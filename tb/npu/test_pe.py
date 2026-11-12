"""cocotb tests for zg_pe: signed MAC, pass-through registers, clear priority, stall."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly

AW = 32


def s8(v):
    return v & 0xFF


def to_signed(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.en.value = 1
    dut.clr.value = 0
    dut.a_in.value = 0
    dut.b_in.value = 0
    dut.v_in.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_mac_random(dut):
    """2000 random signed MACs incl. stalls and invalid cycles vs python model"""
    await setup(dut)
    random.seed(7)
    acc = 0
    for _ in range(2000):
        await FallingEdge(dut.clk)
        a, b = random.randint(-128, 127), random.randint(-128, 127)
        v, en = random.random() < 0.8, random.random() < 0.9
        dut.a_in.value, dut.b_in.value, dut.v_in.value, dut.en.value = s8(a), s8(b), int(v), int(en)
        await RisingEdge(dut.clk)
        if en and v:
            acc = to_signed(acc + a * b, AW)
        await ReadOnly()
        assert to_signed(int(dut.acc.value), AW) == acc, "acc mismatch"
        if en:
            assert to_signed(int(dut.a_out.value), 8) == a and to_signed(int(dut.b_out.value), 8) == b, "pass-through mismatch"
            assert int(dut.v_out.value) == int(v), "valid pass-through mismatch"


@cocotb.test()
async def test_clear_priority(dut):
    """clr wins over a valid product in the same cycle; stalled clr does nothing"""
    await setup(dut)
    dut.a_in.value, dut.b_in.value, dut.v_in.value = s8(100), s8(-3), 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert to_signed(int(dut.acc.value), AW) == -600
    await RisingEdge(dut.clk)
    dut.en.value, dut.clr.value = 0, 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert to_signed(int(dut.acc.value), AW) == -900, "stalled clr must not clear"
    await RisingEdge(dut.clk)
    dut.en.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.acc.value) == 0, "clr must win over valid"
