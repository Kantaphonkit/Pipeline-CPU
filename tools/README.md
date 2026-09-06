# tools/ — assembler, golden-reference ISS, cross-validation

Pure Python 3 standard library. Contracts: `docs/INTERFACES.md` §1–§5.

```
python tools/asm.py asm/smoke.s -o sim/work/smoke.hex [--list] [--bin-json]
python tools/iss.py sim/work/smoke.hex [--data X.data.hex] [--trace f]
       [--max-insns N] [--irq-after N ...] [--dump-regs] [--dump-mem LO HI]
python tools/test_tools.py            # 4300+ self-checks, exit 0 = all pass
```

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
