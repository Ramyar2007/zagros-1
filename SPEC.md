# ZAGROS-1 — architecture spec (v0.1, 12 Nov 2026)

Edge-AI system-on-chip, open-source flow, target process GF180MCU (layout/GDS only — not fabricated).
Designed in the WAFER studio. All numbers below are targets until the flow reports them.

## Block diagram

```
            +-------------------------------- ZAGROS-1 --------------------------------+
  UART  <-->|  UART (115200 8N1)                                                        |
  SPI   <-->|  SPI master            +----------------+     +-------------------------+ |
  GPIO  <-->|  GPIO x16              |  ZG-CORE       |     |  ZG-NPU                 | |
            |  TIMER (mtime/cmp)     |  RV32IMC       |     |  8x8 INT8 systolic array| |
            |        |               |  5-stage, M/C  |     |  output-stationary      | |
            |        |               |  machine mode  |     |  A/B scratchpads, DMA   | |
            |        |               +-------+--------+     |  requant (scale,shift,  | |
            |        |                       |              |  zero-point, ReLU)      | |
            |   +----+-----------------------+---------+    +-----+-------------+-----+ |
            |   |                 ZG-BUS (32-bit, 2 masters: core, NPU DMA)    |       |
            |   +----+-----------------+---------------+------------------------+       |
            |        |                 |               |                                |
            |     I-SRAM 8 KB      D-SRAM 16 KB     peripherals @ 0x4000_0000           |
            +---------------------------------------------------------------------------+
```

## Memory map

| Range | Block |
|---|---|
| 0x0000_0000 - 0x0000_1FFF | I-SRAM 8 KB (code; loadable over UART/SPI boot) |
| 0x1000_0000 - 0x1000_3FFF | D-SRAM 16 KB (data, tensors) |
| 0x4000_0000 | UART: DATA, STATUS, DIV |
| 0x4000_1000 | GPIO: OUT, IN, DIR |
| 0x4000_2000 | SPI master: DATA, CTRL, STATUS |
| 0x4000_3000 | TIMER: MTIME lo/hi, MTIMECMP lo/hi |
| 0x5000_0000 | NPU registers (below) |

## ZG-NPU

Computes C[8x8] = requant( A[8xK] x B[Kx8] (+ bias) ) with INT8 inputs and INT32 accumulation.
- Systolic array: 8x8 processing elements (PE = 8x8 signed multiply + 32-bit accumulate), output-stationary.
  A columns enter from the left skewed by row, B rows enter from the top skewed by column; one K step per clock.
  Latency for one tile: K + 2*8 - 1 cycles from the first K step until `busy` drops (results final).
- K is chunked by software: CTRL.ACC_KEEP keeps the accumulators so K can be any multiple of the chunk size.
- Requant: y = clamp( ((acc + bias) * MULT + round) >>> SHIFT + ZP, -128, 127 ), optional ReLU.
- DMA master on ZG-BUS: loads A and B tiles from D-SRAM with strides, writes C back.
- Registers: CTRL (start, acc_keep, relu, irq_en), STATUS (busy, done), A_ADDR, B_ADDR, C_ADDR, K, A_STRIDE, B_STRIDE, C_STRIDE, MULT, SHIFT, ZP, BIAS_ADDR.

## ZG-CORE

RV32IMC, machine mode only, 5 stages (IF, ID, EX, MEM, WB), full forwarding, load-use stall,
static not-taken branches resolved in EX, compressed decoder in IF (handles 32-bit instructions split
across a word boundary), single-cycle 32x32 multiplier (pipelined) and iterative 33-cycle divider.
CSRs: mstatus, misa, mtvec, mepc, mcause, mtval, mie, mip, mscratch, mcycle(h), minstret(h), mhartid.
Traps: illegal instruction, ecall, ebreak, misaligned load/store/jump, timer + external interrupts.

## Verification plan (sign-off gates)

1. Unit tests (cocotb + Verilator) per block against Python/numpy golden models, random + corner cases.
2. Core: riscv-tests rv32ui/um/uc + architectural compliance (ACT4) + random programs vs a Python ISS.
3. Formal (SymbiYosys): PE/array accumulate invariants, bus handshake, no X on outputs after reset.
4. SoC: firmware runs an INT8 neural network (digits) on the NPU; result must equal the Python reference bit for bit.
5. Gate-level simulation of the synthesized netlist (catches synthesis pruning and X-propagation).
6. Physical: LibreLane on GF180 -> GDS; DRC, LVS, antenna clean; multi-corner STA with hold margin.
7. Design rules from past open tapeouts: synchronous reset release, 2-flop synchronisers on every async input,
   cell/flip-flop count checked against expectation after synthesis, debug backdoor over UART.
