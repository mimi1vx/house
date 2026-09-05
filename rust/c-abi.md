# Stable C ABI map — Rust ↔ Haskell FFI + `ld`

> Single source of truth for every `#[no_mangle] pub extern "C"` / `pub static`
> the Rust workspace exports. The C-to-Rust port is complete: `house-boot`
> (`global_asm!` entry/vectors) + `house-hal-aarch64` + `house-libc` are always
> linked (`platform/aarch64/Makefile`, `--start-group`/`--end-group`), and
>    `platform/aarch64/tinylibc` is superseded. Ceiling is `HOUSE_MAX_SMP=32`
   (`u32` online mask, `0xFFFFFFFF` at 32; no `1u32 << 32` shifts — all
   mask construction uses `checked_shl` or the `smp_n >= 32` guard). This
   file is the frozen contract:
> renaming, removing, or re-signaturing a symbol here breaks `ld -T
> build/aarch64.ld` and every Haskell `foreign import ccall unsafe` that names
> it. This file is `nm`-auditable: `nm rust/target/aarch64-unknown-none/debug/*.a
> *.rlib | grep " T "` must cover the `Symbol` column (see Audit notes).
> No `bindgen`/`cbindgen` — freestanding headers are not host-parseable and host
> `glibc` `stat` layouts differ from tinylibc `stat`; hand-written `#[repr(C)]`
> truth with the `nm` gate is the reviewable contract (SOTA Rust 01 minimal API).

Conventions: **Crate** is the defining Rust crate (link owner); the section
header names the defining module (`src/<file>.rs`). Every
`pub unsafe extern "C"` carries a `// SAFETY:` comment at its definition site
discharging the caller's preconditions (SOTA Rust 03); the `Hal*` traits in
`house-hal` are `#[inline(always)]` adapters over these free functions and add
no new `#[no_mangle]` names. **Source** is pre-port C provenance
(`platform/aarch64/*`, `tinylibc/*`, `start.S`, `aarch64.ld`).

## No ABI delta from Tracks A/B

Tracks A/B added no `#[no_mangle]` symbols: `house_vm_demand_single`,
`house_vm_demand_100`, and `house_puts_after` (the `vmTest`/`vm` surface) live
in `house-hal-aarch64/src/mm/vm.rs` and were part of the port, not new ABI.
No `house_pa_for_va` / `house_shootdown_count` symbols exist anywhere in the
tree (they stayed private to the HAL); `parFib`/`mvarTest`/net/EL0 work reused
the frozen map below.

## Trust boundaries

Future symbol additions that touch these paths get bounds review first
(SOTA Code Security 06/09):

- **Virtio-blk device bytes.** The device writes completion data into guest
  RAM; `virtio_blk_invalidate` (`dc ivac`, invalidate-before-read) must precede
  any read of `used`/status/data, and `virtio_transport_dc_flush` (`dc cvac`,
  flush-before-notify) must precede `virtio_transport_notify`. Lengths arrive
  from `qsize`/request fields — `checked_*` on `pa+len` (see `mmio.rs`
  `dc_cvac_range`/`dc_ivac_range`, `virtio_transport_dc_flush`).
- **Virtio-net hostile RX frames.** Same invalidate-before-read rule via
  `virtio_net_invalidate`; the Haskell decoders (`decodeEthernet`/`Arp`/`Ipv4`
  in `Kernel/Driver/Virtio/Net/Stack.hs`) do their own length checks on top.
  RX-replenish keeps the Track B `pollTx`/locking order; the IRQ→Endpoint push
  path (`house_irq_push`, `ba5acfa`) stays byte-identical.
- **EL0 `svc` dispatch.** `house_svc_dispatch` (`WRITE 0x01`/`EXIT 0x02`) and
  `house_ipc_svc_dispatch` (`IPC 0x10..0x14`) take raw `imm`/`x0..x3` from EL0;
  unknown `imm` returns an error, user pointers are validated before
  copy (`house_ipc_copy_msg` is length-bounded).
- **Buddy containment.** `buddy_free_page`/`buddy_contains` reject null,
   misaligned, and out-of-range (`BUDDY_START..BUDDY_END`) pages; the managed
   window is `__heap_base+64M .. stack_top-N*64K` (N = detected cores).

Legend: **Crate** is the defining Rust crate; **Symbol** is the exact
`#[no_mangle]` name `ld` expects; **C signature** is the pre-port C declaration;
**Source** is the owning pre-port C file (Rust module is the section header).

## HAL crates (`house-hal-aarch64`)

### `uart.rs` — `uart.h` / `uart.c`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `uart_init` | `void uart_init(void)` | `uart.c` |
| `house-hal-aarch64` | `uart_putc` | `void uart_putc(char c)` | `uart.c` |
| `house-hal-aarch64` | `uart_puts` | `void uart_puts(const char *s)` | `uart.c` |
| `house-hal-aarch64` | `uart_getc_blocking` | `int uart_getc_blocking(void)` | `uart.c` |
| `house-hal-aarch64` | `uart_getc_nonblock` | `int uart_getc_nonblock(void)` | `uart.c` |

### `mmu.rs` — `mmu.c`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_mmu_early` | `void house_mmu_early(void)` | `mmu.c` |
| `house-hal-aarch64` | `house_mmu_enable_secondary` | `void house_mmu_enable_secondary(void)` | `mmu.c` (`c_start.c` extern) |
| `house-hal-aarch64` | `house_mmu_set_ttbr0` | `void house_mmu_set_ttbr0(void *pdir, uint64_t asid)` | `mmu.c` |
| `house-hal-aarch64` | `house_mmu_clone_kernel_l1` | `void house_mmu_clone_kernel_l1(void *new_l1)` | `mmu.c` |
| `house-hal-aarch64` | `house_mmu_clone_kernel_l2` | `void house_mmu_clone_kernel_l2(void *new_l2)` | `mmu.c` |
| `house-hal-aarch64` | `house_mmu_update_alias` | `void house_mmu_update_alias(void)` | `mmu.c` |
| `house-hal-aarch64` | `house_mmu_map_kernel` | `void house_mmu_map_kernel(uint64_t pa, uint64_t va, uint64_t size, uint64_t attr)` | `mmu.c` |
| `house-hal-aarch64` | `house_get_ttbrs` | `void house_get_ttbrs(uint64_t *ttbr0, uint64_t *ttbr1, uint64_t *tcr)` | `mmu.c` |
| `house-hal-aarch64` | `ttbr0_l0` | `uint64_t ttbr0_l0[512]` aligned 4096 | `mmu.c` |

Also `ttbr1_l0`, `l1_low`, `l1_rts`, `l2_rts` are `static` and not exported — not part of ABI.

### `buddy.rs` — `buddy.c` / `buddy.h`

Manages `__heap_base+64M .. stack_top-N*64K` (N = detected cores, 2 MiB max
reservation at the 32-core HW bound); lengths use `checked_add` (SOTA
Security 06). Counters are 64-bit; `buddy_*_count` stay `int` as saturated
compat shims, `house_mem_stats` is the full 64-bit path.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `buddy_init` | `void buddy_init(uint64_t start, uint64_t end)` | `buddy.c` |
| `house-hal-aarch64` | `buddy_alloc_page` | `void *buddy_alloc_page(void)` | `buddy.c` |
| `house-hal-aarch64` | `buddy_free_page` | `void buddy_free_page(void *p)` | `buddy.c` |
| `house-hal-aarch64` | `buddy_free_count` | `int buddy_free_count(void)` | `buddy.c` |
| `house-hal-aarch64` | `buddy_total_count` | `int buddy_total_count(void)` | `buddy.c` |
| `house-hal-aarch64` | `buddy_contains` | `int buddy_contains(void *p)` | `buddy.c` |
| `house-hal-aarch64` | `house_mem_stats` | `void house_mem_stats(uint64_t *total, uint64_t *free_pages)` | `buddy.c` |

### `gic.rs` — `gic.c`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_gic_init` | `void house_gic_init(void)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_init_secondary` | `void house_gic_init_secondary(uint32_t core)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_enable_int` | `void house_gic_enable_int(uint32_t intid)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_disable_int` | `void house_gic_disable_int(uint32_t intid)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_send_sgi` | `void house_gic_send_sgi(uint32_t sgi_id, uint32_t aff0_mask)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_send_sgi_to_core` | `void house_gic_send_sgi_to_core(uint32_t sgi_id, uint32_t core)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_enable_sgi` | `void house_gic_enable_sgi(uint32_t id)` | `gic.c` |
| `house-hal-aarch64` | `house_gic_eoi` | `void house_gic_eoi(uint32_t iar)` | `gic.c` |
| `house-hal-aarch64` | `house_irq_enable` | `void house_irq_enable(void)` | `gic.c` |
| `house-hal-aarch64` | `house_irq_disable` | `void house_irq_disable(void)` | `gic.c` |

### `timer.rs` — `timer.c`

Owns `house_isr_active` / `house_isr_pending` (per-core timer pending) and the
rearm path feeding `house_rts_tick()` (SMP_N cores, PPI 27/30, SGI 0 IPI).

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_isr_active` | `volatile int house_isr_active` | `timer.c`/`irq.c` |
| `house-hal-aarch64` | `house_isr_pending` | `volatile uint64_t house_isr_pending[HOUSE_MAX_SMP]` (32) | `timer.c` |
| `house-hal-aarch64` | `house_timer_init` | `void house_timer_init(void)` | `timer.c` |
| `house-hal-aarch64` | `house_timer_init_secondary` | `void house_timer_init_secondary(uint32_t core)` | `timer.c` |
| `house-hal-aarch64` | `house_timer_rearm_virt` | `void house_timer_rearm_virt(void)` | `timer.c` |
| `house-hal-aarch64` | `house_timer_rearm_phys` | `void house_timer_rearm_phys(void)` | `timer.c` |
| `house-hal-aarch64` | `house_uptime_secs` | `uint64_t house_uptime_secs(void)` | `timer.c` |

### `irq.rs` — `irq.c` / `irq.h`

IRQ→Endpoint push path (`house_irq_push`, `ba5acfa` livelock fix) is frozen;
`house_fd_pipe_readable` is provided by `house-libc`.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_irq_init` | `void house_irq_init(void)` | `irq.c` |
| `house-hal-aarch64` | `house_irq_push` | `void house_irq_push(uint32_t intid)` | `irq.c` |
| `house-hal-aarch64` | `house_irq_pop` | `int house_irq_pop(void)` | `irq.c` |
| `house-hal-aarch64` | `house_irq_pipe_fd` | `int house_irq_pipe_fd(void)` | `irq.c` |
| `house-hal-aarch64` | `house_irq_pipe_drain` | `void house_irq_pipe_drain(void)` | `irq.c` |
| `house-hal-aarch64` | `house_irq_pipe_readable` | `int house_irq_pipe_readable(int fd)` | `irq.c` |

### `userspace.rs` — `userspace.c` / `userspace.h`

TTBR0 window `0x01000000–0xFFFFFFFF`, 8-bit ASID with `VMALLE1IS` wrap,
demand pager + `mprotect` RO perm faults + `munmap` translation faults,
`VAE1IS` + SGI 1 shootdown.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_userspace_init` | `void house_userspace_init(void)` | `userspace.c` |
| `house-hal-aarch64` | `init_page_dir` | `void init_page_dir(void *pdir)` | `userspace.c` |
| `house-hal-aarch64` | `current_pdir` | `void *current_pdir(void)` | `userspace.c` |
| `house-hal-aarch64` | `invalidate_page` | `void invalidate_page(uint64_t vaddr)` | `userspace.c` |
| `house-hal-aarch64` | `house_set_recorded_pdir` | `void house_set_recorded_pdir(void *pdir)` | `userspace.c` |
| `house-hal-aarch64` | `house_asid_for_pdir` | `uint64_t house_asid_for_pdir(void *pdir)` | `userspace.c` |
| `house-hal-aarch64` | `house_is_ro_page` | `int house_is_ro_page(uint64_t va)` | `userspace.c` |
| `house-hal-aarch64` | `house_tlb_shootdown` | `void house_tlb_shootdown(uint64_t vaddr)` | `userspace.c` |
| `house-hal-aarch64` | `house_handle_user_fault` | `int house_handle_user_fault(uint64_t far)` | `userspace.c` |
| `house-hal-aarch64` | `min_user_addr` | `void *min_user_addr` | `userspace.c` |
| `house-hal-aarch64` | `max_user_addr` | `void *max_user_addr` | `userspace.c` |

### `mm/vm.rs` — `mm/vm.c`

VM self-test surface used by the `vm` shell command (`vm-ok` gate):
demand-100 pages, `mprotect` RO perm fault, `munmap` translation fault,
`house_puts_after` ordering marker.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_vm_mmap` | `void *house_vm_mmap(void *addr, size_t len, int prot, int flags, int fd, long off)` | `mm/vm.c` |
| `house-hal-aarch64` | `house_vm_munmap` | `int house_vm_munmap(void *a, size_t len)` | `mm/vm.c` |
| `house-hal-aarch64` | `house_vm_mprotect` | `int house_vm_mprotect(void *a, size_t len, int prot)` | `mm/vm.c` |
| `house-hal-aarch64` | `house_vm_demand_single` | `int house_vm_demand_single(void)` | `mm/vm.c` |
| `house-hal-aarch64` | `house_vm_demand_100` | `int house_vm_demand_100(void)` | `mm/vm.c` |
| `house-hal-aarch64` | `house_puts_after` | `void house_puts_after(void)` | `mm/vm.c` |

### `svc.rs` + `ipc.rs` — `svc.c` / `svc.h` / `ipc.c` / `ipc.h`

EL0 `svc #imm` dispatch (`WRITE 0x01`/`EXIT 0x02`, `IPC 0x10..0x14` via
Endpoint). Unknown `imm` is rejected; user pointers are validated before copy.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_svc_dispatch` | `int64_t house_svc_dispatch(uint32_t imm, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t *gpr)` | `svc.c` |
| `house-hal-aarch64` | `house_set_exit` | `void house_set_exit(int code)` | `svc.c` |
| `house-hal-aarch64` | `house_get_exit_code` | `int house_get_exit_code(void)` | `svc.c` |
| `house-hal-aarch64` | `house_clear_exit` | `void house_clear_exit(void)` | `svc.c` |
| `house-hal-aarch64` | `house_is_exited` | `int house_is_exited(void)` | `svc.c` |
| `house-hal-aarch64` | `house_ipc_svc_dispatch` | `int64_t house_ipc_svc_dispatch(uint32_t op, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3)` | `ipc.c` |
| `house-hal-aarch64` | `house_ipc_copy_msg` | `void house_ipc_copy_msg(const void *src, void *dst, size_t len)` | `ipc.c` |

### `smp.rs` — SMP hotplug (new, Tracks S+H)

`house_smp_up` / `house_smp_down` drive the PSCI OFF→ON cycle (`CPU_OFF`
self-off via SGI 7 remote handshake, `CPU_ON` re-entry through
`secondary_entry` with epoch-guarded re-init); `house_smp_online` reports the
live mask and `house_smp_should_off` is polled by the target's SGI 7 handler
in `house-boot` (`c_start.rs`). Range checks use `checked_shl` (no
`1u32 << 32` edge); core 0 down is refused.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `house_smp_online` | `uint32_t house_smp_online(void)` | `smp.rs` (new) |
| `house-hal-aarch64` | `house_smp_up` | `int house_smp_up(uint32_t core)` | `smp.rs` (new) |
| `house-hal-aarch64` | `house_smp_down` | `int house_smp_down(uint32_t core)` | `smp.rs` (new) |
| `house-hal-aarch64` | `house_smp_should_off` | `int house_smp_should_off(uint32_t core)` | `smp.rs` (new) |

### `psci.rs` — `psci.c` / `psci.h`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `psci_cpu_on` | `int64_t psci_cpu_on(uint64_t mpidr, uint64_t entry, uint64_t ctx)` | `psci.c` |
| `house-hal-aarch64` | `psci_affinity_info` | `int64_t psci_affinity_info(uint64_t mpidr, uint64_t lowest)` | `psci.c` |
| `house-hal-aarch64` | `psci_system_off` | `void psci_system_off(void)` | `psci.c` |
| `house-hal-aarch64` | `psci_system_reset` | `void psci_system_reset(void)` | `psci.c` |
| `house-hal-aarch64` | `psci_cpu_off` | `int64_t psci_cpu_off(void)` | `psci.c` |

### `dtb` / `detect` / `probe` — `house_dtb.c` / `house_detect.c` / `house_probe.c`

RAM auto-detect: DTB `reg` (via `x0`) → open-ended fault probe (double from
128M, TCR-bounded) → `512M` fallback. No build-time LIMIT vars, no geometry
caps — `-m` is the only knob. DTB sums use `checked_add` (overflow → 0);
`stack_top = BASE+ram-2M` via checked math. SMP is DTB → max(DTB,PSCI,GICR),
bounded only by the 32-entry HW tables.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `fdt_valid` | `int fdt_valid(const void *dtb)` | `house_dtb.c` |
| `house-hal-aarch64` | `fdt_get_ram_bytes` | `uint64_t fdt_get_ram_bytes(const void *dtb)` | `house_dtb.c` |
| `house-hal-aarch64` | `fdt_ram_bank_count` | `int fdt_ram_bank_count(const void *dtb)` | `house_dtb.c` (new) |
| `house-hal-aarch64` | `fdt_get_ram_bank` | `int fdt_get_ram_bank(const void *dtb, int i, uint64_t *base, uint64_t *size)` | `house_dtb.c` (new) |
| `house-hal-aarch64` | `fdt_get_cpu_count` | `int fdt_get_cpu_count(const void *dtb)` | `house_dtb.c` |
| `house-hal-aarch64` | `house_detect_early` | `void house_detect_early(void)` | `house_detect.c` |
| `house-hal-aarch64` | `house_detect_late` | `void house_detect_late(void)` | `house_detect.c` |
| `house-hal-aarch64` | `house_smp_detect_psci` | `int house_smp_detect_psci(void)` | `house_detect.c` |
| `house-hal-aarch64` | `house_smp_detect_gicr` | `int house_smp_detect_gicr(void)` | `house_detect.c` |
| `house-hal-aarch64` | `house_ram_probe` | `uint64_t house_ram_probe(void)` | `house_probe.c` |
| `house-hal-aarch64` | `house_ram_bytes` | `uint64_t house_ram_bytes` | `house_detect.c` |
| `house-hal-aarch64` | `house_boot_stack_top` | `uint64_t house_boot_stack_top` | `house_detect.c` |
| `house-hal-aarch64` | `house_smp` | `int house_smp` | `house_detect.c` |
| `house-hal-aarch64` | `house_ram_source` | `const char *house_ram_source` | `house_detect.c` |

### `virtio` — `virtio_transport.c` / `virtio_blk.c` / `virtio_net.c` / `virtio_probe.c`

Flush discipline (audited Track D): `dc cvac` (flush-before-notify) on every
touched TX/descriptor/avail range, `dc ivac` (invalidate-before-read) on every
device-written RX/used range, `dsb sy` after each range op. Only touched ranges
are flushed (64 B lines from `pa & !63` to `pa+len`, `checked_add`).

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-hal-aarch64` | `virtio_probe_slot` | `int virtio_probe_slot(int slot, uint32_t *device_id, uint32_t *vendor_id, uint32_t *version)` | `virtio_probe.c` |
| `house-hal-aarch64` | `virtio_transport_init` | `int virtio_transport_init(int slot, uint32_t *dev_features_lo, uint32_t *dev_features_hi)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_set_features` | `int virtio_transport_set_features(int slot, uint64_t wanted)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_get_status` | `int virtio_transport_get_status(int slot, uint32_t *status)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_set_status` | `int virtio_transport_set_status(int slot, uint32_t status)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_queue_max` | `int virtio_transport_queue_max(int slot, uint32_t *max)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_queue_max_q` | `int virtio_transport_queue_max_q(int slot, int qidx, uint32_t *max)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_queue_setup` | `int virtio_transport_queue_setup(int slot, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_queue_setup_q` | `int virtio_transport_queue_setup_q(int slot, int qidx, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_notify` | `int virtio_transport_notify(int slot, uint32_t qidx)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_interrupt_status` | `uint32_t virtio_transport_interrupt_status(int slot)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_ack` | `void virtio_transport_ack(int slot, uint32_t mask)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_transport_dc_flush` | `void virtio_transport_dc_flush(uint64_t pa, size_t len)` | `virtio_transport.c` |
| `house-hal-aarch64` | `virtio_page_pa` | `uint64_t virtio_page_pa(void *p)` | `virtio_probe.c` |
| `house-hal-aarch64` | `virtio_blk_save_queue` | `void virtio_blk_save_queue(int slot, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_blk_reset_slot` | `void virtio_blk_reset_slot(int slot)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_blk_invalidate` | `void virtio_blk_invalidate(uint64_t pa, size_t len)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_blk_probe_capacity` | `int virtio_blk_probe_capacity(int slot, uint64_t *capacity_sectors)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_blk_submit_read` | `int virtio_blk_submit_read(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_blk_submit_write` | `int virtio_blk_submit_write(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_blk_poll_used` | `int virtio_blk_poll_used(int slot, uint32_t *out_id, uint8_t *out_status)` | `virtio_blk.c` |
| `house-hal-aarch64` | `virtio_net_save_queues` | `int virtio_net_save_queues(int slot, uint64_t rx_desc, uint64_t rx_avail, uint64_t rx_used, uint64_t tx_desc, uint64_t tx_avail, uint64_t tx_used, uint32_t qsize_rx, uint32_t qsize_tx)` | `virtio_net.c` |
| `house-hal-aarch64` | `virtio_net_invalidate` | `void virtio_net_invalidate(uint64_t pa, size_t len)` | `virtio_net.c` |
| `house-hal-aarch64` | `virtio_net_probe_mac` | `int virtio_net_probe_mac(int slot, uint8_t mac[6])` | `virtio_net.c` |
| `house-hal-aarch64` | `virtio_net_submit_rx` | `int virtio_net_submit_rx(int slot, uint64_t data_pa, uint32_t len, uint32_t *req_id)` | `virtio_net.c` |
| `house-hal-aarch64` | `virtio_net_submit_tx` | `int virtio_net_submit_tx(int slot, uint64_t hdr_pa, uint64_t data_pa, uint32_t data_len, uint32_t *req_id)` | `virtio_net.c` |
| `house-hal-aarch64` | `virtio_net_poll_used` | `int virtio_net_poll_used(int slot, int qidx, uint32_t *out_id, uint32_t *out_len)` | `virtio_net.c` |
| `house-hal-aarch64` | `virtio_con_save_queues` | `int virtio_con_save_queues(int slot, uint64_t rx_desc, uint64_t rx_avail, uint64_t rx_used, uint64_t tx_desc, uint64_t tx_avail, uint64_t tx_used, uint32_t qsize_rx, uint32_t qsize_tx)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_invalidate` | `void virtio_con_invalidate(uint64_t pa, size_t len)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_reset_slot` | `void virtio_con_reset_slot(int slot)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_submit_rx` | `int virtio_con_submit_rx(int slot, uint64_t data_pa, uint32_t len, uint32_t *req_id)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_submit_tx` | `int virtio_con_submit_tx(int slot, uint64_t data_pa, uint32_t data_len, uint32_t *req_id)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_poll_used` | `int virtio_con_poll_used(int slot, int qidx, uint32_t *out_id, uint32_t *out_len)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_max_ports` | `int virtio_con_max_ports(int slot, uint32_t *out_ports)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_save_ctrl_queues` | `int virtio_con_save_ctrl_queues(int slot, uint64_t crx_desc, uint64_t crx_avail, uint64_t crx_used, uint64_t ctx_desc, uint64_t ctx_avail, uint64_t ctx_used, uint32_t qsize_crx, uint32_t qsize_ctx)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_submit_ctrl_rx` | `int virtio_con_submit_ctrl_rx(int slot, uint64_t data_pa, uint32_t len, uint32_t *req_id)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_submit_ctrl_tx` | `int virtio_con_submit_ctrl_tx(int slot, uint64_t data_pa, uint32_t data_len, uint32_t *req_id)` | `virtio_con.c` |
| `house-hal-aarch64` | `virtio_con_set_port_queues` | `int virtio_con_set_port_queues(int slot, uint32_t rx_qidx, uint32_t tx_qidx)` | `virtio_con.c` |

### `c_start` / `exception` — `house-boot` (`global_asm!` + `c_start.rs`)

`_start`, `secondary_entry`, `vectors`, `house_enter_el0`,
`svc_exit_trampoline`, and `__boot_dtb` are emitted by `global_asm!`
(`entry.rs`, `exception.rs`), not by `#[no_mangle]` functions — they resolve
at `ld -T build/aarch64.ld` exactly like the old `start.S` labels.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-boot` | `c_start` | `void c_start(void)` | `c_start.c` → `c_start.rs` |
| `house-boot` | `c_start_secondary` | `void c_start_secondary(uint64_t core_id)` | `c_start.c` → `c_start.rs` |
| `house-boot` | `c_handle_sync` | `uint64_t c_handle_sync(uint64_t esr, uint64_t far, uint64_t elr, uint64_t *gpr, void *fpi)` | `c_start.c` → `c_start.rs` |
| `house-boot` | `c_handle_irq` | `void c_handle_irq(uint64_t *gpr, void *fpi)` | `c_start.c` → `c_start.rs` |
| `house-boot` | `fatal_exception` | `void fatal_exception(void)` | `c_start.c` → `c_start.rs` |
| `house-boot` | `house_smp_n` | `volatile int house_smp_n` | `c_start.c` → `c_start.rs` |
| `house-boot` | `house_smp_online_mask` | `volatile uint32_t house_smp_online_mask` | `c_start.c` → `c_start.rs` |
| `house-boot` | `vectors` | `vectors` (VBAR_EL1) | `start.S` → `exception.rs` `global_asm!` |
| `house-boot` | `_start` | `ENTRY _start` | `start.S` + `aarch64.ld` → `entry.rs` `global_asm!` |
| `house-boot` | `secondary_entry` | `secondary_entry` (4K-aligned) | `start.S` → `entry.rs` `global_asm!` |
| `house-boot` | `house_enter_el0` | `void house_enter_el0(uint64_t entry, uint64_t sp, void *pdir, uint64_t asid)` | `start.S` → `exception.rs` `global_asm!` |
| `house-boot` | `svc_exit_trampoline` | `void svc_exit_trampoline(void)` | `start.S` → `exception.rs` `global_asm!` |
| `house-boot` | `__boot_dtb` | `uint64_t __boot_dtb` | `start.S` → `entry.rs` `global_asm!` |
| `house-boot` | `__rela_start` / `__rela_end` | `__rela_start`, `__rela_end` | `aarch64.ld` |
| `house-boot` | `__bss_start` / `__bss_end` | `__bss_start`, `__bss_end` | `aarch64.ld` |
| `house-boot` | `__early_stacks_*` / `__heap_base` / `__ram_base` | linker symbols | `aarch64.ld` |
| `house-boot` | `__init_array_start` / `__fini_array_start` | init/fini bounds | `aarch64.ld` |

## house-libc (`tinylibc/*` port — complete)

Single owner of `#[panic_handler]` (`panic.rs`) and `__stack_chk_guard` /
`__stack_chk_fail` (SOTA Rust 03). `house_rts_tick` is the timer ticker seam
called from the HAL rearm path; `house_uptime_ns` backs timerfd pacing.

### `sys` — `tinylibc/sys.c` → `sys/mod.rs` + `sys/time.rs` + `sys/errno.rs`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `__errno_location` | `int *__errno_location(void)` | `tinylibc/sys.c` |
| `house-libc` | `write` | `ssize_t write(int fd, const void *buf, size_t n)` | `tinylibc/sys.c` |
| `house-libc` | `read` | `ssize_t read(int fd, void *buf, size_t n)` | `tinylibc/sys.c` |
| `house-libc` | `open` | `int open(const char *path, int flags, ...)` | `tinylibc/sys.c` |
| `house-libc` | `close` | `int close(int fd)` | `tinylibc/sys.c` |
| `house-libc` | `lseek` | `off_t lseek(int fd, off_t off, int whence)` | `tinylibc/sys.c` |
| `house-libc` | `fcntl` | `int fcntl(int fd, int cmd, ...)` | `tinylibc/sys.c` |
| `house-libc` | `ioctl` | `int ioctl(int fd, unsigned long req, ...)` | `tinylibc/sys.c` |
| `house-libc` | `isatty` | `int isatty(int fd)` | `tinylibc/sys.c` |
| `house-libc` | `fstat` | `int fstat(int fd, struct stat *st)` | `tinylibc/sys.c` |
| `house-libc` | `stat` | `int stat(const char *path, struct stat *st)` | `tinylibc/sys.c` |
| `house-libc` | `unlink` | `int unlink(const char *path)` | `tinylibc/sys.c` |
| `house-libc` | `chdir` | `int chdir(const char *path)` | `tinylibc/sys.c` |
| `house-libc` | `getcwd` | `char *getcwd(char *buf, size_t n)` | `tinylibc/sys.c` |
| `house-libc` | `pipe` | `int pipe(int fds[2])` | `tinylibc/sys.c` |
| `house-libc` | `getenv` | `char *getenv(const char *n)` | `tinylibc/sys.c` |
| `house-libc` | `environ` | `char **environ` | `tinylibc/sys.c` |
| `house-libc` | `eventfd` | `int eventfd(unsigned initval, int flags)` | `tinylibc/sys.c` |
| `house-libc` | `eventfd_write` | `int eventfd_write(int fd, unsigned long value)` | `tinylibc/sys.c` |
| `house-libc` | `eventfd_read` | `int eventfd_read(int fd, unsigned long *value)` | `tinylibc/sys.c` |
| `house-libc` | `epoll_create` | `int epoll_create(int size)` | `tinylibc/sys.c` |
| `house-libc` | `epoll_create1` | `int epoll_create1(int flags)` | `tinylibc/sys.c` |
| `house-libc` | `epoll_ctl` | `int epoll_ctl(int epfd, int op, int fd, void *ev)` | `tinylibc/sys.c` |
| `house-libc` | `epoll_wait` | `int epoll_wait(int epfd, void *events, int maxevents, int timeout)` | `tinylibc/sys.c` |
| `house-libc` | `epoll_pwait` | `int epoll_pwait(int epfd, void *events, int maxevents, int timeout, const void *sigmask)` | `tinylibc/sys.c` |
| `house-libc` | `epoll_pwait2` | `int epoll_pwait2(int epfd, void *events, int maxevents, const struct timespec *ts, const void *sigmask)` | `tinylibc/sys.c` |
| `house-libc` | `dup` / `dup2` | `int dup(int fd)` / `int dup2(int oldfd, int newfd)` | `tinylibc/sys.c` |
| `house-libc` | `getpid` / `getuid` / `geteuid` / `getgid` / `getegid` | `pid_t getpid(void)` etc. | `tinylibc/sys.c` |
| `house-libc` | `clock_gettime` | `int clock_gettime(clockid_t clk, struct timespec *tp)` | `tinylibc/sys.c` |
| `house-libc` | `clock_getres` | `int clock_getres(clockid_t clk, struct timespec *res)` | `tinylibc/sys.c` |
| `house-libc` | `gettimeofday` | `int gettimeofday(struct timeval *tv, void *tz)` | `tinylibc/sys.c` |
| `house-libc` | `times` | `clock_t times(struct tms *t)` | `tinylibc/sys.c` |
| `house-libc` | `sigemptyset` / `sigfillset` / `sigaddset` / `sigdelset` / `sigismember` | signal set ops | `tinylibc/sys.c` |
| `house-libc` | `sigaction` | `int sigaction(int sig, const struct sigaction *act, struct sigaction *old)` | `tinylibc/sys.c` |
| `house-libc` | `sigprocmask` | `int sigprocmask(int how, const sigset_t *set, sigset_t *old)` | `tinylibc/sys.c` |
| `house-libc` | `raise` / `kill` | `int raise(int sig)` / `int kill(pid_t pid, int sig)` | `tinylibc/sys.c` |
| `house-libc` | `house_rts_tick` | `void house_rts_tick(void)` | `tinylibc/sys.c` → `sys/mod.rs` (ticker seam) |
| `house-libc` | `house_uptime_ns` | `uint64_t house_uptime_ns(void)` | `tinylibc/sys.c` → `sys/time.rs` (timerfd pacing) |
| `house-libc` | `setitimer` / `getitimer` | `int setitimer(int which, const struct itimerval *nv, struct itimerval *ov)` | `tinylibc/sys.c` |
| `house-libc` | `timer_create` / `timer_settime` / `timer_gettime` / `timer_getoverrun` / `timer_delete` | POSIX timers | `tinylibc/sys.c` |
| `house-libc` | `timerfd_create` / `timerfd_settime` / `timerfd_gettime` | `int timerfd_create(int clockid, int flags)` etc. | `tinylibc/sys.c` |
| `house-libc` | `house_timerfd_due` | `int house_timerfd_due(int fd)` | `tinylibc/sys.c` |
| `house-libc` | `house_fd_pipe_readable` | `int house_fd_pipe_readable(int fd)` | `tinylibc/sys.c` |
| `house-libc` | `sysconf` / `getpagesize` | `long sysconf(int name)` / `int getpagesize(void)` | `tinylibc/sys.c` |
| `house-libc` | `exit` / `_exit` / `_Exit` / `abort` | `void exit(int status)` etc. `void abort(void)` | `tinylibc/sys.c` |
| `house-libc` | `__stack_chk_guard` | `uintptr_t __stack_chk_guard = 0xdeadbeefcafef00dULL` | `tinylibc/sys.c` |
| `house-libc` | `__stack_chk_fail` | `void __stack_chk_fail(void)` | `tinylibc/sys.c` |
| `house-libc` | `strtol` / `strtoul` / `atoi` / `strerror` | `long strtol(const char *n, char **end, int base)` etc. | `tinylibc/sys.c` |

### `threads` — `tinylibc/threads.c` + `threads.h` + `switch.S` + `tls*.S/.c`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `house_threads_init` | `void house_threads_init(void)` | `threads.c` |
| `house-libc` | `house_thread_init_main` | `void house_thread_init_main(void)` | `threads.c` |
| `house-libc` | `house_threads_init_secondary` | `void house_threads_init_secondary(uint32_t core)` | `threads.c` |
| `house-libc` | `house_threads_rebalance` | `void house_threads_rebalance(void)` | `threads.c` |
| `house-libc` | `house_thread_current` | `house_thread_t *house_thread_current(void)` | `threads.c` |
| `house-libc` | `house_sched_lock_acquire` / `house_sched_lock_release` | `void house_sched_lock_acquire(void)` etc. | `threads.c` |
| `house-libc` | `house_sched_block` / `house_sched_yield` / `house_sched_kick` / `house_sched_ipi_handler` / `house_sched_maybe_preempt_from_isr` / `house_sched_wake` | scheduler ops | `threads.c` |
| `house-libc` | `house_tls_alloc` | `void *house_tls_alloc(void)` | `threads.c` |
| `house-libc` | `house_thread_switch` | `void house_thread_switch(house_thread_t *old, house_thread_t *next)` | `switch.S` |
| `house-libc` | `pthread_create` / `pthread_join` / `pthread_detach` / `pthread_exit` / `pthread_self` / `pthread_kill` / `pthread_setname_np` | pthreads | `threads.c` |
| `house-libc` | `pthread_mutex_init` / `pthread_mutex_destroy` / `pthread_mutex_lock` / `pthread_mutex_trylock` / `pthread_mutex_unlock` | mutex | `threads.c` |
| `house-libc` | `pthread_cond_init` / `pthread_cond_destroy` / `pthread_cond_signal` / `pthread_cond_broadcast` / `pthread_cond_wait` / `pthread_cond_timedwait` | condvar | `threads.c` |
| `house-libc` | `pthread_condattr_init` / `pthread_condattr_destroy` / `pthread_condattr_setclock` | condattr | `threads.c` |
| `house-libc` | `pthread_attr_init` / `pthread_attr_destroy` / `pthread_attr_getstacksize` / `pthread_attr_setaffinity_np` / `pthread_attr_getaffinity_np` / `pthread_setaffinity_np` / `pthread_getaffinity_np` | attr/affinity | `threads.c` |
| `house-libc` | `sched_yield` / `sched_getaffinity` / `sched_setaffinity` | `int sched_yield(void)` etc. | `threads.c` |
| `house-libc` | `pthread_sigmask` | `int pthread_sigmask(int how, const sigset_t *set, sigset_t *old)` | `threads.c` |
| `house-libc` | `nanosleep` / `poll` / `select` / `pause` | `int nanosleep(...)` etc. | `threads.c` |
| `house-libc` | `house_spin_*` | `house_spin_init/lock/trylock/unlock` (inline in `spinlock.h`) | `spinlock.h` |

### `alloc` — `tinylibc/alloc.c` + `mm/vm.c` (POSIX `mmap` family)

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `malloc` | `void *malloc(size_t n)` | `tinylibc/alloc.c` |
| `house-libc` | `free` | `void free(void *p)` | `tinylibc/alloc.c` |
| `house-libc` | `calloc` | `void *calloc(size_t a, size_t b)` | `tinylibc/alloc.c` |
| `house-libc` | `realloc` | `void *realloc(void *old, size_t n)` | `tinylibc/alloc.c` |
| `house-libc` | `posix_memalign` | `int posix_memalign(void **out, size_t align, size_t n)` | `tinylibc/alloc.c` |
| `house-libc` | `strdup` | `char *strdup(const char *s)` | `tinylibc/alloc.c` |
| `house-libc` | `mmap` | `void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off)` | `mm/vm.c` (+ `alloc.c` bump) |
| `house-libc` | `munmap` | `int munmap(void *a, size_t len)` | `mm/vm.c` |
| `house-libc` | `mprotect` | `int mprotect(void *a, size_t len, int prot)` | `mm/vm.c` |

### `mem` — `tinylibc/mem.c` → `mem.rs`

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `memcpy` | `void *memcpy(void *dst, const void *src, size_t n)` | `tinylibc/mem.c` |
| `house-libc` | `memmove` | `void *memmove(void *dst, const void *src, size_t n)` | `tinylibc/mem.c` |
| `house-libc` | `memset` | `void *memset(void *dst, int c, size_t n)` | `tinylibc/mem.c` |
| `house-libc` | `memcmp` | `int memcmp(const void *a, const void *b, size_t n)` | `tinylibc/mem.c` |
| `house-libc` | `memchr` | `void *memchr(const void *s, int c, size_t n)` | `tinylibc/mem.c` |
| `house-libc` | `strlen` | `size_t strlen(const char *s)` | `tinylibc/mem.c` |
| `house-libc` | `strnlen` | `size_t strnlen(const char *s, size_t maxlen)` | `tinylibc/mem.c` |
| `house-libc` | `strcmp` / `strncmp` | `int strcmp(const char *a, const char *b)` etc. | `tinylibc/mem.c` |
| `house-libc` | `strcpy` / `strncpy` / `strcat` | `char *strcpy(char *dst, const char *src)` etc. | `tinylibc/mem.c` |
| `house-libc` | `strchr` / `strrchr` | `char *strchr(const char *s, int c)` etc. | `tinylibc/mem.c` |
| `house-libc` | `strcasecmp` | `int strcasecmp(const char *a, const char *b)` | `tinylibc/mem.c` |

### `stdio` — `tinylibc/stdio.c` → `stdio.rs` (ported)

`stdin`/`stdout`/`stderr` plus the `printf` family; formatting is minimal
(freestanding) — full `vfprintf` formatting stays out of scope.

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `stdin` / `stdout` / `stderr` | `FILE *stdin` etc. | `tinylibc/stdio.c` |
| `house-libc` | `printf` / `vprintf` | `int printf(const char *fmt, ...)` | `tinylibc/stdio.c` |
| `house-libc` | `fprintf` / `vfprintf` | `int fprintf(FILE *f, const char *fmt, ...)` | `tinylibc/stdio.c` |
| `house-libc` | `sprintf` / `snprintf` / `vsnprintf` | `int snprintf(char *s, size_t n, const char *fmt, ...)` etc. | `tinylibc/stdio.c` |
| `house-libc` | `puts` / `fputs` / `putchar` / `fputc` | `int puts(const char *s)` etc. | `tinylibc/stdio.c` |
| `house-libc` | `fwrite` / `fflush` | `size_t fwrite(const void *p, size_t s, size_t n, FILE *f)` etc. | `tinylibc/stdio.c` |

### `getopt` — `tinylibc/getopt.c` → `getopt.rs` (ported)

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `optind` / `opterr` / `optopt` / `optarg` | `int optind` etc. `char *optarg` | `tinylibc/getopt.c` |
| `house-libc` | `getopt` / `getopt_long` / `getopt_long_only` | `int getopt(int argc, char **argv, const char *opts)` etc. | `tinylibc/getopt.c` |

### `compat` — `tinylibc/compat.c` → `compat.rs` (ported)

Host-compat shims the RTS link needs: `stat64`/`fstat64`/`lstat64`,
`dl*` stubs, `__*_chk` fortify stubs, file/term/process/locale/iconv/regex
stubs. Representative (see `compat.rs` for the full list):

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `stat64` / `fstat64` / `lstat` / `lstat64` | `int stat64(const char *p, struct stat64 *st)` etc. | `tinylibc/compat.c` |
| `house-libc` | `dlopen` / `dlsym` / `dlclose` / `dlerror` / `dlinfo` / `dl_iterate_phdr` | `void *dlopen(const char *f, int mode)` etc. | `tinylibc/compat.c` |
| `house-libc` | `__fprintf_chk` / `__printf_chk` / `__memcpy_chk` / `__memmove_chk` / `__memset_chk` / `__xpg_strerror_r` / `__isoc99_sscanf` / `__getauxval` / `__assert_fail` / `__ctype_b_loc` | fortify/host stubs | `tinylibc/compat.c` |
| `house-libc` | `fopen` / `fclose` / `fread` / `fgets` / `feof` / `fseek` / `ftell` / `getc` / `getline` | `FILE *fopen(const char *p, const char *m)` etc. | `tinylibc/compat.c` |
| `house-libc` | `setmntent` / `endmntent` / `hasmntopt` / `getmntent_r` | mntent stubs | `tinylibc/compat.c` |
| `house-libc` | `access` / `chmod` / `creat` / `link` / `mkdir` / `mknod` / `mkfifo` / `mkstemp` / `memfd_create` / `umask` / `utime` / `ftruncate` / `ftruncate64` / `qsort` / `statfs` | POSIX stubs | `tinylibc/compat.c` |
| `house-libc` | `getrlimit` / `getrusage` / `clock_getcpuclockid` / `time` / `ctime_r` / `getauxval` / `getppid` / `fork` / `waitpid` / `atexit` / `syscall` / `madvise` | process/time stubs | `tinylibc/compat.c` |
| `house-libc` | `tcgetattr` / `tcsetattr` / `dirname` / `stpcpy` / `strtoull` | misc stubs | `tinylibc/compat.c` |
| `house-libc` | `regcomp` / `regexec` / `regfree` | regex stubs | `tinylibc/compat.c` |
| `house-libc` | `newlocale` / `freelocale` / `uselocale` / `setlocale` / `nl_langinfo` / `iconv_open` / `iconv` / `iconv_close` | locale/iconv stubs | `tinylibc/compat.c` |

### `mathmin` — `tinylibc/mathmin.c` → `mathmin.rs` (ported)

Freestanding `libm` subset (`ldexp`, `log`/`log2`, `exp`, `pow`, `sin`,
`cos`, `tan`, `sqrt`, `fabs`, `floor`, `ceil`, `trunc`, `round`, `strtod`,
`asinh`/`asinhf`, `acosh`/`acoshf`, `atanh`/`atanhf`, `cbrt`, `hypot`,
`fmax`, `fmin`, `fmod`).

### `c_print` — `tinylibc/c_print.c` → `c_print.rs` (ported)

| Crate | Symbol | C signature | Source |
|-------|--------|-------------|--------|
| `house-libc` | `c_print` | `void c_print(const char *s)` | `tinylibc/c_print.c` |

## Globals resolved by `aarch64.ld`

These are linker-defined symbols the HAL references as `extern`; Rust must not
define them — they remain in `aarch64.ld`. They are listed here because `nm`
shows them as `U` until `ld -T build/aarch64.ld` links.

`__heap_base` (`0x42000000`), `__ram_base` (`0x40000000`), `__kernel_virt_base`,
`__bss_start`/`__bss_end`, `__rela_start`/`__rela_end`, `__init_array_start`/`__fini_array_start`,
`__early_stacks_base`/`__early_stacks_top`/`__early_stacks_top_core0`/`__early_stacks_max_top`.

## Audit notes

```sh
# Documented symbols check (Symbol column):
grep -E '^\| (house-|uart_|buddy_|psci_|virtio_|fdt_|c_start|vectors|_start|secondary_entry|house_enter_el0|svc_exit_trampoline|__boot_dtb|malloc|free|calloc|realloc|mmap|munmap|mprotect|memcpy|printf|getopt|c_print|optind|stdin|pthread_|sched_|clock_|timer|epoll_|eventfd|pipe|nanosleep|poll|select|read|write|open|close|stat|sysconf|exit|abort|strtol|socket)' rust/c-abi.md | awk -F'|' '{print $3}' | tr -d ' ' | sort -u | head -60
# Rust export audit (post-port: HAL + boot + libc):
grep -rn "#\[no_mangle\]" rust/crates --include="*.rs" | wc -l   # ~400 (full libc port)
grep -rn "pub unsafe extern \"C\" fn" rust/crates/house-hal-aarch64/src rust/crates/house-boot/src --include="*.rs" | wc -l
# global_asm! labels (not no_mangle):
grep -n "\.global" rust/crates/house-boot/src/entry.rs rust/crates/house-boot/src/exception.rs
# After link, no unexpected U should remain (RTS/glibc names excluded):
# nm platform/aarch64/build/house.elf | grep " U " | grep -v "HsFFI\|libHS" || echo ok
# Single-owner gates (ci-tinylibc-parity.sh):
grep -rn "panic_handler" rust/crates --include="*.rs"   # exactly 1 (house-libc panic.rs)
```

`HsFFI.h` / `ghc --print-libdir` RTS archives are unchanged and linked via
`--start-group $(PRIM_A) ... $(RTS_A) $(FFI_A)` — they are not part of this map.

## `house-hal` trait note

`house-hal` trait groups existing `#[no_mangle]` symbols — no new names.
`house-hal-aarch64` `impl Hal* for AArch64Hal` are `#[inline(always)]` adapters
to the free functions above (no vtable). Verify the `riscv64` feature stub without
breaking the `aarch64` gate:

```sh
cargo build -p house-hal --no-default-features --features riscv64
cargo metadata --manifest-path rust/Cargo.toml | jq '.packages[] | select(.name=="house-hal") | .features'
```

## Rejected alternative

`cbindgen`/`bindgen` from `platform/aarch64/*.h` remains rejected: freestanding
headers are not host-parseable and host `glibc` `stat` layouts differ from
tinylibc `stat` (hence the `stat64`/`fstat64` shims above). Hand-written
`#[repr(C)]` truth with the `nm` gate is the reviewable contract (SOTA Rust 01
minimal API).
