# ZAGROS-1 startup: stack at the top of D-SRAM, clear .bss, call main, report to POST (bit31 = done), park.
    .section .text.init
    .globl _start
_start:
    li   sp, 0x10004000
    .option push
    .option norelax                 # gp must not be computed relative to itself
    la   gp, __global_pointer$
    .option pop
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  call main
    li   t0, 0x80000000
    or   a0, a0, t0
    li   t1, 0x4000F000
    sw   a0, 0(t1)
3:  wfi
    j    3b
