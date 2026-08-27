# premap IOMMU-leaf / TLB campaign

Use this workflow to verify the IOMMU leaf size selected for DMA-IOVA mappings
and to compare registered hugetlb, best-effort premap, and strict premap
command paths. The portable checks require a coherent NVMe function in a
translated DMA-IOMMU domain. The 4 KiB leaf control and requester-filtered PMU
work are AMD-specific.

Use a quiet namespace with no holders, mounts, swap, MD, or device-mapper
users. The command workloads issue reads.

Nothing here draws conclusions -- it produces CSV/JSON you interpret.

## 0. Kernel and boot

Select `blk-iobuf-pool-v5-premap-iova-pgsize-clamp-param-test`:

```sh
make defconfig-iobuf-premap-tlb-baremetal DECLARE_HOSTS=<host>
make -j$(nproc) && make linux
```

The defconfig selects the tree and declared host; it does not install the
required kernel options or boot arguments. Enable `CONFIG_BLK_IOBUF_POOL=y`
and `CONFIG_DMA_IOVA_PGSIZE_SELFTEST=m` in the tested kernel configuration.
Install these command lines on a 4 KiB-base-page AMD system:

```
common    : iommu.passthrough=0 nvme_core.multipath=N \
            nvme_core.iobuf_pool_order=9 \
            nvme_core.iobuf_pool_folios=256 nvme.lift_dma_opt_clamp=1
2 MiB leaf: amd_iommu=pgtbl_v1
4 KiB leaf: amd_iommu=pgtbl_v1,nohugepages
```

Order 9 is 2 MiB only when the base page is 4 KiB.

Verify (huge-on): `cat /proc/cmdline`; `cat /sys/module/nvme/parameters/lift_dma_opt_clamp`
is `Y`; `cat /sys/block/nvme2n1/queue/max_hw_sectors_kb` >= 2048;
`dmesg | grep iobuf_pool:` shows `order 9`; `ls /sys/bus/event_source/devices/amd_iommu_*`.
huge-off additionally shows `dmesg | grep 'Restricting V1 page-sizes to 4KiB'`.

Prereqs: `sudo apt-get install -y fio nvme-cli liburing-dev linux-tools-generic
jq python3`; build `nvme_uring_cmd_smoke` from ebpf-syscall commit
`441c164c8f80` or later. The driver requires its fixed-buffer arm, strict premap
mode, barrier interface, and `nvme_uring_cmd_smoke/v1` JSON schema.

## 1. CPU: hugetlb registration and premap

Run five warmups and 10 measured repetitions on both boots:

```sh
./premap_tlb_smoke.sh \
        --label huge-on \
        --expect-domain translated \
        --expect-strict ok \
        /dev/ng2n1 /path/to/nvme_uring_cmd_smoke results/huge-on-smoke

# After rebooting with amd_iommu=pgtbl_v1,nohugepages:
./premap_tlb_smoke.sh \
        --label huge-off \
        --expect-domain translated \
        --expect-strict EOPNOTSUPP \
        /dev/ng2n1 /path/to/nvme_uring_cmd_smoke results/huge-off-smoke
```

The driver saves each successful run's JSON, perf counter file, log, and pool
counter snapshots. It verifies a retained mapping or fallback from the pool
counter delta around every premap invocation. For an expected strict setup
failure, it saves stdout, stderr, and the counter snapshots; the smoke tool
fails before it emits JSON. `runs.csv` records one row per measured repetition.
The arms are unregistered hugetlb, registered fixed hugetlb, best-effort
premap, and strict premap. On the huge-off boot, strict premap must fail with
`EOPNOTSUPP` because the IOMMU cannot install a 2 MiB leaf. Set `WARMUPS`,
`REPS`, `COUNT`, `QD`, `LEN`, or `LBA` to override the defaults.

The `perf stat` invocation wraps allocation, registration, process startup,
the I/O loop, and teardown. It does not use the smoke tool's ready/start
barrier. Treat these as whole-process cycles, not steady-state command cycles.
Add a measurement-window controller before using this workflow for the next
passthrough cost run.

Compare registered fixed hugetlb with premap. Report that delta as a difference
between the current interfaces, not as the isolated cost of mapping retention:
the hugetlb buffer is user-owned and the premap buffer is kernel-owned.

For an `iommu=pt` fallback check, use `--expect-domain identity` and
`--expect-strict ENODEV`. Always set an explicit label; do not infer the domain
from the presence or absence of `amd_iommu=nohugepages`.

## 2. Synthetic leaf geometry

Build the kernel selftests first:

```sh
make -C /path/to/linux/tools/testing/selftests/blk-iobuf
make -C /path/to/linux/tools/testing/selftests/dma-iova-pgsize
```

Run the leaf tracer on the 2 MiB-leaf boot:

```sh
scripts/workflows/iobuf_bench/premap_tlb_leaf.sh \
        --label huge-on \
        --bdf 0000:BB:DD.F \
        --kernel-tree /path/to/linux \
        --expect-leaf-size 2097152 \
        --expect-strict ok \
        --output results/huge-on-leaf
```

Reboot with `amd_iommu=pgtbl_v1,nohugepages` and repeat with
`--label huge-off`, `--expect-leaf-size 4096`, `--expect-strict EOPNOTSUPP`,
and a new output directory. The driver uses a private tracefs instance and
rejects a non-translated IOMMU domain.

The driver requires the built tree's kernel release to match `uname -r`. It
records the tree commit, tracked-file dirty state, order, iteration count, and
byte cap. The commit remains caller-asserted provenance: matching release names
do not prove that the running kernel was built from that commit.

This trace exercises the DMA-IOVA API; it does not prove the leaf geometry of
a live blk-iobuf registration. Make that claim only after a live registration
trace, pool-counter delta, and expected mapped-byte count agree.

No public driver currently reproduces the preliminary requester-filtered AMD
IOMMU PMU and `iobuf-fixed-test --bench` measurements over the I/O window. Add
the smoke tool's ready/start protocol to that driver before collecting new PMU
numbers. Do not use whole-process counters as steady-state I/O counters.

## Rigor checklist (why the first pilot was a NO-GO)

- >= 5 warmups, >= 10 measured repetitions per arm.
- Alternate boot order across reboots (huge-on, huge-off, huge-on, ...) to
  decorrelate boot/thermal drift.
- PMU and CPU counters over the measured window only, not wrapping setup.
- Direct leaf + command tracing of the real blk-iobuf premap registrations.
- Report medians and dispersion; normalize IOTLB events per GiB and per command.
