#!/bin/bash
# kvio_premap_reach.sh -- can a KV-shaped command stream reach the drive's
# full MDTS, and what does the buffer have to be for that to happen?
#
# Background. Lifting the NVMe dma_opt clamp raises max_hw_sectors, but it
# does not by itself produce MDTS-sized commands: NVME_MAX_SEGS is 256, so a
# 4K-scattered buffer caps a command at 1 MiB and a scattered 2 MiB command is
# refused outright. Reaching MDTS needs physically contiguous memory. This
# script measures which buffer types actually get there, using the command
# geometry a real LLM KV-cache offload issues.
#
# Geometry comes from kvio's GPU-free projection. The default is one
# Llama-3.1-405B KV block:
#   126 layers x 8 KV heads x 128 head_dim x bf16 x 256 tokens = 132,120,576 B
# which is 63 commands at 2 MiB, 126 at 1 MiB and 1008 at 128 KiB.
#
# Requires: the premap kernel (CONFIG_BLK_IOBUF_POOL) booted with a
# TRANSLATING IOMMU and
#   nvme.lift_dma_opt_clamp=1 nvme_core.multipath=0
#   nvme_core.iobuf_pool_folios=<n> nvme_core.iobuf_pool_order=<order>
# Under iommu=pt premap silently falls back to per-command mapping, which
# looks like a null result rather than a misconfiguration -- the script
# records the domain type so that cannot pass unnoticed.
#
# Emits: <OUT>/arms.csv plus a per-arm JSON, power timeline and OCP log dump.
set -u

DEV=${DEV:-/dev/ng0n1}                 # NVMe char device (passthrough)
CTRL=${CTRL:-}                         # /dev/nvmeX, derived from DEV if empty
OBJ_BYTES=${OBJ_BYTES:-132120576}      # one KV object
OBJECTS=${OBJECTS:-40}
QD=${QD:-16}
RANGE_GIB=${RANGE_GIB:-64}
SMOKE=${SMOKE:-$HOME/ebpf-syscall/nvme_uring_cmd_smoke}
OUT=${OUT:-$HOME/kvio-premap-reach}
LBA=${LBA:-}                           # namespace LBA size; probed if empty

mkdir -p "$OUT"
BLK=$(basename "$DEV" | sed 's/^ng/nvme/')
[ -n "$CTRL" ] || CTRL=/dev/$(echo "$BLK" | sed 's/n[0-9]*$//')

# The namespace LBA size is not always 512. Getting this wrong silently
# multiplies every transfer, so probe it rather than assume.
if [ -z "$LBA" ]; then
	LBA=$(cat "/sys/block/$BLK/queue/logical_block_size" 2>/dev/null || echo 512)
fi

RAPL=/sys/class/powercap/intel-rapl:0
rapl_uj() { sudo cat "$RAPL/energy_uj" 2>/dev/null || echo 0; }
rapl_max() { sudo cat "$RAPL/max_energy_range_uj" 2>/dev/null || echo 0; }

# OCP 0xC0 gives device-side counters the host cannot see: how many units the
# media actually read, whether the drive throttled, and unaligned I/O.
ocp_field() { # $1=field regex
	sudo nvme ocp smart-add-log "$CTRL" 2>/dev/null |
		grep -iE "$1" | head -1 | grep -oE '[0-9]+ *$' | tr -d ' '
}
media_read() {
	sudo nvme ocp smart-add-log "$CTRL" 2>/dev/null |
		awk '/Physical media units read/ {print $(NF)}' | head -1
}
dev_temp() {
	sudo nvme smart-log "$CTRL" 2>/dev/null |
		awk -F: '/^temperature/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

echo "== environment" | tee "$OUT/env.txt"
{
	echo "kernel: $(uname -r)"
	echo "cmdline: $(cat /proc/cmdline)"
	echo "device: $DEV  ctrl: $CTRL  block: $BLK  lba_size: $LBA"
	for f in max_hw_sectors_kb max_sectors_kb max_segments; do
		echo "$f: $(cat "/sys/block/$BLK/queue/$f" 2>/dev/null)"
	done
	echo "iommu domains: $(cat /sys/kernel/iommu_groups/*/type 2>/dev/null | sort | uniq -c | tr '\n' ' ')"
	echo "mdts: $(sudo nvme id-ctrl "$CTRL" 2>/dev/null | awk '/^mdts/{print $3}')"
	echo "power states:"
	sudo nvme id-ctrl "$CTRL" 2>/dev/null | grep -E '^ps ' | sed 's/^/  /'
	echo "lift_dma_opt_clamp: $(cat /sys/module/nvme/parameters/lift_dma_opt_clamp 2>/dev/null)"
	echo "iobuf_pool_folios: $(cat /sys/module/nvme_core/parameters/iobuf_pool_folios 2>/dev/null)"
	echo "iobuf_pool_order: $(cat /sys/module/nvme_core/parameters/iobuf_pool_order 2>/dev/null)"
} | tee -a "$OUT/env.txt"
sudo nvme ocp smart-add-log "$CTRL" > "$OUT/ocp-c0-before.txt" 2>&1

# Idle floor for marginal energy: the quietest window we can find, taken on
# this boot rather than assumed, because a fixed post-boot window is
# contaminated by settling.
echo "== measuring idle package power (10s)"
I0=$(rapl_uj); sleep 10; I1=$(rapl_uj)
IDLE_W=$(python3 -c "d=($I1-$I0); d+= $(rapl_max) if d<0 else 0; print(f'{d/1e6/10:.3f}')")
echo "idle_watts: $IDLE_W" | tee -a "$OUT/env.txt"

# The OCP spec calls this counter "physical media units read", but vendors
# differ on whether the value is bytes or a multiple of them. Calibrate it
# against a known transfer rather than trusting a constant: read a fixed
# amount and see how far the counter moves.
echo "== calibrating the OCP media-read counter"
CAL_BYTES=$(( 2 * 1024 * 1024 * 1024 ))
CM0=$(media_read)
sudo "$SMOKE" --dev "$DEV" --count $(( CAL_BYTES / 131072 )) --qd 32 --slots 32 \
	--len 131072 --buffer-len 131072 --lba-size "$LBA" --cmds-per-obj 1 \
	--random --range-gib "$RANGE_GIB" >/dev/null 2>&1
CM1=$(media_read)
MEDIA_UNIT=$(python3 -c "
d = ${CM1:-0} - ${CM0:-0}
print(f'{$CAL_BYTES/d:.4f}' if d > 0 else '0')
")
echo "media counter moved $(( ${CM1:-0} - ${CM0:-0} )) for $CAL_BYTES host bytes -> $MEDIA_UNIT bytes per unit" | tee -a "$OUT/env.txt"

echo "arm,len,cmds_per_obj,count,status,errors,iops,mib_s,p99_us,pkg_watts,marginal_j_per_gib,media_units_read_delta,host_bytes,dev_amp,temp_c_before,temp_c_after,throttle_events" > "$OUT/arms.csv"

run_arm() { # $1=name $2=len  rest=buffer args
	local name=$1 len=$2; shift 2
	local cmds=$(( OBJ_BYTES / len ))
	local count=$(( cmds * OBJECTS ))
	local host_bytes=$(( count * len ))
	echo "== $name: len=$len cmds/obj=$cmds count=$count args=$*"

	local t0 t1 e0 e1 m0 m1 tc0 tc1 thr0 thr1
	tc0=$(dev_temp); m0=$(media_read); thr0=$(ocp_field 'Number of Thermal throttling events')
	e0=$(rapl_uj); t0=$(date +%s.%N)
	( while :; do echo "$(date +%s.%N) $(rapl_uj)"; sleep 0.5; done ) > "$OUT/$name.power" 2>/dev/null &
	local sampler=$!

	sudo "$SMOKE" --dev "$DEV" --count "$count" --qd "$QD" --slots "$QD" \
		--len "$len" --buffer-len "$len" --lba-size "$LBA" \
		--cmds-per-obj "$cmds" --random --range-gib "$RANGE_GIB" "$@" \
		>"$OUT/$name.json" 2>"$OUT/$name.err"
	local rc=$?
	kill $sampler 2>/dev/null; wait $sampler 2>/dev/null
	t1=$(date +%s.%N); e1=$(rapl_uj)
	tc1=$(dev_temp); m1=$(media_read); thr1=$(ocp_field 'Number of Thermal throttling events')

	python3 - "$OUT/$name.json" "$name" "$len" "$cmds" "$count" "$rc" \
		"$t0" "$t1" "$e0" "$e1" "$(rapl_max)" "$IDLE_W" \
		"${m0:-0}" "${m1:-0}" "$host_bytes" "${tc0:-0}" "${tc1:-0}" \
		"${thr0:-0}" "${thr1:-0}" "$MEDIA_UNIT" >> "$OUT/arms.csv" <<'PY'
import json, sys
(path, name, ln, cmds, count, rc, t0, t1, e0, e1, emax, idlew,
 m0, m1, host_bytes, tc0, tc1, thr0, thr1, media_unit) = sys.argv[1:21]
ln, count = int(ln), int(count)
dur = float(t1) - float(t0)
de = int(e1) - int(e0)
if de < 0:
    de += int(emax)
pkg_w = de / 1e6 / dur if dur > 0 else 0.0
status, errors, iops, mib, p99 = "rejected", count, 0.0, 0.0, 0.0
try:
    line = [l for l in open(path) if l.lstrip().startswith("{")][-1]
    d = json.loads(line)
    status = d.get("status", "?")
    errors = d.get("errors", 0)
    iops = d.get("iops", 0.0)
    mib = d.get("bytes_per_second", 0.0) / 1048576
    p99 = d.get("latency_ns", {}).get("p99", 0) / 1000
except Exception:
    pass
# Marginal energy attributes only the above-idle joules to the bytes moved.
ok_bytes = (count - int(errors)) * ln
gib = ok_bytes / (1024 ** 3)
marg = ((de / 1e6) - float(idlew) * dur) / gib if gib > 0 else 0.0
# Device-side amplification: what the NAND actually read, over what the host
# asked for. The unit is calibrated at run time, not assumed.
dm = int(m1) - int(m0)
dev_bytes = dm * float(media_unit)
amp = dev_bytes / ok_bytes if ok_bytes else 0.0
print(f"{name},{ln},{cmds},{count},{status},{errors},{iops:.0f},{mib:.0f},"
      f"{p99:.0f},{pkg_w:.1f},{marg:.2f},{dm},{ok_bytes},{amp:.3f},"
      f"{tc0},{tc1},{int(thr1)-int(thr0)}")
PY
	tail -1 "$OUT/arms.csv" | sed 's/^/  -> /'
}

sudo sysctl -q -w vm.nr_hugepages=$(( QD * 2 + 64 ))

# A scattered buffer at MDTS needs 512 segments; the driver allows 256.
run_arm scattered-2m       2097152
run_arm scattered-1m       1048576
run_arm scattered-128k      131072
# Physically contiguous user memory clears the segment budget.
run_arm hugepage-2m        2097152 --hugepage --fixed
# Kernel-owned pool folios, mapped once, no hugetlb reservation by the app.
run_arm premap-2m          2097152 --premap
run_arm premap-strict-2m   2097152 --strict-premap

sudo nvme ocp smart-add-log "$CTRL" > "$OUT/ocp-c0-after.txt" 2>&1
echo
column -t -s, "$OUT/arms.csv"
echo "KVIO_PREMAP_REACH_DONE -> $OUT/arms.csv"
