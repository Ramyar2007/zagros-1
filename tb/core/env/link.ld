OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x00000000;
  .text.init : { *(.text.init) }
  .text : { *(.text*) }
  . = 0x00008000;
  .tohost : { *(.tohost) }
  .data : { *(.data*) *(.sdata*) *(.rodata*) *(.srodata*) }
  .bss : { *(.bss*) *(.sbss*) }
  _end = .;
}
