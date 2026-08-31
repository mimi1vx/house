ENTRY(_start)

PHDRS
{
  text   PT_LOAD FLAGS(5); /* R+X */
  rodata PT_LOAD FLAGS(4); /* R   */
  data   PT_LOAD FLAGS(6); /* R+W */
}

SECTIONS
{
  . = 0x40080000;

  .text : {
    KEEP(*(.text.boot))
    *(.text .text.*)
  } :text

  . = ALIGN(0x1000);
  .rodata : {
    *(.rodata .rodata.* .srodata .srodata.*)
  } :rodata

  . = ALIGN(0x1000);

  /* Static-PIC archives may contribute RELATIVE dynamic relocs; start.S
     applies them before anything runs. */
  .rela.dyn : {
    __rela_start = .;
    *(.rela.dyn .rela.dyn.*)
    __rela_end = .;
  } :data

  /* Debian gcc emits q-register struct copies from .data.rel.ro assuming
     the Linux-style region alignment; honour that explicitly. */
  .data.rel.ro : ALIGN(64) {
    *(.data.rel.ro .data.rel.ro.*)
  } :data

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

  /* Per-core early stacks: SMP_N * 16K, 16-byte aligned.
      Primary uses top of first 16K (__early_stack_top / core0), secondaries
      compute base + (core+1)*16K in start.S. Keep old names as aliases.
      SMP>2 working set is 4G RAM; 512M stays valid for N=2 regression only. */
#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif
  __early_stacks_base = .;
  __early_stack = .;
  . = ALIGN(16);
  . += HOUSE_SMP_N * 16384;
  __early_stacks_top = .;
  __early_stack_top = __early_stacks_base + 16384;
  __early_stack_top_core0 = __early_stack_top;

  /DISCARD/ : {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
    *(.dynamic)
    *(.interp)
    *(.gnu.hash)
    *(.dynsym)
    *(.dynstr)
    *(.gnu.version*)
  }
}

__ram_base       = 0x40000000;   /* guest RAM start (QEMU virt) */
__heap_base      = 0x42000000;   /* bump malloc / mmap-commit region;
                                    RAM extent itself is compiled in via
                                    HOUSE_RAM_BYTES/BOOT_STACK_TOP from
                                    the top-level Makefile (SPIKE_MEM) */
