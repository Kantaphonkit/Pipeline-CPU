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

## 8. Internal RTL encodings (fixed so modules built in parallel agree)

### 8.1 `imm_gen.v`
```verilog
module imm_gen (input wire [31:0] inst, input wire [2:0] imm_sel, output reg [31:0] imm);
```
| imm_sel | Format | Bits |
|---|---|---|
| 3'd0 | I | `{{20{inst[31]}}, inst[31:20]}` (also used for jalr, loads, shift-imm; ALU masks `[4:0]` for shifts) |
| 3'd1 | S | `{{20{inst[31]}}, inst[31:25], inst[11:7]}` |
| 3'd2 | B | `{{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}` |
| 3'd3 | U | `{inst[31:12], 12'b0}` |
| 3'd4 | J | `{{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}` |
| 3'd5 | Z | `{27'b0, inst[19:15]}` (CSR zimm, zero-extended) |
| others | — | 32'b0 |

### 8.2 `alu.v`
```verilog
module alu (input wire [31:0] a, input wire [31:0] b, input wire [3:0] alu_op, output reg [31:0] y);
```
| alu_op | Name | y |
|---|---|---|
| 4'd0 | ADD | a + b |
| 4'd1 | SUB | a - b |
| 4'd2 | SLL | a << b[4:0] |
| 4'd3 | SLT | ($signed(a) < $signed(b)) ? 1 : 0 |
| 4'd4 | SLTU | (a < b) ? 1 : 0 |
| 4'd5 | XOR | a ^ b |
| 4'd6 | SRL | a >> b[4:0] |
| 4'd7 | SRA | $signed(a) >>> b[4:0] |
| 4'd8 | OR | a \| b |
| 4'd9 | AND | a & b |
| 4'd10 | PASSB | b (lui: b = U-imm) |
| others | — | 32'b0 |

`b` is already the muxed operand (rs2 or immediate); the ALU always uses `b[4:0]` as shift
amount, which satisfies both the `rs2[4:0]` and `imm[4:0]` rules. Branch comparisons are
NOT done in the ALU — `branch_unit.v` compares rs1/rs2 directly.

### 8.3 `regfile.v`
```verilog
module regfile (
    input wire clk, input wire we, input wire [4:0] waddr, input wire [31:0] wdata,
    input wire [4:0] raddr1, input wire [4:0] raddr2,
    output wire [31:0] rdata1, output wire [31:0] rdata2);
// reg [31:0] regs [0:31];  -- array MUST be named regs (testbench hierarchical access)
```
- Asynchronous (combinational) read with WB→ID bypass: if `we && waddr==raddr && waddr!=0`
  the read returns `wdata`. Synchronous write on posedge clk; writes to x0 ignored; x0 always
  reads 0. No reset on the array (x1..x31 uninitialized per spec §3.3). Not 2019.2-hostile:
  plain `always @(posedge clk)` + `assign`.

### 8.4 `branch_unit.v` (for step 5, listed now for completeness)
```verilog
module branch_unit (input wire [31:0] rs1, input wire [31:0] rs2, input wire [2:0] funct3, output wire taken);
```
funct3: 000 beq, 001 bne, 100 blt, 101 bge, 110 bltu, 111 bgeu; others → 0.

## 9. Control signals (`control.v`, `alu_ctrl.v`)

```verilog
module control (
    input  wire [6:0] opcode, input wire [2:0] funct3, input wire [6:0] funct7,
    input  wire [4:0] rs1,    input wire [11:0] csr_addr,   // rs1 for CSR write-suppression, csr_addr for mret detect
    output reg        reg_we,        // rd written
    output reg        alu_src_a,     // 0 = rs1, 1 = PC (auipc)
    output reg        alu_src_b,     // 0 = rs2, 1 = imm
    output reg  [2:0] imm_sel,       // §8.1
    output reg  [1:0] alu_class,     // 0 ADD (mem addr / auipc), 1 R-type, 2 I-type, 3 LUI(PASSB)
    output reg        mem_re, mem_we,// funct3 carried separately for width/sign
    output reg  [1:0] wb_sel,        // 0 alu, 1 mem, 2 pc+4, 3 csr
    output reg        branch,        // conditional branch (resolve in EX)
    output reg        jal,           // resolve in ID
    output reg        jalr,          // resolve in EX
    output reg        csr_en,        // any CSR instruction (read side)
    output reg        csr_we,        // CSR write side actually happens (csrrw always; rs/rc: rs1/zimm != 0)
    output reg        csr_imm,       // zimm form (use imm Z instead of rs1 value)
    output reg        mret, ecall, ebreak,
    output reg        illegal);
```

- `alu_ctrl(alu_class, funct3, funct7_bit30) -> alu_op[3:0]` per §8.2. **Only** class 1 (R-type)
  and class 2 with funct3 = 101 (srli/srai) may look at bit 30. Class 2 with funct3=000 (addi)
  is ADD regardless of bit 30 (classic bug).
- CSR ALU op: csrrw → new = src; csrrs → new = old | src; csrrc → new = old & ~src, where
  src = rs1 value or zimm. Computed in `csr.v`, not the ALU.
- `illegal` = 1 for unknown opcode/funct: RTL treats as NOP (no trap) — spec doesn't require
  illegal-instruction traps. Perf counters don't count it as retired.

## 10. Pipeline plan (binding for steps 4–5)

| Stage | Does |
|---|---|
| IF | PC register, PC-select mux, IMEM read (sync, 1 cycle → instruction available in ID). BHT lookup (step 7). |
| ID | control decode, regfile read (with WB bypass), imm_gen, **jal target = PC + J-imm → redirect, flush IF (1 bubble)**, hazard detection (load-use stall). |
| EX | forwarding muxes (A, B, and store-data), ALU, branch_unit, **branch/jalr resolution → redirect, flush IF+ID (2 bubbles)**, CSR read/modify, trap detection (ecall / external irq) + mepc/mcause update, mret redirect. |
| MEM | DMEM access (sync write, sync read), byte-lane select/extend for loads in MEM→WB boundary. |
| WB | wb mux (alu / mem / pc+4 / csr) → regfile write. Commit-trace port + perf `insns` count here. |

- **PC-select priority (highest first):** reset → trap (EX, PC=mtvec) → mret (EX, PC=mepc) →
  branch-taken/jalr (EX) → jal (ID) → BHT predicted-taken (IF, step 7) → PC+4. The stall
  signal holds PC and IF/ID. A redirect from EX means the instruction in ID is being flushed,
  so any stall it raised is moot — **redirect overrides stall**.
- **Flush = insert bubble:** IF/ID and ID/EX registers cleared to a NOP with all control
  signals 0 (`reg_we=mem_we=csr_we=branch=jal=jalr=0`, etc.).
- **Load-use stall:** ID/EX.mem_re && ID/EX.rd != 0 && (ID/EX.rd == IF/ID.rs1 || rs2) → hold PC
  and IF/ID one cycle, bubble ID/EX. With `FORWARDING=0`, the hazard unit stalls on *any*
  RAW against EX/MEM or MEM/WB destinations instead (up to 2 cycles), and the forward muxes
  are forced to pass regfile data. That parameter difference is the CPI experiment.
- **Forwarding (FORWARDING=1):** EX/MEM.reg_we && EX/MEM.rd != 0 && rd == rs → 2'b10;
  else MEM/WB same → 2'b01; else 2'b00. Applies to A, B, and store-data. EX/MEM source data
  = ALU result (for loads in EX/MEM the load-use stall guarantees the consumer isn't in EX yet).
- **ebreak:** retires normally through WB (appears in trace + counted); sets sticky `done`.
  Instructions after it in the pipeline are flushed at the EX stage so nothing younger commits.
- **Trap point:** EX. `mepc` ← EX-stage PC. For an external irq, the interrupt is attached to
  the instruction currently in EX (it is squashed, not retired, mepc = its PC) — only when
  that EX slot holds a valid (non-bubble) instruction, so mepc is always a real PC.
- **CSR hazards:** a CSR write in EX and a CSR read by the next instruction: csr.v forwards its
  freshly-written value combinationally (single-cycle RMW in EX), so no stall needed. `mret`
  right after `csrw mepc` works because mepc is written at the end of the cycle in which the
  csrw is in EX and mret reads it a cycle later in its own EX.
- **Trace port** (`trace_*` in §6) is registered at the WB stage: `trace_valid` = 1 for one
  cycle per retired instruction, including bubbles = 0. `trace_mem_val` for `sb`/`sh` is the
  data masked to width (`& 0xff` / `& 0xffff`).

### 8.5 `pc.v`
```verilog
module pc (input wire clk, input wire rst, input wire en, input wire [31:0] pc_next, output reg [31:0] pc_q);
// posedge: if (rst) pc_q <= 0; else if (en) pc_q <= pc_next;
```

### 8.6 `imem.v` — synchronous read with enable (BRAM-inferable)
```verilog
module imem #(parameter INIT = "asm/smoke.hex") (
    input wire clk, input wire en, input wire [31:0] addr, output reg [31:0] inst);
// reg [31:0] mem [0:1023]; initial $readmemh(INIT, mem);
// always @(posedge clk) if (en) inst <= mem[addr[11:2]];
```
`en` = ~stall: when the pipeline stalls, IF/ID must hold, and because the instruction word
lives in imem's output register, holding PC alone is not enough (PC has already advanced).
cpu_top keeps `if_id_pc` and `if_id_valid` alongside; flush clears `if_id_valid` so ID sees a
NOP regardless of `inst`.

### 8.7 `dmem.v` — synchronous, byte lanes handled inside
```verilog
module dmem #(parameter INIT = "") (
    input  wire        clk,
    input  wire        we,            // store in MEM stage
    input  wire        re,            // load in MEM stage
    input  wire [31:0] addr,          // effective byte address
    input  wire [2:0]  funct3,        // 000 b, 001 h, 010 w, 100 bu, 101 hu
    input  wire [31:0] wdata,         // rs2 value (already forwarded); dmem masks/shifts by lane
    output wire [31:0] rdata);        // load result, extended, valid the cycle after `re` (WB stage)
```
- `reg [31:0] mem [0:1023]`; `initial` zero-fills, then `$readmemh(INIT, mem)` only when
  `INIT != ""` (must work in xsim for both cases — test both).
- Write: `mem[addr[11:2]]` byte-lane update from `addr[1:0]` and funct3[1:0] (sb: 1 byte,
  sh: 2 bytes, sw: 4). Little-endian: byte 0 = bits [7:0].
- Read: on posedge with `re`, register `mem[addr[11:2]]`, `addr[1:0]`, `funct3`; `rdata` is the
  combinational lane-select + sign/zero extension of those registered values.
- Also expose `output wire [31:0] wmask_data` — the store data masked to width and NOT shifted
  (sb: `{24'b0, wdata[7:0]}`, sh: `{16'b0, wdata[15:0]}`, sw: wdata) for the trace port.

### 8.8 `perf_counters.v`
```verilog
module perf_counters (input wire clk, input wire rst,
    input wire retire, input wire lu_stall, input wire flush, input wire bht_pred, input wire bht_miss,
    output reg [31:0] cycles, output reg [31:0] insns, output reg [31:0] lu_stalls,
    output reg [31:0] flushes, output reg [31:0] bht_preds, output reg [31:0] bht_misses);
```
All counters clear on rst; `cycles` increments every non-reset cycle; the others increment
when their input is 1. Counting stops when `done` (cpu_top gates `retire` etc. — perf module
stays dumb).
