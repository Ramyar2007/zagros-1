// Minimal riscv-tests environment for ZAGROS-1 (machine mode, no MMU/PMP).
// PASS: writes 1 to tohost. FAIL: writes (TESTNUM << 1) | 1. Unexpected trap: writes 0xDEAD_xxx1 (cause in xxx).
#ifndef _ZG_RISCV_TEST_H
#define _ZG_RISCV_TEST_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U .macro init; .endm
#define RVTEST_RV32M .macro init; .endm
#define TESTNUM gp

#define RVTEST_CODE_BEGIN                                   \
        .section .text.init;                                \
        .align  2;                                          \
        .globl _start;                                      \
_start:                                                     \
        la t0, trap_vector; csrw mtvec, t0;                 \
        li TESTNUM, 0;                                      \
        j 1f;                                               \
        .align 2;                                           \
trap_vector:                                                \
        csrr t5, mcause;                                    \
        slli t5, t5, 4; ori t5, t5, 1;                      \
        li t6, 0xDEA00000; or t5, t5, t6;                   \
        la t6, tohost; sw t5, 0(t6);                        \
9:      j 9b;                                               \
1:      init;

#define RVTEST_CODE_END unimp

#define RVTEST_PASS                                         \
        fence; li TESTNUM, 1; la t5, tohost; sw TESTNUM, 0(t5); 8: j 8b;

#define RVTEST_FAIL                                         \
        fence; 7: beqz TESTNUM, 7b; sll TESTNUM, TESTNUM, 1; or TESTNUM, TESTNUM, 1; \
        la t5, tohost; sw TESTNUM, 0(t5); 6: j 6b;

#define EXTRA_DATA
#define RVTEST_DATA_BEGIN EXTRA_DATA .pushsection .tohost,"aw",@progbits; .align 4; .global tohost; tohost: .word 0; .align 4; .popsection; .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
