# tools/ — assembler, golden-reference ISS, cross-validation

Pure Python 3 standard library. Contracts: `docs/INTERFACES.md` §1–§5.

```
python tools/asm.py asm/smoke.s -o sim/work/smoke.hex [--list] [--bin-json]
python tools/iss.py sim/work/smoke.hex [--data X.data.hex] [--trace f]
       [--max-insns N] [--irq-after N ...] [--dump-regs] [--dump-mem LO HI]
python tools/test_tools.py            # 4300+ self-checks, exit 0 = all pass
python tools/gen_control_table.py     # regenerate the decode truth table + vectors
python tools/gen_control_table.py --check   # fail if those outputs are stale
```

`gen_control_table.py` owns the per-instruction control settings as a Python
dict -- that dict is the single source of truth behind both `docs/DESIGN.md`
section 3 (spliced between the `CONTROL-TABLE-BEGIN/END` markers) and
`tb/vectors/control_vectors.hex` (consumed by `tb/tb_control.v`), so the report
table and the RTL test cannot drift apart.  Stimulus words come from
`asm.encode`; every word's expected mnemonic (or its illegality) is confirmed by
`iss.decode` before a vector is emitted.

`run_tests.py` drives `tb/tb_program.v` over a directory of `.s` programs:

```
python tools/run_tests.py --dir asm/insn                 # trace + register check
python tools/run_tests.py --dir asm/prog --fwd 0         # forwarding off
python tools/run_tests.py --dir asm/prog --bht 0         # predictor off
python tools/run_tests.py --dir asm/prog --irq-at 200,500  # external interrupts
python tools/run_tests.py --dir asm/insn --no-batch        # recompile per program
```

**One elaboration per run, not per program.** Every program in one invocation
is simulated with the same design and the same generics -- only the `+PROG`
plusarg differs -- so the programs are grouped by their (`FORWARDING`,
`BHT_ENABLE`) pair and `sim/run.sh --elab-only --tag <group>` builds a single
snapshot up front; each program then runs `sim/run.sh --sim-only --tag
<group>`, which is one `xsim` launch and nothing else. The simulations are
byte-for-byte the same ones the per-program path ran -- same snapshot, same
plusargs -- so the PASS/FAIL verdicts and PERF numbers are unchanged; only the
`xvlog` + `xelab` that dominated the wall time is gone. Measured on
`--dir asm/insn` (46 programs): **347 s -> 144 s**. `--no-batch` restores the
old recompile-per-program path as an escape hatch.

**Interrupt programs are diffed through a derived-index flow, not against the
committed `.trace` fixture.** `iss.py --irq-after N` traps at the boundary
after N instructions have retired, and `irq_demo.trace` is generated with the
fixed schedule `--irq-after 50 --irq-after 120`. The RTL's N is a different
number: it depends on how many instructions happened to be in MEM and WB when
the interrupt level arrived, which is a function of the cycle the testbench
raises `irq`, the forwarding setting and the branch predictor. So `run_tests.py
--irq-at` instead:

1. runs the RTL with `+NOTRACE +IRQ_AT1=…` and lets `tb_program` measure the
   index itself -- it prints `IRQ_TAKEN retire_index=<N>` when the first
   instruction at `mtvec` retires after each trap;
2. re-runs `iss.py` with those measured `--irq-after N` values;
3. diffs the two traces in Python, byte for byte (line endings normalised:
   xsim's `$fwrite` writes CRLF on Windows, `iss.py` writes LF).

The register check still uses the committed `.regs` fixture, which is
timing-independent for `irq_demo` by construction (`x10 = 200`, `x11 = 2`).
The committed `irq_demo.trace` stays as the reference-model artefact for the
report; nothing regenerates it.

One modelling difference is deliberate: the ISS's `irq` is a one-shot pulse
that is *dropped* if `MIE`/`MEIE` are clear at that instant, while the RTL
input is a level the testbench *holds* until it observes the trap. They agree
whenever an interrupt arrives with interrupts already enabled. `tb/tb_irq.v`
covers the round trip directly, and a run with an irq scheduled inside the ISR
demonstrates the held-level case.

`asm.py` writes exactly 1024 lowercase 8-hex-digit lines (`$readmemh` fills the
whole 4 KB array), plus `<base>.data.hex` when `.data` is non-empty.
ISS exit codes are the testbench contract: **0** ebreak, **2** `--max-insns`
exceeded, **3** illegal instruction.

Both are importable:

```python
from asm import assemble, encode, encode_all, AsmError   # encode("addi","x1","x0","-1")
from iss import Cpu, decode, IllegalInstruction          # Cpu(text, data).step()/.run()
```

Details INTERFACES.md leaves open, decided here:

- `.align n` aligns to an **n-byte** boundary; `n` must be a power of two.
- `li rd, imm` needs a constant (literal or earlier `.equ`); use `la` for
  symbols. It is 1 instruction if the value fits in 12 signed bits, else
  `lui`+`addi` (always 2, so pass 1 sizing is exact). `la` is always 2.
- `iss.py` auto-loads `<base>.data.hex` next to the program when `--data` is
  omitted and that file exists.
- `--max-insns` counts executed steps (traps included), not just retirements.
- `--dump-mem LO HI` prints `mem[<08x>]=<08x>` per word, `LO` rounded down.
- `--bin-json` prints trimmed word lists as JSON integers.
- Misaligned accesses (don't-care per spec) are modelled the way the RTL will
  behave: word index is `addr[11:2]`, half/byte lane selected by `addr[1:0]`.
