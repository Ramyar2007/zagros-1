# ZAGROS-1 custom: timer + external interrupts via the test harness IRQ register (0xF000: bit0 timer, bit1 ext).
#include "riscv_test.h"
#include "test_macros.h"

#define IRQREG 0xF000

RVTEST_RV32U
RVTEST_CODE_BEGIN
        la t0, handler
        csrw mtvec, t0
        li s4, 0                    # interrupts seen
        li s5, 0                    # last mcause

        # 1 pending timer irq is ignored while MIE=0
        li TESTNUM, 1
        li a0, IRQREG
        li t0, 1
        sw t0, 0(a0)                # raise timer
        li t0, 0x80
        csrw mie, t0                # MTIE
        nop; nop; nop; nop; nop
        bnez s4, fail

        # 2 enabling MIE takes the timer interrupt; handler lowers the line
        li TESTNUM, 2
        csrsi mstatus, 8
        nop; nop; nop; nop; nop; nop; nop; nop
        li t0, 1
        bne s4, t0, fail
        li t0, 0x80000007
        bne s5, t0, fail

        # 3 external interrupt (MEIE), taken in the middle of a divide loop
        li TESTNUM, 3
        li t0, 0x800
        csrw mie, t0
        li t1, 100000
        li t2, 7
        li a0, IRQREG
        li t0, 2
        sw t0, 0(a0)                # raise external
        div t3, t1, t2
        div t3, t3, t2
        nop; nop; nop; nop
        li t0, 2
        bne s4, t0, fail
        li t0, 0x8000000B
        bne s5, t0, fail
        li t4, 2040                 # 100000/7/7 = 2040 (divide must still be correct)
        bne t3, t4, fail

        # 4 MIE is restored by mret, MPIE behaviour
        li TESTNUM, 4
        csrr t0, mstatus
        andi t0, t0, 8
        beqz t0, fail

        TEST_PASSFAIL

handler:
        csrr s5, mcause
        addi s4, s4, 1
        li a1, IRQREG
        sw zero, 0(a1)              # lower all interrupt lines
        csrr a2, mstatus            # inside the handler MIE must be 0
        andi a2, a2, 8
        bnez a2, fail
        mret

RVTEST_CODE_END
        .data
RVTEST_DATA_BEGIN
        TEST_DATA
RVTEST_DATA_END
