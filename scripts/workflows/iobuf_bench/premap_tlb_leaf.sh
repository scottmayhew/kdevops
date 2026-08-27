#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Trace the IOMMU leaf geometry selected by the DMA-IOVA page-size selftest.
# Use a private tracefs instance and leave global tracing state untouched.

set -Eeuo pipefail
export LC_ALL=C

usage()
{
	cat >&2 <<EOF
usage: $0 --label LABEL --bdf DOMAIN:BUS:SLOT.FUNC \
          --kernel-tree DIR --expect-leaf-size BYTES \
          --expect-strict ok|EOPNOTSUPP --output DIR
EOF
}

LABEL=
BDF=
TREE=
EXPECT_LEAF_SIZE=
EXPECT_STRICT=
OUT=
while test "$#" -gt 0; do
	case "$1" in
	--label) LABEL=${2:-}; shift 2 ;;
	--bdf) BDF=${2:-}; shift 2 ;;
	--kernel-tree) TREE=${2:-}; shift 2 ;;
	--expect-leaf-size) EXPECT_LEAF_SIZE=${2:-}; shift 2 ;;
	--expect-strict) EXPECT_STRICT=${2:-}; shift 2 ;;
	--output) OUT=${2:-}; shift 2 ;;
	*)
		usage
		exit 2
		;;
	esac
done

[[ "$LABEL" =~ ^[A-Za-z0-9_.-]+$ ]] || {
	echo "set --label to a filesystem-safe run name" >&2
	exit 2
}
[[ "$BDF" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]
case "$EXPECT_STRICT" in
ok|EOPNOTSUPP) ;;
*)
	echo "invalid --expect-strict: $EXPECT_STRICT" >&2
	exit 2
	;;
esac
test -n "$TREE"
test -n "$OUT"
test ! -e "$OUT"

readonly ORDER=${ORDER:-9}
readonly ITERATIONS=${ITERATIONS:-8}
readonly MAX_BYTES=${MAX_BYTES:-67108864}

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

require_uint EXPECT_LEAF_SIZE "$EXPECT_LEAF_SIZE" 1073741824
require_uint ORDER "$ORDER" 20
require_uint ITERATIONS "$ITERATIONS" 1000000
require_uint MAX_BYTES "$MAX_BYTES" 4294967295

TREE_COMMIT=$(git -C "$TREE" rev-parse --verify HEAD)
if test -n "$(git -C "$TREE" status --porcelain --untracked-files=no)"; then
	TREE_DIRTY=true
else
	TREE_DIRTY=false
fi
test -r "$TREE/include/config/kernel.release" || {
	echo "build the kernel tree before running this test" >&2
	exit 1
}
TREE_RELEASE=$(cat "$TREE/include/config/kernel.release")
RUNNING_RELEASE=$(uname -r)
test "$TREE_RELEASE" = "$RUNNING_RELEASE" || {
	echo "kernel tree release $TREE_RELEASE does not match running $RUNNING_RELEASE" >&2
	exit 1
}
DMA="$TREE/tools/testing/selftests/dma-iova-pgsize/dma_iova_pgsize.sh"
HIST="$TREE/tools/testing/selftests/dma-iova-pgsize/leaf_hist.py"
TRACE_ROOT=/sys/kernel/tracing
TRACE_INSTANCE="$TRACE_ROOT/instances/premap-tlb-$$"

test -x "$DMA"
test -x "$HIST"
command -v flock >/dev/null
test -e "/sys/bus/pci/devices/$BDF/iommu_group"
GROUP_PATH=$(readlink -f "/sys/bus/pci/devices/$BDF/iommu_group")
DOMAIN_TYPE=$(cat "$GROUP_PATH/type")
case "$DOMAIN_TYPE" in
DMA|DMA-FQ) ;;
*)
	echo "expected a translated DMA domain, found $DOMAIN_TYPE" >&2
	exit 1
	;;
esac
mountpoint -q "$TRACE_ROOT" || {
	echo "mount tracefs at $TRACE_ROOT before running this test" >&2
	exit 1
}
MODULE_LOCK_FILE=/tmp/premap-tlb-leaf-module.lock
exec {MODULE_LOCK_FD}> "$MODULE_LOCK_FILE"
flock -n "$MODULE_LOCK_FD" || {
	echo "another DMA-IOVA leaf test is using the global selftest module" >&2
	exit 1
}
if lsmod | awk '{ print $1 }' | grep -qx dma_iova_pgsize_selftest; then
	echo "unload dma_iova_pgsize_selftest before running this test" >&2
	exit 1
fi
sudo -n true

LOCK_NAME=${BDF//[^A-Za-z0-9_.-]/_}
LOCK_FILE="/tmp/premap-tlb-leaf-device-$LOCK_NAME.lock"
exec {LOCK_FD}> "$LOCK_FILE"
flock -n "$LOCK_FD" || {
	echo "another run holds $LOCK_FILE" >&2
	exit 1
}

mkdir -p "$OUT"
sudo mkdir "$TRACE_INSTANCE"
cleanup()
{
	sudo sh -c "echo 0 > '$TRACE_INSTANCE/events/iommu/iommu_map_leaf/enable'" \
		>/dev/null 2>&1 || true
	sudo modprobe -r dma_iova_pgsize_selftest >/dev/null 2>&1 || true
	sudo rmdir "$TRACE_INSTANCE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

jq -n \
	--arg label "$LABEL" \
	--arg bdf "$BDF" \
	--arg domain_type "$DOMAIN_TYPE" \
	--arg tree_commit "$TREE_COMMIT" \
	--argjson tree_dirty "$TREE_DIRTY" \
	--arg tree_release "$TREE_RELEASE" \
	--arg running_release "$RUNNING_RELEASE" \
	--argjson expected_leaf_size "$EXPECT_LEAF_SIZE" \
	--arg expect_strict "$EXPECT_STRICT" \
	--argjson order "$ORDER" \
	--argjson iterations "$ITERATIONS" \
	--argjson max_bytes "$MAX_BYTES" \
	'{label:$label,bdf:$bdf,domain_type:$domain_type,
	  selftest_tree_commit:$tree_commit,selftest_tree_dirty:$tree_dirty,
	  selftest_tree_release:$tree_release,running_kernel_release:$running_release,
	  running_commit_proven:false,
	  expected_leaf_size:$expected_leaf_size,expect_strict:$expect_strict,
	  order:$order,iterations:$iterations,max_bytes:$max_bytes}' \
	> "$OUT/metadata.json"

cleanup_module()
{
	sudo modprobe -r dma_iova_pgsize_selftest >/dev/null 2>&1 || true
}

configure()
{
	local api=$1

	cleanup_module
	sudo "$DMA" \
		--bdf "$BDF" --api "$api" --mode immediate --negative none \
		--order "$ORDER" --folios-per-mapping 1 \
		--iterations "$ITERATIONS" --max-live 1 \
		--max-bytes "$MAX_BYTES" --seed 1 \
		--kernel-commit "$TREE_COMMIT" --configure-only
}

trace_success()
{
	local api=$1
	local result="$OUT/$api-result.json"
	local events="$OUT/$api-leaf-events.txt"
	local histogram="$OUT/$api-leaf-hist.json"
	local domain iova size expected

	configure "$api"
	sudo sh -c "echo > '$TRACE_INSTANCE/trace'; \
		echo 1 > '$TRACE_INSTANCE/events/iommu/iommu_map_leaf/enable'"
	sudo "$DMA" --run-only > "$result" 2> "$OUT/$api.log"
	sudo sh -c "echo 0 > '$TRACE_INSTANCE/events/iommu/iommu_map_leaf/enable'"
	sudo cat "$TRACE_INSTANCE/trace" > "$events"

	jq -e --arg api "$api" --arg commit "$TREE_COMMIT" \
		--argjson iterations "$ITERATIONS" '
		.status == 0 and .api == $api and .kernel_commit == $commit and
		.mapping_successes == $iterations and .folio_leaks == 0 and
		.iova_leaks == 0 and .expected_leaf_mapped_bytes > 0 and
		(.domain_token | type == "string" and length > 0)
	' "$result" >/dev/null

	domain=$(jq -er '.domain_token' "$result")
	iova=$(jq -er '.iova_start' "$result")
	size=$(jq -er '.iova_size' "$result")
	expected=$(jq -er '.expected_leaf_mapped_bytes' "$result")
	"$HIST" --domain "$domain" --iova-start "$iova" --iova-size "$size" \
		--expected-mapped-bytes "$expected" --format json "$events" \
		> "$histogram"
	jq -e --argjson leaf "$EXPECT_LEAF_SIZE" '
		([.histogram[].mapped_bytes] | add // 0) == .expected_mapped_bytes and
		(.histogram | length) == 1 and .histogram[0].leaf_size == $leaf
	' "$histogram" >/dev/null
	cleanup_module
}

strict_must_fail()
{
	local result="$OUT/strict-expected-EOPNOTSUPP.json"
	local rc

	cleanup_module
	set +e
	sudo "$DMA" \
		--bdf "$BDF" --api strict --mode immediate --negative none \
		--order "$ORDER" --folios-per-mapping 1 --iterations 1 \
		--max-live 1 --max-bytes "$MAX_BYTES" --seed 1 \
		--kernel-commit "$TREE_COMMIT" > "$result" \
		2> "$OUT/strict-expected-EOPNOTSUPP.log"
	rc=$?
	set -e
	test "$rc" -eq 1
	jq -e '
		.status == -95 and .last_errno == -95 and .api == "strict" and
		.mapping_successes == 0 and .pgsize_unsupported == 1 and
		.folio_leaks == 0 and .iova_leaks == 0
	' "$result" >/dev/null
	cleanup_module
}

trace_success current
if test "$EXPECT_STRICT" = ok; then
	trace_success strict
else
	strict_must_fail
fi

printf 'wrote %s\n' "$OUT"
