"""cocotb tests for zg_npu: registers, DMA over ZG-BUS (random grant delays), requant math, chunked K, errors, IRQ."""
import random
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly

N = 8
REG = dict(CTRL=0x00, STATUS=0x04, A_ADDR=0x08, A_STRIDE=0x0C, B_ADDR=0x10, B_STRIDE=0x14, C_ADDR=0x18, C_STRIDE=0x1C,
           K=0x20, MULT=0x24, SHIFT=0x28, ZP=0x2C, BIAS_ADDR=0x30, CYCLES=0x34, ID=0x38)
START, ACC_KEEP, RELU, IRQ_EN, BIAS_EN, RAW_OUT, NO_STORE = 1, 2, 4, 8, 16, 32, 64
BASE = 0x1000_0000


class Mem:
    """byte-addressed memory + ZG-BUS slave model with random grant delays"""

    def __init__(self, dut, gnt_prob=0.6):
        self.dut, self.m, self.gnt_prob = dut, {}, gnt_prob
        self.reads = self.writes = 0

    def wr_bytes(self, addr, data):
        for i, b in enumerate(np.asarray(data, dtype=np.int64).ravel()):
            self.m[addr + i] = int(b) & 0xFF

    def rd_word(self, addr):
        return sum(self.m.get(addr + i, 0) << (8 * i) for i in range(4))

    def rd_bytes(self, addr, n):
        return [self.m.get(addr + i, 0) for i in range(n)]

    async def run(self):
        dut = self.dut
        dut.m_gnt.value = 0
        dut.m_rvalid.value = 0
        pending = None
        while True:
            await FallingEdge(dut.clk)
            dut.m_rvalid.value = 0
            if pending is not None:                       # read data exactly one cycle after the grant
                dut.m_rdata.value = self.rd_word(pending)
                dut.m_rvalid.value = 1
                pending = None
            dut.m_gnt.value = 0
            if int(dut.m_req.value) and random.random() < self.gnt_prob:
                dut.m_gnt.value = 1
                addr = int(dut.m_addr.value)
                assert addr % 4 == 0, f"DMA address {addr:#x} not word aligned"
                if int(dut.m_we.value):
                    w, be = int(dut.m_wdata.value), int(dut.m_be.value)
                    for i in range(4):
                        if be >> i & 1:
                            self.m[addr + i] = (w >> (8 * i)) & 0xFF
                    self.writes += 1
                else:
                    pending = addr
                    self.reads += 1


async def setup(dut, gnt_prob=0.6):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.s_req.value = 0
    dut.s_we.value = 0
    dut.s_addr.value = 0
    dut.s_wdata.value = 0
    mem = Mem(dut, gnt_prob)
    cocotb.start_soon(mem.run())
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    return mem


async def wreg(dut, name, val):
    await FallingEdge(dut.clk)
    dut.s_req.value, dut.s_we.value, dut.s_addr.value, dut.s_wdata.value = 1, 1, REG[name], val & 0xFFFFFFFF
    await FallingEdge(dut.clk)
    dut.s_req.value, dut.s_we.value = 0, 0


async def rreg(dut, name):
    await FallingEdge(dut.clk)
    dut.s_req.value, dut.s_we.value, dut.s_addr.value = 1, 0, REG[name]
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.s_rvalid.value) == 1
    v = int(dut.s_rdata.value)
    await FallingEdge(dut.clk)
    dut.s_req.value = 0
    return v


def requant(acc, bias, mult, shift, zp, relu):
    v = acc.astype(object) + (bias.astype(object) if bias is not None else 0)
    p = v * mult
    if shift:
        p = (p + (1 << (shift - 1))) >> shift          # python >> on ints is arithmetic (floor)
    y = p + zp
    lo = zp if relu else -128
    return np.clip(np.array(y, dtype=object), lo, 127).astype(np.int64)


async def run_tile(dut, mem, A, B, *, a_addr, b_addr, c_addr, a_stride, b_stride, c_stride,
                   mult=1, shift=0, zp=0, relu=False, bias=None, bias_addr=0, raw=False, keep=False, nostore=False,
                   irq=False, timeout=20000):
    K = A.shape[1]
    for i in range(N):
        mem.wr_bytes(a_addr + i * a_stride, A[i])
    for k in range(K):
        mem.wr_bytes(b_addr + k * b_stride, B[k])
    if bias is not None:
        for j in range(N):
            mem.wr_bytes(bias_addr + 4 * j, [(int(bias[j]) >> (8 * b)) & 0xFF for b in range(4)])
    for n, v in [('A_ADDR', a_addr), ('A_STRIDE', a_stride), ('B_ADDR', b_addr), ('B_STRIDE', b_stride),
                 ('C_ADDR', c_addr), ('C_STRIDE', c_stride), ('K', K), ('MULT', mult), ('SHIFT', shift),
                 ('ZP', zp & 0xFF), ('BIAS_ADDR', bias_addr)]:
        await wreg(dut, n, v)
    ctrl = START | (ACC_KEEP if keep else 0) | (RELU if relu else 0) | (IRQ_EN if irq else 0) | \
        (BIAS_EN if bias is not None else 0) | (RAW_OUT if raw else 0) | (NO_STORE if nostore else 0)
    await wreg(dut, 'CTRL', ctrl)
    for _ in range(timeout):
        st = await rreg(dut, 'STATUS')
        if st & 2:
            return st
        assert not st & 4, "NPU reported ERR"
    raise AssertionError("NPU timeout")


def read_c(mem, c_addr, c_stride, raw):
    C = np.zeros((N, N), dtype=np.int64)
    for i in range(N):
        if raw:
            for j in range(N):
                w = mem.rd_word(c_addr + i * c_stride + 4 * j)
                C[i, j] = w - (1 << 32) if w >> 31 else w
        else:
            for j, b in enumerate(mem.rd_bytes(c_addr + i * c_stride, N)):
                C[i, j] = b - 256 if b >> 7 else b
    return C


def rnd(shape):
    return np.random.randint(-128, 128, size=shape).astype(np.int64)


@cocotb.test()
async def test_regs_and_id(dut):
    """register write/readback and the ID constant"""
    await setup(dut)
    assert await rreg(dut, 'ID') == 0x5A474E50
    for n, v in [('A_ADDR', 0x10000100), ('B_STRIDE', 0x40), ('K', 16), ('MULT', 0x12345), ('SHIFT', 13), ('ZP', 0xF6)]:
        await wreg(dut, n, v)
        assert await rreg(dut, n) == v, n


@cocotb.test()
async def test_raw_accumulators(dut):
    """RAW_OUT: int32 results must equal A @ B exactly"""
    mem = await setup(dut)
    np.random.seed(11)
    for K in [4, 8, 20, 32]:
        A, B = rnd((N, K)), rnd((K, N))
        await run_tile(dut, mem, A, B, a_addr=BASE, b_addr=BASE + 0x400, c_addr=BASE + 0x800,
                       a_stride=32, b_stride=8, c_stride=32, raw=True)
        assert np.array_equal(read_c(mem, BASE + 0x800, 32, True), A @ B), f"raw K={K}"


@cocotb.test()
async def test_requant_random(dut):
    """random strides, bias, relu, mult/shift/zp vs the python requant model"""
    mem = await setup(dut, gnt_prob=0.4)
    np.random.seed(12)
    random.seed(12)
    for t in range(12):
        K = random.choice([4, 8, 12, 16, 28, 32])
        a_stride = 4 * random.randint(K // 4, K // 4 + 4)
        b_stride = 4 * random.randint(2, 5)
        c_stride = 4 * random.randint(2, 6)
        A, B = rnd((N, K)), rnd((K, N))
        bias = np.random.randint(-5000, 5000, size=N) if t % 2 else None
        mult, shift = random.randint(1, 1 << 16), random.randint(0, 24)
        zp, relu = random.randint(-20, 20), bool(t % 3 == 0)
        await run_tile(dut, mem, A, B, a_addr=BASE + 0x1000, b_addr=BASE + 0x2000, c_addr=BASE + 0x3000, bias_addr=BASE + 0x3F00,
                       a_stride=a_stride, b_stride=b_stride, c_stride=c_stride, mult=mult, shift=shift, zp=zp, relu=relu, bias=bias)
        exp = requant(A @ B, bias, mult, shift, zp, relu)
        got = read_c(mem, BASE + 0x3000, c_stride, False)
        assert np.array_equal(got, exp), f"case {t}: K={K} mult={mult} shift={shift} zp={zp} relu={relu}\n{got}\n{exp}"


@cocotb.test()
async def test_chunked_k(dut):
    """K=96 in three chunks of 32 (ACC_KEEP on chunks 2-3, NO_STORE on chunks 1-2)"""
    mem = await setup(dut)
    np.random.seed(13)
    A, B = rnd((N, 96)), rnd((96, N))
    for c in range(3):
        await run_tile(dut, mem, A[:, 32 * c:32 * (c + 1)], B[32 * c:32 * (c + 1)], a_addr=BASE, b_addr=BASE + 0x400,
                       c_addr=BASE + 0x800, a_stride=32, b_stride=8, c_stride=32, raw=True, keep=c > 0, nostore=c < 2)
    assert np.array_equal(read_c(mem, BASE + 0x800, 32, True), A @ B)


@cocotb.test()
async def test_errors_and_irq(dut):
    """misaligned config -> ERR without running; IRQ follows DONE when enabled; DONE is write-1-to-clear"""
    mem = await setup(dut)
    await wreg(dut, 'K', 6)                                    # not a multiple of 4
    await wreg(dut, 'CTRL', START)
    for _ in range(3):
        await RisingEdge(dut.clk)
    st = await rreg(dut, 'STATUS')
    assert st & 4 and not st & 1, f"expected ERR, STATUS={st:#x}"
    await wreg(dut, 'STATUS', 4)
    assert not (await rreg(dut, 'STATUS')) & 4
    np.random.seed(14)
    A, B = rnd((N, 8)), rnd((8, N))
    await run_tile(dut, mem, A, B, a_addr=BASE, b_addr=BASE + 0x400, c_addr=BASE + 0x800,
                   a_stride=8, b_stride=8, c_stride=8, irq=True, mult=1, shift=8)
    await ReadOnly()
    assert int(dut.irq.value) == 1, "irq should be high after DONE with IRQ_EN"
    await wreg(dut, 'STATUS', 2)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.irq.value) == 0, "irq should drop when DONE is cleared"
    cyc = await rreg(dut, 'CYCLES')
    assert cyc > 8, f"cycle counter looks wrong: {cyc}"
