/* Link-time stubs for the freestanding aarch64 C ABI (see rust/c-abi.md).
 *
 * The pure test-suite never executes FFI: decoders, the ELF parser, the
 * image codec and splitPath touch no foreign code at runtime. These
 * definitions exist only so the test binary links on the host.
 * Real libc provides mmap/mprotect/munmap, so they are NOT stubbed here.
 */

typedef unsigned long long u64;

/* Data refs (foreign import "&..."). */
u64 __boot_dtb = 0;
u64 house_boot_stack_top = 0;
u64 house_ram_bytes = 0;
u64 house_ram_source = 0;
u64 house_smp = 0;
u64 max_user_addr = 0;
u64 min_user_addr = 0;

/* Function refs. Signatures are link-only; bodies never run in tests. */
#define STUB(name) long name(void) { return 0; }

STUB(buddy_alloc_page)
STUB(buddy_contains)
STUB(buddy_free_count)
STUB(buddy_free_page)
STUB(buddy_total_count)
STUB(c_print)
STUB(current_pdir)
STUB(fdt_get_ram_bank)
STUB(fdt_ram_bank_count)
STUB(house_asid_for_pdir)
STUB(house_clear_exit)
STUB(house_enter_el0)
STUB(house_get_exit_code)
STUB(house_get_ttbrs)
STUB(house_gic_disable_int)
STUB(house_gic_enable_int)
STUB(house_irq_disable)
STUB(house_irq_enable)
STUB(house_irq_pipe_drain)
STUB(house_irq_pop)
STUB(house_is_exited)
STUB(house_is_ro_page)
STUB(house_mem_stats)
STUB(house_mmu_clone_kernel_l1)
STUB(house_mmu_clone_kernel_l2)
STUB(house_puts_after)
STUB(house_set_recorded_pdir)
STUB(house_smp_down)
STUB(house_smp_online)
STUB(house_smp_up)
STUB(house_tlb_shootdown)
STUB(house_uptime_ns)
STUB(house_uptime_secs)
STUB(house_vm_demand_100)
STUB(house_vm_demand_single)
STUB(init_page_dir)
STUB(invalidate_page)
STUB(psci_system_off)
STUB(psci_system_reset)
STUB(uart_getc_nonblock)
STUB(uart_putc)
STUB(uart_puts)
STUB(virtio_blk_invalidate)
STUB(virtio_blk_poll_used)
STUB(virtio_blk_probe_capacity)
STUB(virtio_blk_reset_slot)
STUB(virtio_blk_save_queue)
STUB(virtio_blk_submit_read)
STUB(virtio_blk_submit_write)
STUB(virtio_con_invalidate)
STUB(virtio_con_max_ports)
STUB(virtio_con_poll_used)
STUB(virtio_con_save_ctrl_queues)
STUB(virtio_con_save_queues)
STUB(virtio_con_set_port_queues)
STUB(virtio_con_submit_ctrl_rx)
STUB(virtio_con_submit_ctrl_tx)
STUB(virtio_con_submit_rx)
STUB(virtio_con_submit_tx)
STUB(virtio_net_invalidate)
STUB(virtio_net_poll_used)
STUB(virtio_net_probe_mac)
STUB(virtio_net_save_queues)
STUB(virtio_net_submit_rx)
STUB(virtio_net_submit_tx)
STUB(virtio_page_pa)
STUB(virtio_probe_slot)
STUB(virtio_transport_ack)
STUB(virtio_transport_dc_flush)
STUB(virtio_transport_get_status)
STUB(virtio_transport_init)
STUB(virtio_transport_interrupt_status)
STUB(virtio_transport_notify)
STUB(virtio_transport_queue_max)
STUB(virtio_transport_queue_max_q)
STUB(virtio_transport_queue_setup)
STUB(virtio_transport_queue_setup_q)
STUB(virtio_transport_set_features)
STUB(virtio_transport_set_status)
