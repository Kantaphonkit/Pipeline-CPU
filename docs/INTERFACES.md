# INTERFACES.md — binding contracts shared by tools, RTL, and testbenches

Owner: Fable (orchestrator). Every subagent task references this file. If a task needs to
change something here, it must say so explicitly in its report — do not silently diverge.
PROJECT-REQUIREMENTS.md remains the authoritative spec; this file only pins the details it
leaves open.

## 1. Instruction set — 46 encodings (final count for the report)

| Group | Count | Instructions |
|---|---|---|
| R-type | 10 | add sub sll slt sltu xor srl sra or and |
| I-arith | 9 | addi slti sltiu xori ori andi slli srli srai |
| Loads | 5 | lb lh lw lbu lhu |
| Stores | 3 | sb sh sw |
| Branches | 6 | beq bne blt bge bltu bgeu |
| U-type | 2 | lui auipc |
| Jumps | 2 | jal jalr |
| System | 9 | ecall ebreak csrrw csrrs csrrc csrrwi csrrsi csrrci mret |

Core = 37 (everything except System). Total with System = 46. Report states "46 encodings
(37 core + 9 system)". All six CSR ops are implemented (csrrc/csrrci are trivial once
csrrw/csrrs/csrrwi exist); this slightly exceeds PROJECT-REQUIREMENTS §3.4 but is not a
scope change.

Encodings follow the RISC-V Unprivileged ISA (RV32I) and Privileged ISA exactly:
- `ecall`  = 0x00000073, `ebreak` = 0x00100073, `mret` = 0x30200073.
- CSR ops: opcode 0x73, funct3 = 001 csrrw, 010 csrrs, 011 csrrc, 101 csrrwi, 110 csrrsi,
  111 csrrci. `zimm = inst[19:15]` zero-extended for the *i forms.
- `fence`/`fence.i`/`wfi` are NOT supported (assembler error).

## 2. Memory map (Harvard)

| Memory | Size | Index | Notes |
|---|---|---|---|
| IMEM | 4 KB = 1024 words | `addr[11:2]` | read-only from CPU, loaded by `$readmemh("<prog>.hex")` |
| DMEM | 4 KB = 1024 words | `addr[11:2]` | byte/half/word, little-endian, loaded by `$readmemh("<prog>.data.hex")` if present |

- Both spaces are addressed 0x00000000–0x00000FFF. IMEM and DMEM are separate arrays;
  address bits above 11 are ignored (wrap). Misaligned lh/lw/sh/sw are don't-care.
- Reset: synchronous, active-high, PC ← 0x00000000.
- Software convention: first instruction sets `sp` (x2) = 0x00001000 (top of DMEM, grows down).
  `.data` section starts at DMEM 0x00000000 unless the program uses `.org`. Test programs
  keep stack and data from overlapping (data is small).
- Halt: `ebreak` retires → CPU raises `done` (level, sticky until reset). Testbench stops
  the sim a few cycles later. `ebreak` is NOT a trap.

## 3. CSRs and trap semantics (interrupt bonus)

| CSR | Addr | Implemented bits |
|---|---|---|
| mstatus | 0x300 | MIE = bit 3, MPIE = bit 7. All other bits read 0, writes ignored. |
| mie | 0x304 | MEIE = bit 11 only. Other bits read 0. |
| mtvec | 0x305 | bits [31:2] (BASE); bits [1:0] always 00 (direct mode). |
| mepc | 0x341 | bits [31:2]; bits [1:0] always 00. |
| mcause | 0x342 | full 32 bits, written by hardware on trap; software-writable. |

Any other CSR address: reads 0, writes ignored (ISS and RTL both; assembler accepts any
12-bit number or the five names above).

- **External interrupt** (`irq` input, level-sensitive): taken when `mstatus.MIE=1`,
  `mie.MEIE=1`, `irq=1`. Taken at instruction boundary: the instruction at PC is *not*
  executed; `mepc ← PC` (of that not-yet-executed instruction), `mcause ← 0x8000000B`,
  `MPIE ← MIE`, `MIE ← 0`, `PC ← mtvec`. ISR must NOT advance mepc.
- **ecall**: synchronous trap, `mepc ← PC of ecall`, `mcause ← 11`, same MIE/MPIE update,
  `PC ← mtvec`. ISR must do `mepc += 4` before `mret` or it re-executes ecall forever.
- **mret**: `PC ← mepc`, `MIE ← MPIE`, `MPIE ← 1`.
- CSR instruction semantics per spec: csrrw always writes; csrrs/csrrc with rs1=x0 (or
  zimm=0) do not write; rd=x0 still performs the write side. Reads return the pre-write value.
- In the RTL, a trap/interrupt flushes younger instructions like a mispredicted branch.

## 4. Assembler — `tools/asm.py`

```
python tools/asm.py prog.s -o prog.hex           # writes prog.hex (+ prog.data.hex if .data non-empty)
python tools/asm.py prog.s -o prog.hex --list    # also writes prog.lst (addr, hex, source)
python tools/asm.py prog.s --bin-json            # prints {"text":[...], "data":[...]} for tools
```

Syntax:
- One instruction per line; `#` and `;` start comments; labels `name:` (may share a line).
- Registers: `x0..x31` and ABI names (zero ra sp gp tp t0-t6 s0/fp s1 a0-a7 s2-s11).
- Loads/stores/jalr: `lw rd, imm(rs1)`; jalr also accepts `jalr rd, rs1, imm` and `jalr rs1`.
- Immediates: decimal, `0x` hex, negative, `%hi(sym)`, `%lo(sym)`, and bare label names for
  branches/jal (PC-relative computed by assembler). `%hi`/`%lo` use the sign-adjusted
  convention so `lui rd,%hi(x); addi rd,rd,%lo(x)` yields x.
- Range checking: assembler errors on immediates out of range for the format.
- Directives: `.text`, `.data`, `.word v[,v...]`, `.half`, `.byte`, `.space n`, `.align n`
  (power of two), `.org addr`, `.globl` (ignored), `.equ name, value`.
- Pseudo-instructions: `nop`, `li rd,imm` (addi or lui+addi), `mv`, `not`, `neg`, `seqz`,
  `snez`, `sltz`, `sgtz`, `j label`, `jr rs`, `ret`, `call label` (jal ra), `beqz`, `bnez`,
  `blez`, `bgez`, `bltz`, `bgtz`, `bgt`, `ble`, `bgtu`, `bleu`, `la rd,sym` (lui+addi, absolute
  since data space is flat), `csrr`, `csrw`, `csrs`, `csrc`, `csrwi`, `csrsi`, `csrci`.
- `.hex` format: one 8-hex-digit word per line, lowercase, no `@` addresses, no comments,
  exactly 1024 lines (zero padded) so `$readmemh` fills the whole array deterministically.
  `.data.hex` same format for DMEM.

## 5. ISS — `tools/iss.py`

```
python tools/iss.py prog.hex [--data prog.data.hex] [--trace prog.trace]
                    [--max-insns N] [--irq-after N] [--dump-regs] [--dump-mem lo hi]
```

- Executes from PC=0 until `ebreak` (exit 0), `--max-insns` exceeded (exit 2), or an illegal
  instruction (exit 3, message to stderr).
- `--irq-after N`: assert `irq` at the instruction boundary before retirement index N
  (0-based, counting retired instructions). Model: irq is a one-shot pulse checked at that
  single boundary; if `MIE=0` or `MEIE=0` at that moment, the interrupt is dropped. The
  interrupt demo program therefore enables MIE before the irq is scheduled. The RTL
  testbench drives `irq` as a level and drops it once it observes the trap (PC == mtvec).
  May be given multiple times for multiple interrupts.
- `--dump-regs`: after halt, prints `x<n>=<08x>` for n=0..31 one per line to stdout.
- Exit codes are the testbench contract; do not change them.

### Commit trace format (byte-exact, shared with the Verilog testbench)

One line per retired instruction, fields separated by a single space, all hex lowercase,
zero-padded to 8 digits:

```
<pc> <insn>                              # no architectural side effect visible (e.g. branch, sw to x0? no — see below)
<pc> <insn> x<rd>=<value>                # rd written and rd != 0
<pc> <insn> mem[<addr>]=<value>          # store: addr = effective byte address, value = stored data masked to width, zero-extended to 32 bits
<pc> <insn> x<rd>=<value> mem[<addr>]=<value>   # never occurs in RV32I (kept for format completeness)
```

- `x<rd>` uses decimal register number, no padding (`x5`, `x31`).
- Writes to x0 are not printed. CSR instructions print `x<rd>=` only if rd != 0.
- Traps: the trapping/interrupted instruction is not retired and prints nothing; the first
  ISR instruction prints normally. `mret` prints `<pc> <insn>` (no rd).
- `ebreak` prints `<pc> 00100073` as its final line, then the trace ends.
- Trace is written with `\n` line endings, no trailing blank line issues (one `\n` after the
  last line). Verilog side uses `$fwrite(fd, "%08x %08x", ...)`.

## 6. RTL top-level (`rtl/cpu_top.v`) — fixed port list

```verilog
module cpu_top #(
    parameter FORWARDING = 1,          // 0 = disable forwarding (stall instead) for CPI comparison
    parameter BHT_ENABLE = 1,          // 0 = always predict not-taken
    parameter IMEM_INIT  = "prog.hex", // $readmemh file
    parameter DMEM_INIT  = ""          // "" = leave DMEM zero
) (
    input  wire        clk,
    input  wire        rst,            // synchronous, active-high
    input  wire        irq,            // external interrupt, level
    output wire        done,           // ebreak retired (sticky)
    // commit-trace port (WB stage), sampled by the testbench when trace_valid=1
    output wire        trace_valid,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_insn,
    output wire        trace_rd_we,    // rd written and rd != 0
    output wire [4:0]  trace_rd,
    output wire [31:0] trace_rd_val,
    output wire        trace_mem_we,   // store retired
    output wire [31:0] trace_mem_addr,
    output wire [31:0] trace_mem_val,  // masked-to-width store data
    // performance counters (free-running from reset)
    output wire [31:0] perf_cycles,
    output wire [31:0] perf_insns,     // instructions retired (incl. ebreak)
    output wire [31:0] perf_lu_stalls, // load-use stall cycles
    output wire [31:0] perf_flushes,   // control-flow flush events (branch/jump/trap)
    output wire [31:0] perf_bht_pred,  // branches predicted (conditional branches seen in EX)
    output wire [31:0] perf_bht_miss   // mispredicts
);
```

Testbenches also read the register file and CSRs hierarchically (`dut.u_regfile.regs[n]`,
`dut.u_csr.mepc`, ...) for the per-instruction tests. The regfile array must be named `regs`
and the CSR module instance `u_csr` with registers named `mstatus_mie`, `mstatus_mpie`,
`mie_meie`, `mtvec`, `mepc`, `mcause`.

## 7. Simulation flow — `sim/run.ps1` and `sim/run.sh`

```
./sim/run.sh  tb_alu                     # compile rtl/*.v + tb/tb_alu.v, elaborate, run
./sim/run.sh  tb_program -g PROG=asm/fib # pass -generic style overrides (xelab -generic_top)
```

- Uses `D:/AMDDesigntools/2026.1/Vivado/bin/{xvlog,xelab,xsim}` (override with `$VIVADO_BIN`).
- Work dir: `sim/work/<tb>/` (git-ignored). Log: `sim/work/<tb>/sim.log`.
- Exit code = 0 iff the log contains a line starting with `PASS` and no line starting with
  `FAIL`. Every testbench must print exactly one final `PASS: <name>` or `FAIL: <name> ...`
  and then `$finish`.
- Testbenches that need a program take it via a Verilog parameter/`-generic_top` or a
  `+PROG=` plusarg (`$value$plusargs`), pointing at a path relative to the repo root; the
  run script always launches xsim with the repo root as CWD.

> **Environment note (Thai repo path):** Vivado's xvlog/xelab/xsim cannot operate with a CWD
> containing non-ANSI characters, and this repo lives under `OneDrive/เอกสาร/`. Both run
> scripts therefore execute the tools inside an ASCII-only shadow dir under `%LOCALAPPDATA%`
> that holds NTFS junctions `rtl/`, `tb/`, `asm/` back to the repo, then copy `sim.log` (and
> `.wdb`) back to `sim/work/<tb>/`. Relative `$readmemh("asm/...")` paths work unchanged.
> Testbenches must only reference files via `rtl/`, `tb/`, `asm/` relative paths.
