"""cocotb tests for zg_systolic (N x N output-stationary INT8 array) against a numpy golden model."""
import random
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

N = 8
AW = 32


def pack(vals, width=8):
    """list of signed ints -> packed int, element 0 in the low bits"""
    out = 0
    for i, v in enumerate(vals):
        out |= (int(v) & ((1 << width) - 1)) << (i * width)
    return out


def unpack_acc(dut):
    raw = int(dut.acc_flat.value)
    C = np.zeros((N, N), dtype=np.int64)
    for i in range(N):
        for j in range(N):
            v = (raw >> ((i * N + j) * AW)) & ((1 << AW) - 1)
            C[i, j] = v - (1 << AW) if v >> (AW - 1) else v
    return C


async def reset(dut):
    dut.rst_n.value = 0
    dut.en.value = 1
    dut.clr.value = 0
    dut.in_valid.value = 0
    dut.a_vec.value = 0
    dut.b_vec.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def clear(dut):
    dut.clr.value = 1
    await RisingEdge(dut.clk)
    dut.clr.value = 0


async def stream(dut, A, B, stall_prob=0.0):
    """feed K steps: column k of A and row k of B each cycle; random stalls (en=0) if requested"""
    K = A.shape[1]
    k = 0
    while k < K:
        stall = random.random() < stall_prob
        dut.en.value = 0 if stall else 1
        dut.in_valid.value = 1
        dut.a_vec.value = pack(A[:, k])
        dut.b_vec.value = pack(B[k, :])
        await RisingEdge(dut.clk)
        if not stall:
            k += 1
    dut.in_valid.value = 0
    dut.a_vec.value = 0
    dut.b_vec.value = 0


async def wait_done(dut, stall_prob=0.0, limit=200):
    cycles = 0
    while True:
        dut.en.value = 0 if random.random() < stall_prob else 1
        await ReadOnly()
        busy = int(dut.busy.value)
        await RisingEdge(dut.clk)
        if not busy:
            break
        cycles += 1
        assert cycles < limit, "array never finished"
    dut.en.value = 1
    return cycles


def rand_mat(shape, lo=-128, hi=127):
    return np.random.randint(lo, hi + 1, size=shape).astype(np.int64)


async def run_one(dut, A, B, keep=False, stall_prob=0.0):
    await RisingEdge(dut.clk)          # leave any ReadOnly phase before driving
    if not keep:
        await clear(dut)
    await stream(dut, A, B, stall_prob)
    await wait_done(dut, stall_prob)
    await ReadOnly()
    return unpack_acc(dut)


@cocotb.test()
async def test_identity_and_small(dut):
    """A x I = A for a hand-checkable case, K = N"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    A = np.arange(N * N).reshape(N, N) - 32
    B = np.eye(N, dtype=np.int64)
    got = await run_one(dut, A, B)
    assert np.array_equal(got, A @ B), f"identity mismatch\n{got}\nvs\n{A @ B}"


@cocotb.test()
async def test_random_many_k(dut):
    """random INT8 matrices, K from 1 to 64, compared with numpy int32 matmul"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    np.random.seed(1)
    for K in [1, 2, 3, 7, 8, 9, 16, 31, 64]:
        A, B = rand_mat((N, K)), rand_mat((K, N))
        await RisingEdge(dut.clk)
        got = await run_one(dut, A, B)
        assert np.array_equal(got, A @ B), f"K={K} mismatch"


@cocotb.test()
async def test_extremes(dut):
    """worst case magnitudes: -128 * -128 summed over K=64 must not overflow 32 bits"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    K = 64
    for a, b in [(-128, -128), (-128, 127), (127, 127), (0, -128)]:
        A = np.full((N, K), a, dtype=np.int64)
        B = np.full((K, N), b, dtype=np.int64)
        await RisingEdge(dut.clk)
        got = await run_one(dut, A, B)
        assert np.array_equal(got, A @ B), f"extreme {a}*{b} mismatch"


@cocotb.test()
async def test_accumulate_chunks(dut):
    """ACC_KEEP: two K chunks without clearing must equal A1@B1 + A2@B2"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    np.random.seed(2)
    A1, B1 = rand_mat((N, 16)), rand_mat((16, N))
    A2, B2 = rand_mat((N, 24)), rand_mat((24, N))
    await run_one(dut, A1, B1)
    got = await run_one(dut, A2, B2, keep=True)
    assert np.array_equal(got, A1 @ B1 + A2 @ B2), "chunked accumulation mismatch"


@cocotb.test()
async def test_random_stalls(dut):
    """en=0 stalls at random points must not change the result"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    np.random.seed(3)
    random.seed(3)
    for K in [5, 17, 40]:
        A, B = rand_mat((N, K)), rand_mat((K, N))
        await RisingEdge(dut.clk)
        got = await run_one(dut, A, B, stall_prob=0.3)
        assert np.array_equal(got, A @ B), f"stall K={K} mismatch"


@cocotb.test()
async def test_latency(dut):
    """busy drops exactly 2N-1 cycles after the last K step (total K + 2N - 1), and the result is final then"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    K = 10
    A, B = rand_mat((N, K)), rand_mat((K, N))
    await clear(dut)
    await stream(dut, A, B)
    extra = await wait_done(dut)
    assert extra == 2 * N - 1, f"drain {extra} != {2 * N - 1}"
    await ReadOnly()
    assert np.array_equal(unpack_acc(dut), A @ B), "result not final when busy dropped"
