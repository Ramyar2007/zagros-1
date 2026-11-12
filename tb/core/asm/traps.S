# ZAGROS-1 custom: exceptions + CSRs. Each case sets TESTNUM; the handler checks mcause/mepc/mtval, skips the
# faulting instruction (mepc += length) and returns with mret.
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN
        la t0, handler
        csrw mtvec, t0
        li s1, 0                    # expected mcause
        li s2, 0                    # expected mepc
        li s3, 0                    # expected mtval
        li s4, 0                    # traps seen

        # 1 ecall
        li TESTNUM, 1
        li s1, 11
        la s2, t_ecall
        li s3, 0
t_ecall: ecall
        li t0, 1
        bne s4, t0, fail

        # 2 ebreak
        li TESTNUM, 2
        li s1, 3
        la s2, t_ebreak
t_ebreak: ebreak
        li t0, 2
        bne s4, t0, fail

        # 3 illegal instruction (all-ones word), mtval = instruction bits
        li TESTNUM, 3
        li s1, 2
        la s2, t_ill
        li s3, -1
t_ill:  .word 0xFFFFFFFF
        li t0, 3
        bne s4, t0, fail

        # 4 misaligned load, mtval = address
        li TESTNUM, 4
        li s1, 4
        la s2, t_mld
        li a0, 0x8101
        mv s3, a0
t_mld:  lw a1, 0(a0)
        li t0, 4
        bne s4, t0, fail

        # 5 misaligned store
        li TESTNUM, 5
        li s1, 6
        la s2, t_mst
        li a0, 0x8102
        mv s3, a0
t_mst:  sw a1, 0(a0)
        li t0, 5
        bne s4, t0, fail

        # 6 unknown CSR -> illegal
        li TESTNUM, 6
        li s1, 2
        la s2, t_csr
        li s3, 0x7c0022f3           # csrr t0, 0x7c0  (encoding)
t_csr:  .word 0x7c0022f3
        li t0, 6
        bne s4, t0, fail

        # 7 writing a read-only CSR (mcycle user view 0xC00) -> illegal
        li TESTNUM, 7
        li s1, 2
        la s2, t_ro
        li s3, 0xc0029073           # csrw cycle, t0
t_ro:   .word 0xc0029073
        li t0, 7
        bne s4, t0, fail

        # 8 CSR read/modify/write semantics
        li TESTNUM, 8
        li t0, 0x12345678
        csrw mscratch, t0
        csrrsi t1, mscratch, 5      # t1 = old, set bits 0,2
        bne t1, t0, fail
        csrr t2, mscratch
        li t3, 0x1234567D
        bne t2, t3, fail
        csrrc t1, mscratch, t3      # clear all
        csrr t2, mscratch
        bnez t2, fail
        csrr t1, misa
        li t3, 0x40001104
        bne t1, t3, fail

        # 9 mcycle / minstret count up
        li TESTNUM, 9
        csrr t1, mcycle
        csrr t2, minstret
        nop; nop; nop; nop
        csrr t3, mcycle
        csrr t4, minstret
        bleu t3, t1, fail
        bleu t4, t2, fail

        TEST_PASSFAIL

handler:
        csrr t0, mcause
        bne t0, s1, fail
        csrr t0, mepc
        bne t0, s2, fail
        csrr t0, mtval
        bne t0, s3, fail
        addi s4, s4, 1
        # skip the faulting instruction: 2 bytes if compressed, else 4
        csrr t0, mepc
        lhu t1, 0(t0)
        andi t1, t1, 3
        li t2, 3
        addi t0, t0, 2
        bne t1, t2, 1f
        addi t0, t0, 2
1:      csrw mepc, t0
        mret

RVTEST_CODE_END
        .data
RVTEST_DATA_BEGIN
        TEST_DATA
RVTEST_DATA_END
