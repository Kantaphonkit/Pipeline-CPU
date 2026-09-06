#!/usr/bin/env python3
"""Generate committed fixtures (.hex/.data.hex/.trace/.regs/.dmem) for every
assembly test program in the repo, using tools/asm.py and tools/iss.py as
the golden toolchain. See docs/INTERFACES.md sections 4-5 for the tool
contracts this script relies on.

For every .s file under asm/insn/, asm/hazard/, asm/prog/ (plus asm/smoke.s):
  1. Assemble it: `asm.py <name>.s -o <name>.hex` (writes <name>.data.hex too
     if the program has a non-empty .data section).
  2. Run the ISS golden reference: `iss.py <name>.hex --trace <name>.trace
     --dump-regs --dump-mem 0 0xFFF` (plus any per-program extra args, e.g.
     irq_demo's --irq-after pulses -- see EXTRA_ISS_ARGS below).
  3. Reformat the --dump-regs output into <name>.regs: exactly 32 lines of
     8 lowercase hex digits, x0 first, x31 last -- a $readmemh-loadable
     register-file image (NOT the "x5=..." form the ISS prints).
  4. Reformat the --dump-mem output into <name>.dmem: exactly 1024 lines of
     8 lowercase hex digits -- the final DMEM image, $readmemh-loadable.

Fails loudly (nonzero exit, and skips writing fixtures for that program) if
any program hits ISS exit code 2 (--max-insns exceeded) or 3 (illegal
instruction) -- those are always bugs in the test program, never expected
outcomes for this project's fixtures.

Usage:
    python tools/gen_fixtures.py              # every program
    python tools/gen_fixtures.py --only 'asm/insn/*.s'
    python tools/gen_fixtures.py --only 'add*'
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASM_DIRS = ['asm/insn', 'asm/hazard', 'asm/prog']
SMOKE = 'asm/smoke.s'

PYTHON = sys.executable
ASM_PY = os.path.join(ROOT, 'tools', 'asm.py')
ISS_PY = os.path.join(ROOT, 'tools', 'iss.py')

MEM_WORDS = 1024
MAX_INSNS = 200000

# Per-program extra ISS arguments, keyed by the program's repo-relative .s
# path (forward slashes). irq_demo.s wants two interrupt pulses so the trace
# actually exercises the ISR (see PROJECT-REQUIREMENTS.md sec 3.4 / task D).
EXTRA_ISS_ARGS = {
    'asm/prog/irq_demo.s': ['--irq-after', '50', '--irq-after', '120'],
}


def find_programs():
    progs = []
    if os.path.exists(os.path.join(ROOT, SMOKE)):
        progs.append(SMOKE)
    for d in ASM_DIRS:
        full = os.path.join(ROOT, d)
        if not os.path.isdir(full):
            continue
        for fn in sorted(os.listdir(full)):
            if fn.endswith('.s'):
                progs.append((d + '/' + fn))
    return progs


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)


def parse_dump(stdout):
    """Split `iss.py --dump-regs --dump-mem` stdout into (regs, mem) where
    regs is {n: hex8} and mem is {byte_addr: hex8}."""
    regs = {}
    mem = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('x') and '=' in line:
            name, val = line.split('=', 1)
            regs[int(name[1:])] = val.strip().lower()
        elif line.startswith('mem[') and '=' in line:
            addr_txt, val = line.split('=', 1)
            addr = int(addr_txt[len('mem['):-1], 16)
            mem[addr] = val.strip().lower()
    return regs, mem


def write_lines(path, lines):
    with open(path, 'w', newline='\n') as f:
        for ln in lines:
            f.write(ln + '\n')


def process(rel, extra_args):
    """Assemble + run one program. Returns (retired_count_or_None, exit_code,
    error_text_or_None)."""
    src = os.path.join(ROOT, rel)
    base = rel[:-2] if rel.endswith('.s') else rel
    hexpath = base + '.hex'

    r = run([PYTHON, ASM_PY, src, '-o', os.path.join(ROOT, hexpath)])
    if r.returncode != 0:
        return None, None, "assemble failed:\n" + r.stdout + r.stderr

    trace_rel = base + '.trace'
    cmd = [PYTHON, ISS_PY, hexpath,
           '--trace', trace_rel,
           '--max-insns', str(MAX_INSNS),
           '--dump-regs',
           '--dump-mem', '0', '0xFFF']
    cmd += extra_args

    r = run(cmd)
    exit_code = r.returncode

    if exit_code in (2, 3):
        return None, exit_code, "ISS exit %d:\n%s%s" % (exit_code, r.stdout, r.stderr)

    regs, mem = parse_dump(r.stdout)

    regs_lines = [regs.get(n, '00000000') for n in range(32)]
    write_lines(os.path.join(ROOT, base + '.regs'), regs_lines)

    dmem_lines = [mem.get(4 * i, '00000000') for i in range(MEM_WORDS)]
    write_lines(os.path.join(ROOT, base + '.dmem'), dmem_lines)

    trace_path = os.path.join(ROOT, trace_rel)
    retired = 0
    if os.path.exists(trace_path):
        with open(trace_path) as f:
            retired = sum(1 for _ in f)

    return retired, exit_code, None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--only', metavar='GLOB',
                     help="only process programs whose repo-relative path or "
                          "basename matches this glob")
    args = ap.parse_args(argv)

    progs = find_programs()
    if args.only:
        progs = [p for p in progs
                 if fnmatch.fnmatch(p, args.only)
                 or fnmatch.fnmatch(os.path.basename(p), args.only)]

    if not progs:
        sys.stderr.write("gen_fixtures: no programs matched\n")
        return 1

    rows = []
    failed = False

    for rel in progs:
        extra = EXTRA_ISS_ARGS.get(rel, [])
        retired, exit_code, err = process(rel, extra)
        if err is not None:
            sys.stderr.write("FAIL %s: %s\n" % (rel, err))
            failed = True
            rows.append((rel, '-', str(exit_code) if exit_code is not None else 'ASM-ERR'))
        else:
            rows.append((rel, str(retired), str(exit_code)))

    name_w = max((len(r[0]) for r in rows), default=len('program'))
    name_w = max(name_w, len('program'))
    print("%-*s  %8s  %4s" % (name_w, 'program', 'retired', 'exit'))
    print("%-*s  %8s  %4s" % (name_w, '-' * name_w, '-' * 8, '----'))
    for rel, retired, code in rows:
        print("%-*s  %8s  %4s" % (name_w, rel, retired, code))

    if failed:
        sys.stderr.write("\ngen_fixtures: FAILED -- one or more programs hit "
                          "ISS exit 2/3 or an assembler error\n")
        return 1

    print("\ngen_fixtures: OK -- %d programs assembled and ran to ebreak" % len(rows))
    return 0


if __name__ == '__main__':
    sys.exit(main())
