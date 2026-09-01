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

  /* Per-core early stacks: max 16*16K=256K, runtime uses house_boot_stack_top.
      Old HOUSE_SMP_N kept as compat alias for HOUSE_MAX_SMP. */
#ifndef HOUSE_MAX_SMP
#ifdef HOUSE_SMP_N
#define HOUSE_MAX_SMP HOUSE_SMP_N
#else
#define HOUSE_MAX_SMP 16
#endif
#endif
#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N HOUSE_MAX_SMP
#endif
  __early_stacks_base = .;
  __early_stack = .;
  . = ALIGN(16);
  . += HOUSE_MAX_SMP * 16384;
  __early_stacks_top = .;
  __early_stack_top = __early_stacks_base + 16384;
  __early_stack_top_core0 = __early_stack_top;
  __early_stacks_max_top = __early_stacks_top;

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
__kernel_virt_base = 0x40000000; /* TTBR1 identity alias (v1); higher-half 0xFFFFFFC000000000 in Phase 7 */
__heap_base      = 0x42000000;   /* bump malloc / mmap-commit region;
                                     RAM extent itself is compiled in via
                                     HOUSE_RAM_BYTES/BOOT_STACK_TOP from
                                     the top-level Makefile (SPIKE_MEM) */
