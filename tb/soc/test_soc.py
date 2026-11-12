"""cocotb: full ZAGROS-1 SoC running the digits firmware. Decodes the UART, waits for POST bit31, checks that the NPU
results equal the Python INT8 model bit for bit, and writes results/soc/demo.json (predictions, accuracy, cycles)."""
import json, re
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

ROOT = Path(__file__).resolve().parents[2]
UART_DIV = 8          # firmware sets this
MAX_CYCLES = 3_000_000


async def uart_monitor(dut, sink):
    """decode 8N1 at UART_DIV clocks per bit from uart_tx"""
    while True:
        await FallingEdge(dut.uart_tx)
        await ClockCycles(dut.clk, UART_DIV // 2)
        if int(dut.uart_tx.value):
            continue
        byte = 0
        for b in range(8):
            await ClockCycles(dut.clk, UART_DIV)
            byte |= int(dut.uart_tx.value) << b
        await ClockCycles(dut.clk, UART_DIV)
        sink.append(chr(byte))


@cocotb.test()
async def test_digits_demo(dut):
    """digits MLP on the NPU: every logit and hidden activation must match the Python model"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n_async.value = 0
    dut.uart_rx.value = 1
    dut.gpio_in.value = 0
    dut.spi_miso.value = 0
    out = []
    cocotb.start_soon(uart_monitor(dut, out))
    await ClockCycles(dut.clk, 5)
    dut.rst_n_async.value = 1
    cycles = 0
    while cycles < MAX_CYCLES:
        await ClockCycles(dut.clk, 1000)
        cycles += 1000
        if int(dut.post.value) >> 31:
            break
    await ClockCycles(dut.clk, 200)
    text = ''.join(out)
    post = int(dut.post.value)
    dut._log.info('UART:\n' + text)
    if not post >> 31:
        core = dut.u_soc.u_core
        pcs = []
        for _ in range(400):
            await RisingEdge(dut.clk)
            if int(core.rvfi_valid.value):
                pcs.append(f'{int(core.rvfi_pc.value):x}')
        dut._log.error('retired pcs: ' + ' '.join(pcs[-120:]))
        dut._log.error(f"core state: ifetch addr={int(core.i_addr.value):#x} d_req={int(core.d_req.value)} "
                       f"mcause={int(core.mcause.value):#x} mepc={int(core.mepc.value):#x}")
    assert post >> 31, f'firmware did not finish in {MAX_CYCLES} cycles; UART so far:\n{text}'
    total, correct, bad = post & 0xFF, (post >> 8) & 0xFF, (post >> 16) & 0xFF
    mj = ROOT / 'fw' / 'build' / 'model.json'
    model = json.loads(mj.read_text()) if mj.exists() else {}
    preds = [int(m.group(1)) for m in re.finditer(r'pred (\d+)', text)]
    cyc = re.search(r'npu_l1_per_batch (\d+) cpu_l1_per_batch (\d+)', text)
    res = {'post': f'{post:#010x}', 'total': total, 'correct': correct, 'mismatches': bad, 'cycles_to_done': cycles,
           'predictions': preds, 'labels': model.get('labels', [])[:total], 'uart': text,
           'npu_layer1_cycles': int(cyc.group(1)) if cyc else None, 'cpu_layer1_cycles': int(cyc.group(2)) if cyc else None,
           'speedup': round(int(cyc.group(2)) / int(cyc.group(1)), 1) if cyc and int(cyc.group(1)) else None,
           'model': {k: model.get(k) for k in ('arch', 'float_acc', 'int8_acc', 'dataset')}}
    (ROOT / 'results' / 'soc').mkdir(parents=True, exist_ok=True)
    (ROOT / 'results' / 'soc' / 'demo.json').write_text(json.dumps(res, indent=1))
    assert bad == 0, f'{bad} mismatches between the NPU and the Python INT8 model'
    assert total > 0 and correct > 0
