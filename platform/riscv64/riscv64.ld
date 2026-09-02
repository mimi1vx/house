/* riscv64 placeholder — sibling to platform/aarch64/aarch64.ld (not linked yet).
 * Proves house-hal trait extension point: house-hal-riscv64 will use this.
 * QEMU: -M virt-riscv (PLIC 0x0c000000 vs GICv3 0x08000000, Sv39 SATP vs TTBR0/TTBR1).
 */
ENTRY(_start)

PHDRS
{
  text   PT_LOAD FLAGS(5);
  rodata PT_LOAD FLAGS(4);
  data   PT_LOAD FLAGS(6);
}

SECTIONS
{
  . = 0x40080000;

  .text : {
    KEEP(*(.text.boot))
    KEEP(*(.text.boot.*))
    KEEP(*(.text.boot.rust*))
    *(.text .text.*)
  } :text

  . = ALIGN(0x1000);
  .rodata : {
    *(.rodata .rodata.* .srodata .srodata.*)
  } :rodata

  . = ALIGN(0x1000);
  .data : {
    __init_array_start = .;
    KEEP(*(.init_array*))
    __init_array_end = .;
    __fini_array_start = .;
    KEEP(*(.fini_array*))
    __fini_array_end = .;
    *(.data .data.* .sdata .sdata.*)
    *(.got .got.* .got.plt)
  } :data

  .bss (NOLOAD) : {
    . = ALIGN(16);
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } :data

  /DISCARD/ : {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
  }
}

/* Compat symbols — riscv64 HAL will define house_ram_bytes/house_smp_n via dtb/detect analog. */
__ram_base        = 0x40000000;
__kernel_virt_base = 0x40000000;
__heap_base       = 0x42000000;
