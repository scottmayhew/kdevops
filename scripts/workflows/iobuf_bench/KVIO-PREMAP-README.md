# Can a KV-shaped command stream reach the drive's MDTS?

`kvio_premap_reach.sh` answers one question: when an LLM KV-cache offload
asks a 2 MiB-MDTS drive for 2 MiB commands, what does it actually get, and
what does the buffer have to be for the answer to be "2 MiB"?

## Why the question is not obvious

Raising the NVMe transfer limit is not enough. `nvme-pci` derives the segment
limit from the transfer limit, but caps it at `NVME_MAX_SEGS` = 256. With an
ordinary 4K-scattered buffer that bounds a command at 1 MiB — half of what a
lifted sector limit allows — and a scattered 2 MiB passthrough command needs
512 segments, so it is refused with `EINVAL` rather than split.

Reaching MDTS therefore requires physically contiguous memory. The arms below
separate the three ways of getting it (or failing to):

| arm | buffer | expectation |
|---|---|---|
| `scattered-2m` | ordinary anonymous pages | refused: 512 segments needed, 256 allowed |
| `scattered-1m` | ordinary anonymous pages | the segment-bound ceiling |
| `scattered-128k` | ordinary anonymous pages | what a stock kernel permits anyway |
| `hugepage-2m` | `MAP_HUGETLB` + registered | contiguous, so the budget is met |
| `premap-2m` | kernel-owned pool folios, mapped once | contiguous without the application reserving hugetlb |
| `premap-strict-2m` | as above, IOMMU leaf size enforced | fails closed rather than degrading quietly |

## Geometry

Command sizes come from kvio's GPU-free projection so the stream has the
shape a real KV offload issues, not a synthetic one. The default object is
one Llama-3.1-405B KV block:

```
126 layers x 8 KV heads x 128 head_dim x 2 (bf16) x 256 tokens = 132,120,576 B
```

which is 63 commands at 2 MiB, 126 at 1 MiB and 1008 at 128 KiB. Override
with `OBJ_BYTES` to model another model; regenerate with
`ebpf-syscall/examples/lmcache/kvio_plan.py`.

## Requirements

- A kernel with `CONFIG_BLK_IOBUF_POOL=y` — the `blk-iobuf-pool-v5-premap-iova`
  line, public on korg.
- Booted with a **translating** IOMMU. Under `iommu=pt` premap cannot retain
  an IOVA: best effort falls back to per-command mapping and strict returns
  `-ENODEV`. The script records the domain type for exactly this reason — a
  passthrough boot produces a null result that reads like a finding.
- Boot arguments:
  ```
  nvme.lift_dma_opt_clamp=1 nvme_core.multipath=0
  nvme_core.iobuf_pool_folios=80 nvme_core.iobuf_pool_order=9
  ```
  `order=9` is 2 MiB folios on a 4 KiB-page host. `multipath=0` matters
  because premap needs a non-multipath-head `/dev/ng` path.
- `nvme_uring_cmd_smoke` from ebpf-syscall (`make nvme_uring_cmd_smoke`).
- `nvme-cli` with the `ocp` plugin for the device-side counters.

## Running

```sh
DEV=/dev/ng2n1 OBJECTS=40 QD=16 \
	scripts/workflows/iobuf_bench/kvio_premap_reach.sh
```

Output lands in `$OUT` (default `~/kvio-premap-reach`): `arms.csv`, a JSON
and a 2 Hz power timeline per arm, `env.txt`, and the OCP log before and
after.

## What it measures, and what each number is worth

**Host CPU energy.** Package energy from the RAPL powercap counter, sampled
around each arm, with the idle floor measured on the same boot rather than
assumed. Reported as `pkg_watts` and `marginal_j_per_gib`. This is CPU-side
only: RAPL does not see the SSD, the fans or the PSU, so it is an efficiency
number and not wall power.

**Device-side work.** The OCP 0xC0 log exposes counters the host cannot
derive, including physical media units read, thermal throttling events and
unaligned I/O. `dev_amp` is what the media actually read over what the host
asked for.

The units of the media counter are **calibrated at run time** against a known
2 GiB transfer rather than taken from the specification, because vendors
differ on whether the field is bytes or a multiple of them. `env.txt` records
the calibration so the amplification figure can be rechecked.

**Device power** is *not* measured. The drive reports a maximum power per
power state in `id-ctrl` (25 W in PS0 on the PM9A3 tested), which is a
specification bound, not a draw. Temperature and throttle-event deltas are
recorded as the only device-side evidence of load available without external
instrumentation. Do not convert them into watts.

## Wire-level proof

The acceptance result is only half the story: a command that is *accepted*
may still be split before it reaches the device. Confirm the size on the wire
from the driver tracepoint, which needs no BTF:

```sh
echo 1 > /sys/kernel/tracing/events/nvme/nvme_setup_cmd/enable
# run the arm, then:
grep nvme_cmd_read /sys/kernel/tracing/trace |
	sed -n 's/.*len=\([0-9]*\).*/\1/p' | sort | uniq -c
```

`len` is the zero-based block count, so the transfer is `(len + 1) *
logical_block_size`. Prefer this over `nvme_tp_monitor` on a locally built
kernel: that tracer attaches with `tp_btf`, so it needs `CONFIG_DEBUG_INFO_BTF_MODULES=y`
for the nvme module's tracepoints, which distro-derived configs often build
without.

## Traps this script exists to avoid

- **The LBA size is probed, not assumed.** These namespaces are frequently
  formatted with 4 KiB blocks. Passing `--lba-size 512` against a 4 KiB
  namespace silently multiplies every transfer by eight and produces errors
  that look like a transfer-limit rejection.
- **A passthrough IOMMU boot looks like a premap failure.** The domain type
  is recorded in `env.txt`.
- **A rejected arm is a result, not an error.** `scattered-2m` is expected to
  be refused; the CSV records it as `rejected` and keeps going.
- **`make install` can fail on an unrelated DKMS module** (`bnxt_en` on the
  box tested) and take the initramfs down with it. Move
  `/etc/kernel/postinst.d/dkms` aside, then `update-initramfs -c -k <ver>`.
- **The grub variable is not always `GRUB_CMDLINE_LINUX_DEFAULT`.** Some
  images set only `GRUB_CMDLINE_LINUX`; editing the wrong one appends
  nothing and the kernel boots without the parameters. Always confirm with
  `cat /proc/cmdline` after the reboot, not before.
- **The OCP media-read counter may not advance during a run.** On the PM9A3
  tested it did not move across ~25 GiB, so device-side amplification was not
  obtainable. The script calibrates and reports it rather than assuming it
  works.
