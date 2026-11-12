"""cocotb: run every program in tb/core/build/manifest.json on zg_core with a Python memory (64 KB) on both ZG-BUS ports
(random grant delays). Pass = program writes 1 to tohost (0x8000). Also an IRQ register at 0xF000 (bit0 timer,
bit1 external) for the interrupt tests. Writes tb results to results/core/programs.json."""
import json, os, random
from collections import deque
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

HERE = Path(__file__).resolve().parent
TOHOST, IRQREG, MEMSZ = 0x8000, 0xF000, 0x10000
MAX_CYCLES = int(os.environ.get('MAX_CYCLES', '60000'))


class System:
    def __init__(self, dut, img, gnt_i=0.8, gnt_d=0.7):
        self.dut, self.gi, self.gd = dut, gnt_i, gnt_d
        self.mem = bytearray(MEMSZ)
        self.mem[:len(img)] = img
        self.tohost = None
        self.retired = 0
        self.trace = deque(maxlen=300)
        self.cyc = 0

    def rd(self, a):
        a &= MEMSZ - 1
        return int.from_bytes(self.mem[a:a + 4], 'little')

    async def run(self):
        dut = self.dut
        pi = pd = None
        for _ in range(MAX_CYCLES):
            await FallingEdge(dut.clk)
            self.cyc += 1
            # responses (one cycle after grant)
            dut.i_rvalid.value = 0
            dut.d_rvalid.value = 0
            if pi is not None:
                dut.i_rdata.value = self.rd(pi); dut.i_rvalid.value = 1; pi = None
            if pd is not None:
                dut.d_rdata.value = self.rd(pd); dut.d_rvalid.value = 1; pd = None
            # grants
            dut.i_gnt.value = 0
            dut.d_gnt.value = 0
            if int(dut.i_req.value) and random.random() < self.gi:
                dut.i_gnt.value = 1
                pi = int(dut.i_addr.value)
            if int(dut.d_req.value) and random.random() < self.gd:
                dut.d_gnt.value = 1
                a = int(dut.d_addr.value)
                if int(dut.d_we.value):
                    w, be = int(dut.d_wdata.value), int(dut.d_be.value)
                    self.trace.append(f'{self.cyc:6d} ST  [{a:#07x}] be={be:04b} data={w:#010x}')
                    if a == TOHOST:
                        self.tohost = w
                    elif a == IRQREG:
                        dut.irq_timer.value = w & 1
                        dut.irq_ext.value = (w >> 1) & 1
                    else:
                        for b in range(4):
                            if be >> b & 1:
                                self.mem[(a + b) & (MEMSZ - 1)] = (w >> (8 * b)) & 0xFF
                else:
                    pd = a
                    self.trace.append(f'{self.cyc:6d} LD  [{a:#07x}] -> {self.rd(a):#010x}')
            if int(dut.rvfi_valid.value):
                self.retired += 1
                pc = int(dut.rvfi_pc.value)
                self.trace.append(f'{self.cyc:6d} RET pc={pc:#07x} ins={self.rd(pc & ~3):#010x}')
            if self.tohost is not None:
                return
        self.tohost = None


async def reset(dut):
    dut.rst_n.value = 0
    for s in ('i_gnt', 'i_rvalid', 'd_gnt', 'd_rvalid', 'irq_timer', 'irq_ext'):
        getattr(dut, s).value = 0
    dut.i_rdata.value = 0
    dut.d_rdata.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def test_programs(dut):
    """riscv-tests rv32ui/um/uc (plain + compressed builds) and ZAGROS custom trap/CSR/interrupt programs"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    manifest = json.loads((HERE / 'build' / 'manifest.json').read_text())
    only = os.environ.get('ONLY')
    results, fails = [], []
    random.seed(5)
    for t in manifest:
        if not t['ok'] or (only and only not in t['name']):
            continue
        img = (HERE / t['bin']).read_bytes()
        sysm = System(dut, img, gnt_i=random.choice([1.0, 0.8, 0.5]), gnt_d=random.choice([1.0, 0.7, 0.4]))
        await reset(dut)
        await sysm.run()
        th = sysm.tohost
        ok = th == 1
        why = 'pass' if ok else ('timeout' if th is None else
                                 (f'trap mcause={(th >> 4) & 0xFFFF:#x}' if (th & 0xFFF00000) == 0xDEA00000 else f'failed test #{th >> 1}'))
        results.append({'name': t['name'], 'passed': ok, 'result': why, 'retired': sysm.retired})
        if not ok:
            fails.append(f"{t['name']}: {why}")
            tr = HERE.parents[1] / 'results' / 'core' / f"{t['name']}.trace"
            tr.parent.mkdir(parents=True, exist_ok=True)
            tr.write_text('
'.join(sysm.trace))
        dut._log.info(f"{'PASS' if ok else 'FAIL'} {t['name']} ({why}, {sysm.retired} instr)")
    out = HERE.parents[1] / 'results' / 'core'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'programs.json').write_text(json.dumps(results, indent=1))
    assert results, "no programs ran (build step missing?)"
    assert not fails, f"{len(fails)}/{len(results)} programs failed: " + '; '.join(fails[:20])
