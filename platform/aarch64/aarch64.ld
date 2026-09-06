ENTRY(_start)

PHDRS
{
  text   PT_LOAD FLAGS(5); /* R+X */
  rodata PT_LOAD FLAGS(4); /* R   */
  data   PT_LOAD FLAGS(6); /* R+W */
  tls    PT_TLS  FLAGS(4); /* R   */
}

SECTIONS
{
  . = 0x40080000;

  .text : {
    KEEP(*(.text.boot))
    KEEP(*(.text.boot.*))
    /* Phase 2: Rust global_asm! may emit .text.boot.rust subsection — keep from --gc-sections */
    KEEP(*(.text.boot.rust*))
    KEEP(*(.text.vectors))
    KEEP(*(.text.vectors.*))
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

  /* Static TLS template for the threaded RTS (`__thread` locals, e.g. the
     task pointer in Task.thr_o): without an explicit template + PT_TLS,
     ld.lld rejects the link ("STT_TLS symbol but no SHF_TLS section")
     where GNU ld silently orphans .tbss into the data LOAD. Dual-assigned
     :tls :data so the init template stays inside the flat .bin LOAD image;
     placed before the ASSERT so template bytes count toward the gate. */
  .tls : {
    *(.tdata .tdata.* .gnu.linkonce.td.*)
    *(.tbss .tbss.* .gnu.linkonce.tb.*)
    *(.tcommon)
  } :tls :data
  _tls_base = ADDR(.tls);
  _tls_end = ADDR(.tls) + SIZEOF(.tls);

  /* Image-size gate: the loaded file-image (text+rodata+data — what lands
     in the flat .bin) must stay under 16 MiB. Measured 2026-09-06:
     spike ~7.7 MiB, house ~13.3 MiB (full threaded RTS + kernel closure),
     so the transcribed house-ng 8 MiB bound does not fit house; 16 MiB
     leaves ~20% headroom for floated-GHC/nightly codegen drift. .bss plus
     the 2 MiB early-stacks reservation below are NOLOAD and excluded —
     track them via the `size` report after link instead. */
  ASSERT(. <= 0x41080000, "house image exceeds 16 MiB")

  .bss (NOLOAD) : {
    . = ALIGN(16);
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } :data

  /* Per-core early stacks: 32*64K=2M HW reservation, runtime uses
     house_boot_stack_top - core*64K for the detected core count. */
#define HOUSE_MAX_SMP 32
  __early_stacks_base = .;
  __early_stack = .;
  . = ALIGN(16);
  . += HOUSE_MAX_SMP * 65536;
  __early_stacks_top = .;
  __early_stack_top = __early_stacks_base + 65536;
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
__heap_base      = 0x42000000;   /* bump malloc / mmap-commit region; RAM auto-detected */
