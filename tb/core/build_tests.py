"""python tb/core/build_tests.py : fetch riscv-tests (pinned), build rv32ui/rv32um/rv32uc + ZAGROS custom tests into flat
binaries tb/core/build/<name>.bin and a manifest.json. Each rv32ui/um test is built twice: plain RV32IM and with
the C extension enabled (the assembler then emits compressed forms), so the fetch/RVC path is covered too."""
import json, os, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD = HERE / 'build'
RT = HERE / 'riscv-tests'
CC = os.environ.get('RV_CC', 'riscv64-unknown-elf-gcc')
OBJCOPY = CC.replace('gcc', 'objcopy')

UI = ('add addi and andi auipc beq bge bgeu blt bltu bne jal jalr lb lbu lh lhu lui lw or ori sb sh simple sll slli '
      'slt slti sltiu sltu sra srai srl srli sub sw xor xori ld_st st_ld').split()
UM = 'div divu mul mulh mulhsu mulhu rem remu'.split()
UC = ['rvc']

if not RT.exists():
    subprocess.run(['git', 'clone', '-q', 'https://github.com/riscv-software-src/riscv-tests', str(RT)], check=True)
BUILD.mkdir(exist_ok=True)


def build(name, src, march):
    elf = BUILD / f'{name}.elf'
    cmd = [CC, f'-march={march}', '-mabi=ilp32', '-static', '-nostdlib', '-nostartfiles', '-T', str(HERE / 'env' / 'link.ld'),
           '-I', str(HERE / 'env'), '-I', str(RT / 'isa' / 'macros' / 'scalar'), str(src), '-o', str(elf)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return {'name': name, 'ok': False, 'error': r.stderr[-1500:]}
    binf = BUILD / f'{name}.bin'
    subprocess.run([OBJCOPY, '-O', 'binary', str(elf), str(binf)], check=True)
    return {'name': name, 'ok': True, 'bin': str(binf.relative_to(HERE)), 'size': binf.stat().st_size}


tests = []
for t in UI:
    src = RT / 'isa' / 'rv32ui' / f'{t}.S'
    if not src.exists():
        continue
    tests.append(build(f'rv32ui-{t}', src, 'rv32im_zicsr'))
    tests.append(build(f'rv32uic-{t}', src, 'rv32imc_zicsr'))
for t in UM:
    tests.append(build(f'rv32um-{t}', RT / 'isa' / 'rv32um' / f'{t}.S', 'rv32im_zicsr'))
    tests.append(build(f'rv32umc-{t}', RT / 'isa' / 'rv32um' / f'{t}.S', 'rv32imc_zicsr'))
for t in UC:
    tests.append(build(f'rv32uc-{t}', RT / 'isa' / 'rv32uc' / f'{t}.S', 'rv32imc_zicsr'))
for src in sorted((HERE / 'asm').glob('*.S')):
    tests.append(build(f'zg-{src.stem}', src, 'rv32imc_zicsr'))

(BUILD / 'manifest.json').write_text(json.dumps(tests, indent=1))
bad = [t for t in tests if not t['ok']]
print(f'built {len(tests) - len(bad)}/{len(tests)} tests')
for t in bad:
    print('BUILD FAIL', t['name'], t['error'][:400])
sys.exit(1 if bad else 0)
