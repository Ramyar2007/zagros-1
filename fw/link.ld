OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
  ISRAM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
  DSRAM (rw)  : ORIGIN = 0x10000000, LENGTH = 16K
}
SECTIONS {
  .text   : { *(.text.init) *(.text*) } > ISRAM
  .rodata : { *(.rodata*) *(.srodata*) } > ISRAM
  .data   : { *(.data*) *(.sdata*) } > DSRAM
  __global_pointer$ = ADDR(.data) + 0x800;
  .bss    : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > DSRAM
}
