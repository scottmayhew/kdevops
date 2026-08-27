#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Compare unregistered hugetlb, registered fixed hugetlb, best-effort premap,
# and strict premap. Save one validated JSON object and one perf counter file
# per repetition. The counters cover the whole process.

set -Eeuo pipefail
export LC_ALL=C

usage()
{
	cat >&2 <<EOF
usage: $0 --label LABEL --expect-domain translated|identity \
          --expect-strict ok|EOPNOTSUPP|ENODEV \
          <ngdev> <smoke-tool> <output-dir>
EOF
}

LABEL=
EXPECT_DOMAIN=
EXPECT_STRICT=
while test "$#" -gt 0; do
	case "$1" in
	--label)
		LABEL=${2:-}
		shift 2
		;;
	--expect-domain)
		EXPECT_DOMAIN=${2:-}
		shift 2
		;;
	--expect-strict)
		EXPECT_STRICT=${2:-}
		shift 2
		;;
	--)
		shift
		break
		;;
	-*)
		usage
		exit 2
		;;
	*)
		break
		;;
	esac
done

test "$#" -eq 3 || {
	usage
	exit 2
}
NG=$1
SMOKE=$2
OUT=$3

[[ "$LABEL" =~ ^[A-Za-z0-9_.-]+$ ]] || {
	echo "set --label to a filesystem-safe run name" >&2
	exit 2
}
case "$EXPECT_DOMAIN" in
translated|identity) ;;
*)
	echo "invalid --expect-domain: $EXPECT_DOMAIN" >&2
	exit 2
	;;
esac
case "$EXPECT_STRICT" in
ok|EOPNOTSUPP|ENODEV) ;;
*)
	echo "invalid --expect-strict: $EXPECT_STRICT" >&2
	exit 2
	;;
esac
case "$EXPECT_DOMAIN:$EXPECT_STRICT" in
translated:ok|translated:EOPNOTSUPP|identity:ENODEV) ;;
*)
	echo "inconsistent domain and strict-mode expectation" >&2
	exit 2
	;;
esac

readonly REPS=${REPS:-10}
readonly WARMUPS=${WARMUPS:-5}
readonly COUNT=${COUNT:-30000}
readonly QD=${QD:-32}
readonly LEN=${LEN:-2097152}
readonly LBA=${LBA:-512}

require_uint()
{
	local name=$1 value=$2 limit=$3

	[[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || {
		echo "$name must be a positive decimal integer" >&2
		exit 2
	}
	test "$((10#$value))" -le "$limit" || {
		echo "$name exceeds $limit" >&2
		exit 2
	}
}

require_uint REPS "$REPS" 1000
require_uint WARMUPS "$WARMUPS" 1000
require_uint COUNT "$COUNT" 134217728
require_uint QD "$QD" 65535
require_uint LEN "$LEN" 4294967295
require_uint LBA "$LBA" 4294967295
test "$((LEN % LBA))" -eq 0 || {
	echo "LEN must be an exact multiple of LBA" >&2
	exit 2
}
test "$((LEN / LBA))" -le 65536 || {
	echo "LEN/LBA exceeds the NVMe command limit of 65536 blocks" >&2
	exit 2
}

PERF=${PERF:-}
if test -z "$PERF"; then
	for candidate in /usr/lib/linux-tools/*/perf; do
		if test -x "$candidate"; then
			PERF=$candidate
			break
		fi
	done
fi
PERF=${PERF:-$(command -v perf || true)}

test -c "$NG"
test -x "$SMOKE"
test -x "$PERF"
command -v jq >/dev/null
command -v flock >/dev/null
SMOKE_HELP=$("$SMOKE" --help)
grep -Fq -- '--fixed' <<< "$SMOKE_HELP"
grep -Fq -- '--strict-premap' <<< "$SMOKE_HELP"
grep -Fq -- '--ready-fd' <<< "$SMOKE_HELP"
sudo -n true

NGNAME=${NG##*/}
[[ "$NGNAME" =~ ^ng[0-9]+n[0-9]+$ ]] || {
	echo "expected an NVMe namespace character device, got $NG" >&2
	exit 1
}
KNAME=${NGNAME/#ng/nvme}
BLOCK=/dev/$KNAME
CTRL=${KNAME%n*}
test -b "$BLOCK"
test -z "$(find "/sys/class/block/$KNAME/holders" \
	-mindepth 1 -maxdepth 1 -print -quit)"
if lsblk -nr -o MOUNTPOINTS "$BLOCK" | grep -q '[^[:space:]]'; then
	echo "$BLOCK is mounted" >&2
	exit 1
fi
if grep -qw "$KNAME" /proc/mdstat; then
	echo "$BLOCK is an mdraid member" >&2
	exit 1
fi
if awk 'NR > 1 { print $1 }' /proc/swaps | grep -qx "$BLOCK"; then
	echo "$BLOCK is active swap" >&2
	exit 1
fi
grep -Fqw nvme_core.multipath=N /proc/cmdline
STATS="/sys/class/block/$KNAME/queue/iobuf_pool_premap_stats"
test -r "$STATS"
grep -Eq '^attempts=[0-9]+$' "$STATS"
grep -Eq '^successes=[0-9]+$' "$STATS"
grep -Eq '^fallbacks=[0-9]+$' "$STATS"
grep -Eq '^no_translating_iommu=[0-9]+$' "$STATS"
grep -Eq '^pgsize_unsupported=[0-9]+$' "$STATS"
grep -Eq '^strict_rejections=[0-9]+$' "$STATS"
test "$(cat "/sys/class/block/$KNAME/queue/max_hw_sectors_kb")" \
	-ge "$((LEN / 1024))"
test -e "/sys/class/nvme/$CTRL/device/iommu_group"
GROUP_PATH=$(readlink -f "/sys/class/nvme/$CTRL/device/iommu_group")
DOMAIN_TYPE=$(cat "$GROUP_PATH/type")
case "$EXPECT_DOMAIN:$DOMAIN_TYPE" in
translated:DMA|translated:DMA-FQ|identity:identity) ;;
*)
	echo "expected $EXPECT_DOMAIN IOMMU domain, found $DOMAIN_TYPE" >&2
	exit 1
	;;
esac

LOCK_NAME=${KNAME//[^A-Za-z0-9_.-]/_}
LOCK_FILE="/tmp/premap-tlb-smoke-$LOCK_NAME.lock"
exec {LOCK_FD}> "$LOCK_FILE"
flock -n "$LOCK_FD" || {
	echo "another run holds $LOCK_FILE" >&2
	exit 1
}
HUGEPAGE_LOCK_FILE=/tmp/premap-tlb-hugetlb.lock
exec {HUGEPAGE_LOCK_FD}> "$HUGEPAGE_LOCK_FILE"
flock -n "$HUGEPAGE_LOCK_FD" || {
	echo "another run is changing the global hugetlb pool" >&2
	exit 1
}
test ! -e "$OUT"
mkdir -p "$OUT"

ORIG_HUGEPAGES=$(sysctl -n vm.nr_hugepages)
HUGEPAGE_KB=$(awk '/Hugepagesize:/ { print $2; exit }' /proc/meminfo)
[[ "$HUGEPAGE_KB" =~ ^[1-9][0-9]*$ ]]
HUGEPAGE_BYTES=$((HUGEPAGE_KB * 1024))
test "$((LEN % HUGEPAGE_BYTES))" -eq 0 || {
	echo "LEN=$LEN is not a multiple of the $HUGEPAGE_BYTES-byte default huge page" >&2
	exit 1
}
NEEDED_HUGEPAGES=$((QD * (LEN / HUGEPAGE_BYTES)))
restore_hugepages()
{
	sudo sysctl -q -w "vm.nr_hugepages=$ORIG_HUGEPAGES" || true
}
trap restore_hugepages EXIT

FREE_HUGEPAGES=$(awk '/HugePages_Free:/ { print $2 }' /proc/meminfo)
TARGET_HUGEPAGES=$ORIG_HUGEPAGES
if test "$FREE_HUGEPAGES" -lt "$NEEDED_HUGEPAGES"; then
	TARGET_HUGEPAGES=$((ORIG_HUGEPAGES + NEEDED_HUGEPAGES - FREE_HUGEPAGES))
fi
sudo sysctl -q -w "vm.nr_hugepages=$TARGET_HUGEPAGES"
test "$(awk '/HugePages_Free:/ { print $2 }' /proc/meminfo)" \
	-ge "$NEEDED_HUGEPAGES"

CSV="$OUT/runs.csv"
printf '%s\n' \
	'label,domain,arm,rep,status,cycles,completed,cycles_per_command,premap_attempts,premap_successes,premap_fallbacks,no_translating_iommu,pgsize_unsupported,strict_rejections' \
	> "$CSV"

readonly PREMAP_COUNTERS=(
	attempts successes fallbacks no_translating_iommu pgsize_unsupported
	iova_no_space iova_misaligned other_failures link_failures sync_failures
	strict_rejections
)

snapshot_stats()
{
	local destination=$1

	cp -- "$STATS" "$destination"
	for counter in "${PREMAP_COUNTERS[@]}"; do
		grep -Eq "^$counter=[0-9]+$" "$destination"
	done
}

counter_value()
{
	local source=$1 counter=$2

	awk -F= -v counter="$counter" '
		$1 == counter { print $2; found = 1 }
		END { if (!found) exit 1 }
	' "$source"
}

counter_delta()
{
	local before=$1 after=$2 counter=$3 old new

	old=$(counter_value "$before" "$counter")
	new=$(counter_value "$after" "$counter")
	test "$new" -ge "$old"
	printf '%d\n' "$((new - old))"
}

write_counter_delta()
{
	local before=$1 after=$2 destination=$3 counter

	: > "$destination"
	for counter in "${PREMAP_COUNTERS[@]}"; do
		printf '%s=%s\n' "$counter" \
			"$(counter_delta "$before" "$after" "$counter")" \
			>> "$destination"
	done
}

validate_counter_delta()
{
	local profile=$1 before=$2 after=$3 counter expected actual

	for counter in "${PREMAP_COUNTERS[@]}"; do
		expected=0
		case "$profile:$counter" in
		retained:attempts|retained:successes)
			expected=$QD
			;;
		identity-fallback:attempts|identity-fallback:fallbacks|identity-fallback:other_failures)
			expected=$QD
			;;
		strict-ENODEV:attempts|strict-ENODEV:no_translating_iommu|strict-ENODEV:strict_rejections)
			expected=1
			;;
		strict-EOPNOTSUPP:attempts|strict-EOPNOTSUPP:pgsize_unsupported|strict-EOPNOTSUPP:strict_rejections)
			expected=1
			;;
		esac
		actual=$(counter_delta "$before" "$after" "$counter")
		test "$actual" -eq "$expected" || {
			echo "$profile: expected $counter delta $expected, got $actual" >&2
			exit 1
		}
	done
}

success_counter_profile()
{
	local mode=$1

	case "$mode:$EXPECT_DOMAIN" in
	premap:identity) echo identity-fallback ;;
	premap:translated|strict-premap:translated) echo retained ;;
	*) return 1 ;;
	esac
}

counter_csv()
{
	local before=$1 after=$2

	printf '%s,%s,%s,%s,%s,%s' \
		"$(counter_delta "$before" "$after" attempts)" \
		"$(counter_delta "$before" "$after" successes)" \
		"$(counter_delta "$before" "$after" fallbacks)" \
		"$(counter_delta "$before" "$after" no_translating_iommu)" \
		"$(counter_delta "$before" "$after" pgsize_unsupported)" \
		"$(counter_delta "$before" "$after" strict_rejections)"
}

expected_mode()
{
	case "$1" in
	hugepage) echo user-hugetlb ;;
	hugepage-fixed) echo fixed-hugetlb ;;
	premap) echo premap ;;
	strict-premap) echo strict-premap ;;
	esac
}

validate_success()
{
	local json=$1 mode=$2

	jq -e --arg mode "$(expected_mode "$mode")" --argjson count "$COUNT" '
		.schema == "nvme_uring_cmd_smoke/v1" and
		.status == "ok" and .mode == $mode and
		.count == $count and .submitted == $count and
		.completed == $count and .successful_commands == $count and
		.errors == 0 and .fatal_errno == 0 and
		.slot_validation.passed == true and
		.ring_counters.passed == true
	' "$json" >/dev/null
}

run_warmups()
{
	local mode=$1
	shift
	local i json log before after delta profile

	for ((i = 1; i <= WARMUPS; i++)); do
		json="$OUT/$mode-warmup-$i.json"
		log="$OUT/$mode-warmup-$i.log"
		if [[ "$mode" == *premap ]]; then
			before="$OUT/$mode-warmup-$i.stats-before"
			after="$OUT/$mode-warmup-$i.stats-after"
			delta="$OUT/$mode-warmup-$i.stats-delta"
			profile=$(success_counter_profile "$mode")
			snapshot_stats "$before"
		fi
		sudo "$SMOKE" --dev "$NG" --count "$COUNT" --qd "$QD" \
			--len "$LEN" --lba-size "$LBA" --cmds-per-obj 8 \
			--trace-base 1000000 "$@" \
			> "$json" 2> "$log"
		validate_success "$json" "$mode"
		if [[ "$mode" == *premap ]]; then
			snapshot_stats "$after"
			write_counter_delta "$before" "$after" "$delta"
			validate_counter_delta "$profile" "$before" "$after"
		fi
	done
}

run_success()
{
	local mode=$1
	shift
	local i json log perf cycles completed cpc before after delta profile stats_fields

	run_warmups "$mode" "$@"
	for ((i = 1; i <= REPS; i++)); do
		json="$OUT/$mode-rep-$i.json"
		log="$OUT/$mode-rep-$i.log"
		perf="$OUT/$mode-rep-$i.perf.csv"
		stats_fields=,,,,,
		if [[ "$mode" == *premap ]]; then
			before="$OUT/$mode-rep-$i.stats-before"
			after="$OUT/$mode-rep-$i.stats-after"
			delta="$OUT/$mode-rep-$i.stats-delta"
			profile=$(success_counter_profile "$mode")
			snapshot_stats "$before"
		fi
		sudo "$PERF" stat -x, -o "$perf" -e cycles -- \
			"$SMOKE" --dev "$NG" --count "$COUNT" --qd "$QD" \
			--len "$LEN" --lba-size "$LBA" --cmds-per-obj 8 \
			--trace-base 2000000 "$@" \
			> "$json" 2> "$log"
		validate_success "$json" "$mode"
		if [[ "$mode" == *premap ]]; then
			snapshot_stats "$after"
			write_counter_delta "$before" "$after" "$delta"
			validate_counter_delta "$profile" "$before" "$after"
			stats_fields=$(counter_csv "$before" "$after")
		fi
		cycles=$(awk -F, '/cycles/ { gsub(/[[:space:]]/, "", $1); print $1; exit }' "$perf")
		[[ "$cycles" =~ ^[0-9]+$ ]]
		completed=$(jq -er '.completed' "$json")
		cpc=$(awk -v cycles="$cycles" -v completed="$completed" \
			'BEGIN { printf "%.3f", cycles / completed }')
		printf '%s,%s,%s,%d,ok,%s,%s,%s,%s\n' \
			"$LABEL" "$DOMAIN_TYPE" "$mode" "$i" "$cycles" \
			"$completed" "$cpc" "$stats_fields" >> "$CSV"
	done
}

run_expected_strict_failure()
{
	local error_text stdout log rc before after delta profile stats_fields

	case "$EXPECT_STRICT" in
	EOPNOTSUPP) error_text='Operation not supported' ;;
	ENODEV) error_text='No such device' ;;
	esac
	stdout="$OUT/strict-premap-expected-$EXPECT_STRICT.stdout"
	log="$OUT/strict-premap-expected-$EXPECT_STRICT.log"
	before="$OUT/strict-premap-expected-$EXPECT_STRICT.stats-before"
	after="$OUT/strict-premap-expected-$EXPECT_STRICT.stats-after"
	delta="$OUT/strict-premap-expected-$EXPECT_STRICT.stats-delta"
	profile="strict-$EXPECT_STRICT"
	snapshot_stats "$before"
	set +e
	sudo "$SMOKE" --dev "$NG" --count "$COUNT" --qd "$QD" \
		--len "$LEN" --lba-size "$LBA" --cmds-per-obj 8 \
		--trace-base 3000000 --strict-premap > "$stdout" 2> "$log"
	rc=$?
	set -e
	test "$rc" -eq 1
	test ! -s "$stdout"
	grep -Fqx "ALLOC_IOBUF slot 0: $error_text; provision nvme_core.iobuf_pool_folios/order and use a non-multipath-head /dev/ng path" "$log"
	snapshot_stats "$after"
	write_counter_delta "$before" "$after" "$delta"
	validate_counter_delta "$profile" "$before" "$after"
	stats_fields=$(counter_csv "$before" "$after")
	printf '%s,%s,strict-premap,0,expected-%s,,0,,%s\n' \
		"$LABEL" "$DOMAIN_TYPE" "$EXPECT_STRICT" "$stats_fields" >> "$CSV"
}

run_success hugepage --hugepage
run_success hugepage-fixed --hugepage --fixed
run_success premap --premap
if test "$EXPECT_STRICT" = ok; then
	run_success strict-premap --strict-premap
else
	run_expected_strict_failure
fi

printf 'wrote %s\n' "$OUT"
