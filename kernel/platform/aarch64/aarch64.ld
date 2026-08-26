ENTRY(_start)

SECTIONS
{
  . = 0x40080000;

  .text : {
    KEEP(*(.text.boot))
    *(.text .text.*)
  }

  .rodata : {
    *(.rodata .rodata.* .srodata .srodata.*)
  }

  /* Static-PIC archives may contribute RELATIVE dynamic relocs; start.S
     applies them before anything runs. */
  .rela.dyn : {
    __rela_start = .;
    *(.rela.dyn .rela.dyn.*)
    __rela_end = .;
  }

  /* Debian gcc emits q-register struct copies from .data.rel.ro assuming
     the Linux-style region alignment; honour that explicitly. */
  .data.rel.ro : ALIGN(64) {
    *(.data.rel.ro .data.rel.ro.*)
  }

  .data : {
    __init_array_start = .;
    KEEP(*(.init_array*))
    __init_array_end = .;
    __fini_array_start = .;
    KEEP(*(.fini_array*))
    __fini_array_end = .;
    *(.data .data.* .sdata .sdata.*)
    *(.got .got.* .got.plt)
  }

  .bss (NOLOAD) : {
    . = ALIGN(16);
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  }

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

__heap_base      = 0x42000000;   /* bump mmap / malloc region (low bank) */
__heap_end       = 0xBC000000;
boot_stack_bottom = 0x7F000000;   /* high bank for mmap lives at
                                    0x4000000000+ (see tinylibc/alloc.c) */
boot_stack_top    = 0x80000000;
