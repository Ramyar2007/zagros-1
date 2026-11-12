# ZAGROS-1

Open-source edge-AI system-on-chip: RV32IMC RISC-V core + 8x8 INT8 systolic NPU + SRAM + UART/SPI/GPIO.
Designed and verified in **WAFER** (chip design studio). Target process GF180MCU (layout only, not fabricated).

- `SPEC.md` architecture and verification plan
- `rtl/` Verilog source (`npu/`, `core/`, `soc/`)
- `tb/` cocotb testbenches (`python tb/run.py [suite]`)
- `flow/` lint, quick synthesis, LibreLane hardening
- CI: `.github/workflows/sim.yml` (lint + simulation + synthesis), results uploaded as artifacts

License: Apache-2.0
