ENTRY(_start)
PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}
SECTIONS
{
  . = 0x1000000;
  .text : { *(.text*) } :text
  .rodata : { *(.rodata*) } :text
  . = 0x1001000;
  .data : { *(.data*) } :data
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) }
}
