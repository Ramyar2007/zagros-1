"""python fw/build.py : train/quantize (model.h), compile the firmware, write fw/build/isram.hex + dsram.hex ($readmemh words)."""
import os, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / 'build'
OUT.mkdir(exist_ok=True)
CC = os.environ.get('RV_CC', 'riscv64-unknown-elf-gcc')
OBJCOPY = CC.replace('gcc', 'objcopy')

subprocess.run([sys.executable, str(HERE / 'train_digits.py')], check=True)
elf = OUT / 'fw.elf'
subprocess.run([CC, '-march=rv32imc_zicsr', '-mabi=ilp32', '-O2', '-ffreestanding', '-nostdlib', '-nostartfiles', '-static',
                '-T', str(HERE / 'link.ld'), str(HERE / 'crt0.S'), str(HERE / 'main.c'), '-o', str(elf)], check=True)
for name, secs in (('isram', ['.text', '.rodata']), ('dsram', ['.data'])):
    b = OUT / f'{name}.bin'
    args = []
    for s in secs:
        args += ['-j', s]
    subprocess.run([OBJCOPY, '-O', 'binary'] + args + [str(elf), str(b)], check=True)
    data = b.read_bytes()
    data += b'\0' * (-len(data) % 4)
    words = [int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4)] or [0]
    (OUT / f'{name}.hex').write_text('\n'.join(f'{w:08x}' for w in words) + '\n')
    print(name, len(data), 'bytes')
print(subprocess.run([CC.replace('gcc', 'size'), str(elf)], capture_output=True, text=True).stdout)
dis = subprocess.run([CC.replace('gcc', 'objdump'), '-d', '-M', 'no-aliases', str(elf)], capture_output=True, text=True).stdout
(OUT / 'fw.dis').write_text(dis)
