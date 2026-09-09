# PROJECT-EXPLAINED — a study guide to the RV32I pipelined CPU

*Written for Kantaphon, to defend this design in an oral exam. Every claim
points at a real line of code (`file:line`) so you can open the file and see
it yourself. Read it with the RTL open in a second window.*

**How to use this guide.** Chapters 1–5 walk the pipeline stage by stage.
Chapters 6–9 explain the four "intelligence" units. Chapter 10 is the wiring
hub. Chapters 11–12 cover how the design was tested and synthesised. Chapter
13 is the examiner Q&A. If you only have one hour, read chapters 6, 7 and 13.

---

## 0. The big picture in one minute

The CPU executes the RV32I base integer instruction set (32-bit RISC-V, no
multiply, no floating point) on a classic **5-stage in-order pipeline**:

| Stage | Name | One-line job |
|---|---|---|
| IF | Instruction Fetch | Read the next instruction from instruction memory |
| ID | Instruction Decode | Turn the 32 bits into control signals, read registers |
| EX | Execute | ALU, branch decision, CSR read-modify-write, traps |
| MEM | Memory | Load or store data memory |
| WB | Write Back | Write the result into the register file |

**Pipeline analogy.** Think of a car wash with five bays. Five cars are being
worked on at once, each in a different bay, and every clock tick every car
moves one bay forward. Throughput is one car per tick even though each car
spends five ticks inside. The "hazard" problem is what happens when the car in
bay 3 needs a part that the car in bay 4 has not finished making yet.

Everything is plain synthesisable Verilog-2001. The top-level module is
`rtl/cpu_top.v`, and it has two compile-time knobs
(`rtl/cpu_top.v:50-51`):

- `FORWARDING` (1 = bypass network on, 0 = stall on every RAW hazard);
- `BHT_ENABLE` (1 = branch predictor on, 0 = always predict not-taken).

Those two knobs are why the test suite runs as a **2 × 2 sweep** (chapter 11).

---

## 1. IF — Instruction Fetch

**Concept.** IF answers one question every cycle: *which instruction comes
next?* It holds the program counter (PC), presents it to the instruction
memory, and in parallel asks the branch predictor "if this turns out to be a
branch, will it be taken?" The answer travels down the pipe with the
instruction so ID can act on it without a second lookup.

**Modules.** `rtl/pc.v`, `rtl/imem.v`, `rtl/bht.v` (lookup half),
`rtl/if_id.v`.

**Key wires (all in `rtl/cpu_top.v` unless noted).**

| Signal | Where | Meaning |
|---|---|---|
| `fetch_en` | `cpu_top.v:123` | `~halt & (redirect \| ~stall)`. The PC and IMEM advance when not stalled, **or** when a redirect overrides the stall. |
| `pc_q` / `pc_next` | `cpu_top.v:125-131`, `pc.v:12-17` | The PC register. Loads `pc_next` when `en` is high, resets to 0. |
| `if_inst` | `cpu_top.v:133-138`, `imem.v:25-28` | IMEM is a **synchronous-read** block RAM: the word appears one edge later, i.e. in ID. |
| `bht_pred_state_if` | `cpu_top.v:145-154`, `bht.v:72-80` | 2-bit counter looked up with the same `pc_q` that IMEM is reading. |
| `if_id_pc`, `if_id_valid`, `if_id_pred_state` | `cpu_top.v:163-174`, `if_id.v:45-54` | The IF/ID register. Note it carries PC, valid, and the prediction, but **not** the instruction word. |

**Why IF/ID has no instruction field.** Because `imem.v` already registers
its output (`imem.v:27`), that output register *is* the instruction half of
IF/ID. Registering the word again would add a wasted cycle. So `cpu_top` drives
IMEM's `en` and IF/ID's enable with the same `fetch_en` so the two halves stay
in step (`cpu_top.v:135`, `cpu_top.v:166`). Read the header of `if_id.v:1-28`
for the designers' own explanation.

**Where the next PC comes from.** The PC-select mux at `cpu_top.v:530-538`
has seven inputs in strict priority order: trap → mret → mispredicted
branch → jalr → jal → BHT predicted-taken → PC+4. Chapter 10 walks it.

---

## 2. ID — Instruction Decode

**Concept.** ID reads the 32-bit instruction word and produces (a) the control
word that tells every later stage what to do, (b) the immediate constant
embedded in the instruction, and (c) the two source register values. It also
resolves `jal` early, because a `jal` target only needs PC + immediate, which
ID already has.

**Modules.** `rtl/control.v`, `rtl/alu_ctrl.v`, `rtl/imm_gen.v`,
`rtl/regfile.v`, `rtl/id_ex.v`.

**Key wires.**

| Signal | Where | Meaning |
|---|---|---|
| `id_inst` | `cpu_top.v:181` | `if_id_valid ? if_inst : NOP`. A flushed slot decodes as `addi x0,x0,0` no matter what IMEM's register holds. |
| `id_opcode … id_csr_addr` | `cpu_top.v:183-189` | Field slicing: opcode `[6:0]`, funct3 `[14:12]`, funct7 `[31:25]`, rs1 `[19:15]`, rs2 `[24:20]`, rd `[11:7]`. |
| control outputs | `cpu_top.v:200-224`, `control.v:116-330` | `reg_we`, `alu_src_a/b`, `imm_sel`, `alu_class`, `mem_re/we`, `wb_sel`, `branch`, `jal`, `jalr`, CSR flags, `mret/ecall/ebreak`, `illegal`. |
| `id_imm` | `cpu_top.v:227-231`, `imm_gen.v:46-58` | The six immediate formats I/S/B/U/J/Z. |
| `id_alu_op` | `cpu_top.v:234-239`, `alu_ctrl.v:57-90` | Second-level decode to the 4-bit ALU opcode. |
| `id_rs1_val`, `id_rs2_val` | `cpu_top.v:247-256`, `regfile.v:23-29` | Asynchronous read **with WB→ID bypass**. |
| `id_uses_rs1`, `id_uses_rs2` | `cpu_top.v:261-266` | "Does this instruction really read rs1/rs2?" Feeds the hazard unit only. |
| `id_redirect_target` | `cpu_top.v:285` | `if_id_pc + id_imm`, shared by `jal` and the predicted-taken branch. |
| `jal_taken`, `bht_taken`, `redirect_id` | `cpu_top.v:289-291` | ID-stage redirects, both gated with `~stall`. |

**Three decode facts examiners like.**

1. **`imm_gen` is where the bugs live.** The B and J formats scramble bits:
   B is `{inst[31], inst[7], inst[30:25], inst[11:8], 0}` (`imm_gen.v:50-51`)
   and J is `{inst[31], inst[19:12], inst[20], inst[30:21], 0}`
   (`imm_gen.v:53-54`). Both already include the implicit low zero, so they are
   byte offsets. Z (CSR zimm) is the only **zero**-extended immediate
   (`imm_gen.v:55`).
2. **`addi rd, rs1, -1` must stay ADD.** A negative I-immediate has
   `inst[30] = 1`, which is the same bit that means SUB for R-type. So
   `alu_ctrl` consults `inst[30]` for R-type (`alu_ctrl.v:62`) and for the
   shift-immediates (`alu_ctrl.v:79`), but **never** for plain `addi`
   (`alu_ctrl.v:74`).
3. **Illegal instructions become NOPs, not traps.** `control.v` zeroes the
   whole control word and raises `illegal` (`control.v:116-135`,
   `control.v:304`). They still flow through but are not retired or traced
   (`cpu_top.v:649`).

**The regfile bypass.** `regfile.v:23-29`: if the WB stage is writing register
`r` this cycle and ID is reading `r`, the read returns the write data. x0 reads
zero unconditionally, and the write is suppressed for x0 (`regfile.v:31-35`).
This bypass is why a producer three slots ahead needs no forwarding logic.

**The ID/EX register.** `cpu_top.v:311-374` and `id_ex.v:97-128`. A bubble is
"every field zero", which is a genuine NOP control word. Flush has priority
over stall (`id_ex.v:98`).

---

## 3. EX — Execute

**Concept.** EX is where values are actually computed and where every
"surprise" is discovered: a branch turns out taken, a `jalr` target becomes
known, an `ecall` or an external interrupt fires, an `mret` returns. It is the
busiest stage because the forwarding muxes sit at its entrance, so every
operand it sees is already the freshest value in the machine.

**Modules.** `rtl/forward_unit.v` (selects), `rtl/alu.v`,
`rtl/branch_unit.v`, `rtl/csr.v`, `rtl/bht.v` (update half), `rtl/ex_mem.v`.

**Key wires.**

| Signal | Where | Meaning |
|---|---|---|
| `fwd_a`, `fwd_b`, `fwd_c` | `cpu_top.v:398-408` | 2-bit selects from the forward unit. |
| `fwd_src_mem`, `fwd_src_wb` | `cpu_top.v:412-413` | The two bypass sources: EX/MEM `res`, and the WB write data. |
| `ex_a_val`, `ex_b_val`, `ex_store_data` | `cpu_top.v:415-421` | The three forwarding muxes. |
| `alu_a`, `alu_b` | `cpu_top.v:423-424` | `alu_src_a` picks PC (auipc only); `alu_src_b` picks the immediate. |
| `alu_y` | `cpu_top.v:427-432`, `alu.v:11-26` | 11 operations. Shifts use `b[4:0]` only (`alu.v:15`, `alu.v:20`). |
| `branch_cond` | `cpu_top.v:435-440`, `branch_unit.v:15-25` | Compares the **forwarded** rs1/rs2, not the ALU output. |
| `csr_rdata`, `csr_wsrc` | `cpu_top.v:442-464` | CSR read-modify-write, chapter 8. |
| `irq_taken`, `trap_taken`, `trap_cause` | `cpu_top.v:484-487` | Interrupt outranks ecall. |
| `mret_taken`, `jalr_taken`, `br_redirect`, `redirect_ex` | `cpu_top.v:490-501` | All EX-stage control-flow events. |
| `bht_update_en` | `cpu_top.v:507` | Train the predictor on every real branch. |
| `ebreak_pending` | `cpu_top.v:514-516` | The halt shadow (ebreak in EX, MEM or WB). |
| `ex_branch_target`, `ex_jalr_target`, `ex_correct_target` | `cpu_top.v:518-527` | Where to go if the prediction was wrong. |
| `ex_res` | `cpu_top.v:541-548` | The ALU / PC+4 / CSR result mux, chosen **in EX**. |
| `flush_ex` | `cpu_top.v:553` | Squash the trapping instruction at the EX/MEM boundary. |

**Why the result mux is in EX and not WB.** `ex_mem.v:4-10` explains it: the
EX/MEM register carries `res`, which is *the value the instruction will write
back*. For `jal`/`jalr` that is PC+4, for `csrr*` it is the old CSR value. If
EX/MEM carried the raw ALU output, then forwarding from EX/MEM to a consumer of
`jalr`'s `rd` would hand it a jump target instead of a link address. WB then
only has to choose between `res` and load data (`cpu_top.v:644`).

**Branch resolution.** A conditional branch only redirects when the
prediction was **wrong**: `br_redirect = ex_branch_valid & (ex_pred_taken !=
branch_cond)` (`cpu_top.v:498`). If it mispredicted, the correct target is
either PC + B-imm (branch really taken) or PC + 4 (predicted taken, actually
not) (`cpu_top.v:526-527`). `jalr` masks bit 0 of `rs1 + imm`
(`cpu_top.v:519`) as the ISA requires.

---

## 4. MEM — Memory

**Concept.** MEM talks to data memory. Stores write byte lanes; loads read a
whole word now and pick the right byte or half-word in the next stage.

**Modules.** `rtl/dmem.v`, `rtl/mem_wb.v`.

**Key wires.**

| Signal | Where | Meaning |
|---|---|---|
| `u_dmem` ports | `cpu_top.v:596-605` | `addr = mem_res` (the ALU address), `wdata = mem_store_data` (already forwarded in EX). |
| byte-lane write | `dmem.v:33-55` | `sb`/`sh`/`sw` choose lanes from `addr[1:0]` (`dmem.v:38` is the first `sb` lane). |
| registered read | `dmem.v:62-68` | On the MEM edge, capture the word, `addr[1:0]` and `funct3`. |
| lane extension | `dmem.v:74-95`, `dmem.v:97` | Combinational select + sign/zero extension on the *registered* word, i.e. this logic executes during WB. |
| `mem_wb` | `cpu_top.v:610-639`, `mem_wb.v:51-61` | Carries `res`, `rd`, `reg_we`, `wb_sel`, trace fields. Load data is **not** registered here; `dmem` already holds it. |

**Why the load extension "belongs to WB".** `dmem.v` registers the raw word
at the MEM clock edge and extends it combinationally afterward
(`mem_wb.v:4-9` says this explicitly). That places the lane mux in the WB
cycle, which is exactly where the synthesis critical path starts (chapter 12).

Both memories are forced into block RAM with `(* ram_style = "block" *)`
(`imem.v:20`, `dmem.v:21`); the register file is forced to distributed LUT RAM
(`regfile.v:20`). Chapter 12 explains why that matters.

---

## 5. WB — Write Back

**Concept.** WB commits the instruction: it writes the register file, reports
the commit on the trace port for the testbench, and pulses the performance
counters. It is also where `ebreak` finally stops the machine.

**Modules.** `rtl/regfile.v` (write port), `rtl/perf_counters.v`.

**Key wires.**

| Signal | Where | Meaning |
|---|---|---|
| `wb_data` | `cpu_top.v:644` | `(wb_sel == MEM) ? dmem_rdata : wbs_res`. The only mux WB needs. |
| `wb_reg_we` | `cpu_top.v:646` | `valid & reg_we & rd != 0 & ~halt`. Second line of defence for x0. |
| `wb_retire` | `cpu_top.v:649` | `valid & ~illegal & ~halt`. |
| `done_r` / `halt` | `cpu_top.v:652-661` | Sticky flag set when a valid `ebreak` reaches WB. Freezes every register via their `stall = halt` port. |
| trace port | `cpu_top.v:666-674` | PC, instruction, rd/value, store addr/value, in the ISS's exact format. |
| perf counters | `cpu_top.v:689-703`, `perf_counters.v:23-39` | cycles, insns, lu_stalls, flushes, bht_preds, bht_misses. |

`wb_data` is also `fwd_src_wb` (`cpu_top.v:413`), so the same value that goes
into the register file is what the MEM/WB→EX bypass delivers.

---

## 6. forward_unit.v — the bypass network

**The problem it solves.** A RAW (read-after-write) hazard: instruction B
reads register `x5` that instruction A, still in flight, has not yet written.
Without help, B would read the stale value from the register file. Forwarding
"reaches into" the pipeline registers and hands B the value A already
computed.

**The code.** `forward_unit.v:80-95` is the whole logic:

```
mem_writes = FWD_ON && mem_reg_we && (mem_rd != 0)     // forward_unit.v:80
wb_writes  = FWD_ON && wb_reg_we  && (wb_rd  != 0)     // forward_unit.v:81
fwd_a = (mem_writes && mem_rd == ex_rs1) ? 2'b10 :
        (wb_writes  && wb_rd  == ex_rs1) ? 2'b01 : 2'b00   // :84-86
```

`fwd_b` (`forward_unit.v:88-90`) and `fwd_c` (`forward_unit.v:93-95`) repeat
the rule for rs2. Encoding: `10` = take EX/MEM `res`, `01` = take WB data,
`00` = use the ID/EX register value.

**How detection works.** The consumer is the instruction in EX; its source
register numbers are `ex_rs1_addr`/`ex_rs2_addr` (`cpu_top.v:399-400`). The
two possible producers are the instruction in MEM (EX/MEM register outputs
`mem_reg_we`, `mem_rd_addr`, `cpu_top.v:401-402`) and the instruction in WB
(`wbs_reg_we`, `wbs_rd_addr`, `cpu_top.v:403-404`). A match is "producer
writes a register AND that register is the one I read".

**EX/MEM over MEM/WB, and why.** Suppose `x5 = 100`, then `x5 = x5 + 1`, then
a consumer reads `x5`. When the consumer is in EX, the `+1` is in MEM and the
`= 100` is in WB. Both match. The **newer** writer (MEM) holds the value the
program semantics require (101). Checking WB first would resurrect 100. That is
why the ternary chain tests `mem_writes` first (`forward_unit.v:84`) and
`wb_writes` second (`forward_unit.v:85`). Test: `asm/hazard/fwd_ex_ex.s`.

**Why x0 is special.** A producer with `rd = x0` wrote nothing; the register
file suppresses that write (`regfile.v:32`). If the forward unit matched on
`rd == rs == 0`, the consumer would read a non-zero x0 for one instruction. The
`!= 0` test in `forward_unit.v:80-81` blocks it. Because `rd != 0` is required
for any match, it also implies `rs != 0`, so no consumer-side check is needed.
Test: `asm/hazard/x0_hazard.s`.

**Why store data is forwarded (fwd_c).** `sw x6, 0(x7)` reads **two**
registers: x7 for the address (goes through the ALU via `fwd_a`) and x6 for
the data (does not go through the ALU at all). The data path is
`ex_store_data` (`cpu_top.v:420-421`), fed straight into EX/MEM
`store_data_d` (`cpu_top.v:572`) and then `dmem.wdata` (`cpu_top.v:602`).
Without `fwd_c`, `addi x6,x0,5; sw x6,0(x7)` would store the stale x6. Test:
`asm/hazard/store_data_fwd.s`.

**Why `fwd_b` is before the immediate mux.** A branch compares rs1 with rs2
even though the ALU sees an immediate. So `ex_b_val` (`cpu_top.v:417-418`) is
forwarded first, then `alu_b` picks between it and `ex_imm`
(`cpu_top.v:424`), and `branch_unit` reads `ex_b_val` directly
(`cpu_top.v:437`).

**What forwarding cannot do.** A load in MEM has only its *address* in
EX/MEM `res`, not its data. So the `10` path must never fire for a load. It
never does, because the hazard unit (chapter 7) guarantees a load's consumer
does not reach EX until the load is in WB, where `01` delivers real data
(`forward_unit.v:45-50` header).

**FORWARDING = 0.** `FWD_ON` is false so every select is `00`
(`forward_unit.v:77-81`); the hazard unit switches to stall-on-any-RAW. That is
the CPI baseline for the report.

---

## 7. hazard_unit.v — stalls and flushes

**Outputs** (`hazard_unit.v:102-104` header): `stall` holds PC and IF/ID and
bubbles ID/EX; `flush_if` clears IF/ID; `flush_id` clears ID/EX.

### 7.1 Load-use interlock: why exactly one stall

The rule (`hazard_unit.v:110-125`):

```
ex_match        = (id_uses_rs1 && id_rs1 == ex_rd) || (id_uses_rs2 && id_rs2 == ex_rd)  // :110-111
ex_pending_load = ex_valid && ex_mem_re && ex_rd != 0                                    // :116
load_use        = ex_pending_load && ex_match                                            // :121
stall           = id_valid && need_stall && !redirect_ex && !ebreak_pending              // :144
```

**The timing arithmetic.** Let the load be L and the consumer C, back to
back.

```
cycle:      1    2    3    4    5
L:          IF   ID   EX   MEM  WB      data exists at END of MEM (edge 4→5)
C (no stall):    IF   ID   EX           C needs the value at START of cycle 4
```

C's EX would begin at the start of cycle 4, but L's data only appears after
the cycle-4 edge (it is read from block RAM during MEM, `dmem.v:62-68`). One
cycle short. Insert one bubble:

```
C (stalled):     IF   ID   ID   EX      C's EX is now cycle 5; L is in WB
```

In cycle 5 L is in WB, `wb_data` carries the load result (`cpu_top.v:644`),
and `fwd_*` = `01` picks it up (`forward_unit.v:85`). One stall is exactly
enough. Two would waste a cycle; zero would be wrong. The detection happens
while C is in **ID** and L is in **EX** (hence the names `id_*` and `ex_*`),
which is one cycle before the collision would occur.

**Why `id_uses_rs1/rs2` matter.** `lui`, `auipc`, `jal` and `csrr*i` have
bits in the rs1/rs2 field that are really immediate bits. Without the
qualifier they could stall on a phantom dependency. That costs cycles, not
correctness, but the counters measure CPI so phantom stalls are unacceptable
(`hazard_unit.v:27-32`, `cpu_top.v:261-266`).

**Why `rd != 0`.** `lw x0, 0(x1)` writes nothing, so nobody depends on it
(`hazard_unit.v:116`).

**FORWARDING = 0 path.** `raw_any` (`hazard_unit.v:122-123`) stalls while a
pending writer of a source register is in EX or MEM. A producer in EX costs two
stalls, in MEM one, in WB zero (regfile bypass). Loads need no special case
here because the general rule already holds until the load reaches WB
(`hazard_unit.v:34-47`).

### 7.2 Flushes: jal = 1 bubble, branch/jalr/trap/mret = 2 bubbles

```
flush_if = redirect_ex || redirect_id || ebreak_pending    // hazard_unit.v:147
flush_id = redirect_ex || ebreak_pending                   // hazard_unit.v:148
```

**Count the wrong-path instructions.** When a control-flow instruction
resolves in stage S, every younger instruction already fetched is on the wrong
path and must die.

- `jal` resolves in **ID** (`cpu_top.v:285-289`, `control.v:248`). Only the
  slot behind it (IF) is wrong. Kill IF/ID → `flush_if`. The jal itself must
  continue into EX to produce its link value, so `flush_id` stays 0. **Cost:
  1 bubble.**
- Taken/mispredicted branch, `jalr`, `ecall` trap, `mret` resolve in **EX**
  (`cpu_top.v:500`). Two slots behind it (ID and IF) are wrong. Kill both →
  `flush_if` and `flush_id`. **Cost: 2 bubbles.**

Why can jal resolve in ID but not branch/jalr? jal's target is PC + J-imm,
both known in ID. A branch needs the register **compare** (needs forwarded
operands, only available in EX). jalr needs `rs1 + imm`, also a register
value. So they wait for EX. This is the corrected rule from
`PROJECT-REQUIREMENTS.md` (branches + jalr in EX, jal in ID).

**Redirect beats stall.** The `!redirect_ex` in `hazard_unit.v:144` and the
`redirect | ~stall` in `cpu_top.v:123` say the same thing twice: an
instruction being flushed has no business stalling. Note the deliberate
asymmetry: `redirect_id` is **not** in the stall term, because a jal is raised
*by* the ID instruction; instead `cpu_top.v:289-290` gate `jal_taken` and
`bht_taken` with `~stall`. The header at `hazard_unit.v:129-143` explains that
putting it in both places would create a combinational loop.

**ebreak shadow.** `ebreak_pending` (`cpu_top.v:514-516`) holds IF/ID and
ID/EX empty from the moment an `ebreak` reaches EX until the sticky `done`
freezes everything three cycles later, so no younger instruction can commit
behind the halt.

---

## 8. csr.v — control and status registers, traps, mret

**What a CSR is.** A CSR is a special machine register accessed by its own
instructions (`csrrw`, `csrrs`, `csrrc` and immediate forms). This design
implements five: `mstatus` (MIE bit 3, MPIE bit 7), `mie` (MEIE bit 11),
`mtvec` (trap vector), `mepc` (return address), `mcause` (`csr.v:12-19`).
Everything else reads 0 and ignores writes (`csr.v:112`, `csr.v:163`).

### 8.1 Single-cycle read-modify-write in EX, so no interlock

The read side assembles the architectural view combinationally
(`csr.v:105-116`). The write value is computed from that *pre-write* view
(`csr.v:120-127`: RW = src, RS = old | src, RC = old & ~src) and committed on
the clock edge (`csr.v:153-165`). Read and write happen in the same cycle,
in the same stage.

**Why no CSR interlock is needed.** A younger CSR instruction reaches EX one
cycle later. By then the older one's write has already landed. So
`csrw mepc, t0` immediately followed by `mret` just works: `mepc` is written
at the end of the `csrw`'s EX cycle, and `mret` reads `mepc_o` (`csr.v:101`)
in its own EX cycle, the next one (`csr.v:5-10`, `docs/DESIGN.md` §6.4).
There is no "CSR drain" and no special stall. This is the **CSR drain myth**
question in chapter 13.

What *does* need forwarding is the register side: the write source `rs1` goes
through `fwd_a` (`cpu_top.v:444` uses `ex_a_val`), and the old CSR value
returns through `ex_res` (`cpu_top.v:545`) so a consumer of `csrrw`'s `rd`
forwards the CSR value. Test: `asm/hazard/csr_hazard.s`.

### 8.2 mepc rules: ecall +4, interrupt not

Trap entry (`csr.v:145-149`): `mepc ← trap_pc`, `mcause ← cause`, `MPIE ←
MIE`, `MIE ← 0`. `cpu_top.v:456-458` feeds `trap_pc = ex_pc`, the PC of the
instruction in EX. The PC mux then jumps to `mtvec` (`cpu_top.v:531`).

- **`ecall`** is synchronous: the instruction *itself* is the trap. `mepc`
  points AT the ecall. The handler must do `mepc += 4` before `mret`, or the
  ecall re-executes forever (`csr.v:35-37`).
- **External interrupt**: the instruction in EX is an innocent bystander. It
  is squashed (`flush_ex`, `cpu_top.v:553`) and never retires. `mepc` points AT
  it so `mret` re-executes it. The handler must **not** add 4 (`csr.v:37-38`,
  `csr.v:42-49`).

The asymmetry is in the software, not the hardware: the hardware always
stores the PC of the EX instruction. Only the handler knows, from `mcause`
bit 31, whether that instruction ran or not.

**Interrupt qualification** is inside `csr.v:130`:
`irq_pending = irq & mstatus_mie & mie_meie`. A program that never enables
interrupts is unaffected by `irq`, cycle for cycle. `cpu_top.v:484` adds
`ex_valid` (mepc must be a real PC, never a bubble's 0) and `cpu_top.v:485`
makes interrupt outrank ecall in the same slot.

**mret** (`csr.v:150-152`): `MIE ← MPIE`, `MPIE ← 1`, and the PC mux takes
`mepc` (`cpu_top.v:532`). Write priority is trap > mret > CSR instruction
(`csr.v:133-136`).

**mtvec direct mode.** Low two bits forced to 00 (`csr.v:109`, `csr.v:160`).
Vectored mode is not implemented.

---

## 9. bht.v — branch history table

**What it is.** A 64-entry table of 2-bit **saturating counters**, indexed
by `pc[7:2]` (`bht.v:70-72`). It predicts *direction* only. There is no
branch target buffer because the target of a conditional branch is PC + B-imm,
which ID computes anyway (`bht.v:3-9`).

**The 2-bit counter** (`bht.v:16-32` header, `bht.v:86-92` update):

```
00 strongly not-taken ← 01 weakly not-taken ← 10 weakly taken ← 11 strongly taken
prediction = state[1]                                   // bht.v:80
taken:     state = min(state + 1, 11)                   // bht.v:89
not taken: state = max(state - 1, 00)                   // bht.v:91
```

Two bits give **hysteresis**: one surprise (e.g. a loop exit) does not flip a
strongly-taken prediction. Reset puts every entry at 01 (`bht.v:97-98`), so
an unvisited branch behaves like the no-predictor machine and a loop back-edge
becomes "taken" after a single observation.

**Lookup in IF, act in ID = 1 bubble.** The counter is read combinationally
in IF with `pc_q` (`cpu_top.v:148`, `bht.v:77-79`) and registered into IF/ID
(`cpu_top.v:170`, `if_id.v:52`). In ID, if the instruction is a branch and
`pred_state[1]` is set, `id_pred_taken` is 1 (`cpu_top.v:287`) and
`bht_taken` redirects to `if_id_pc + id_imm` (`cpu_top.v:290`,
`cpu_top.v:536`). Only the IF slot is wrong, so `flush_if` alone fires,
exactly like `jal`: **1 bubble** instead of the 2 an EX-resolved taken branch
costs. A correct not-taken prediction costs 0.

**Update in EX.** `bht_update_en = ex_branch_valid & ~halt`
(`cpu_top.v:507`) with `update_pc = ex_pc` and `update_taken = branch_cond`
(`cpu_top.v:152-153`, `bht.v:99-100`). Mispredict detection is
`ex_pred_taken != branch_cond` (`cpu_top.v:498`), and a mispredict costs 2
bubbles either direction (`cpu_top.v:526-527` chooses target or PC+4).

**Why BHT_ENABLE = 0 reproduces the base machine exactly.** With `ENABLE = 0`:
`pred_state` is constant `01` and `pred_taken` is constant 0 (`bht.v:79-80`),
and no counter is ever written (`bht.v:99`). Therefore `id_pred_taken` is
always 0 (`cpu_top.v:287`), `bht_taken` never fires, `ex_pred_taken` is always
0, and `br_redirect` degenerates to `ex_branch_valid & branch_cond`, which is
"redirect whenever taken" (`cpu_top.v:493-498`). That is the static
not-taken machine, cycle for cycle. `docs/DESIGN.md` §11.3 confirms the
BHT-off cycle counts equal the §11.2 fwd=1 column. With the outputs constant,
synthesis prunes the array away (`bht.v:42-45`).

**The predictor cannot break correctness.** It only changes *when* a
redirect happens; the EX resolution and flush still catch every wrong
prediction. That is why all four (FORWARDING, BHT) configurations pass the
same byte-exact trace diff.

**Cost.** Each mispredict = 2 bubbles. `bloop` in `docs/DESIGN.md` §11.3 is
the adversarial case: its `beq` alternates every iteration, a pattern a 2-bit
counter cannot learn, so BHT-on is 400 cycles *slower* there. `bpred` is the
showcase: −14.5 % cycles.

---

## 10. cpu_top.v — the wiring hub

`cpu_top.v` instantiates every module and owns all the muxes. The four famous
locations:

**PC redirect (lines 287–291 and 530–538).**

```
id_pred_taken = if_id_valid & id_branch & if_id_pred_state[1]    // :287
jal_taken     = if_id_valid & id_jal & ~stall & ~ebreak_pending   // :289
bht_taken     = id_pred_taken        & ~stall & ~ebreak_pending   // :290
redirect_id   = jal_taken | bht_taken                              // :291
```

Then the priority mux (`cpu_top.v:530-538`): `trap_taken → mtvec`,
`mret_taken → mepc`, `br_redirect → ex_correct_target`, `jalr_taken →
ex_jalr_target`, `jal_taken → id_redirect_target`, `bht_taken →
id_redirect_target`, else `pc_q + 4`. EX events outrank ID events because the
EX instruction is older; if both fire in one cycle the ID one is being flushed
anyway.

**Forwarding sources (line 413) and muxes (415–421).**
`fwd_src_mem = mem_res` (`:412`), `fwd_src_wb = wb_data` (`:413`). Note
`wb_data` is the *post-WB-mux* value, so a load's data is forwarded, not its
address. The three muxes at `:415-421` select `10` → MEM, `01` → WB, else
ID/EX.

**CSR block (442–464).** `csr_wsrc` chooses zimm or the forwarded rs1
(`:444`). `csr_we` is masked with `~trap_taken & ~halt` (`:451`) so a CSR
instruction squashed by an interrupt writes nothing. `trap` and `mret` are
likewise masked (`:456`, `:459`). `mtvec_val` and `mepc_val` come out for the
PC mux (`:460-461`).

**Write-back mux (line 644).**
`wb_data = (wbs_wb_sel == WB_MEM) ? dmem_rdata : wbs_res`. Everything that is
not a load was already selected in EX (`:541-548`).

**Enable and flush plumbing.** Every pipeline register gets `stall = halt`
and a flush term: IF/ID `flush_if & ~halt` (`:167`), ID/EX
`~halt & (stall | flush_id)` (`:315`, a stall bubbles ID/EX), EX/MEM
`flush_ex` (`:562`), MEM/WB never flushes (`:614`).

---

## 11. Verification philosophy

**Principle: never trust the RTL to check itself.** Three layers, each
self-checking, each printing exactly one `PASS`/`FAIL` line and exiting
nonzero on failure (`sim/run.ps1` header: exit 0 iff a PASS line and no FAIL
line).

1. **Toolchain first.** `tools/asm.py` (assembler) and `tools/iss.py`
   (instruction-set simulator, the golden model) were cross-validated against
   each other before any RTL existed: `python tools/test_tools.py` runs 4300+
   checks.
2. **Unit testbenches** for every leaf module (`tb/tb_alu.v`, `tb_imm_gen.v`,
   `tb_regfile.v`, `tb_control.v`, `tb_bht.v`, `tb_irq.v`, …). The control
   truth table is generated from one Python dict into both `docs/DESIGN.md`
   §3 and `tb/vectors/control_vectors.hex`, so the report and the test cannot
   drift (`tools/gen_control_table.py`).
3. **Golden-ISS diffing** at program level. `tb/tb_program.v` loads a `.hex`,
   runs to `ebreak`, writes the WB commit trace (`cpu_top.v:666-674`) in the
   ISS's exact format, then compares (a) all 32 registers to `<prog>.regs` and
   (b) the trace line-by-line to `<prog>.trace` (`tb/tb_program.v:3-13`).
   A single differing line is a FAIL.

**Program suites.** `asm/insn/` (46 per-instruction programs), `asm/hazard/`
(9 directed hazard programs, each named for the rule it attacks:
`fwd_ex_ex`, `fwd_mem_ex`, `fwd_wb_id`, `load_use`, `store_data_fwd`,
`x0_hazard`, `branch_flush`, `csr_hazard`, `mixed`), `asm/prog/` (fib, bsort,
bloop, bpred, irq_demo), `tb/bringup/` (7 smoke programs).

**The 2 × 2 configuration sweep.** Because `FORWARDING` and `BHT_ENABLE`
are parameters (`cpu_top.v:50-51`, `tb/tb_program.v:40-41`), the same
programs run under all four machines. The trace must be identical in all four;
only the PERF line (cycles) may differ.

| | BHT = 1 | BHT = 0 |
|---|---|---|
| FWD = 1 | full machine | base machine + forwarding |
| FWD = 0 | predictor, stall-only | stall-only baseline |

**Commands** (run from the repo root, Git Bash or PowerShell):

```
# toolchain self-check, no RTL
python tools/test_tools.py

# one unit testbench (PowerShell or bash form)
powershell -ExecutionPolicy Bypass -File sim/run.ps1 tb_imm_gen
bash sim/run.sh tb_alu

# program suites, default FWD=1 BHT=1
python tools/run_tests.py --dir asm/insn --dir asm/hazard
python tools/run_tests.py --dir asm/prog

# the sweep
python tools/run_tests.py --dir asm/prog --fwd 1 --bht 1
python tools/run_tests.py --dir asm/prog --fwd 1 --bht 0
python tools/run_tests.py --dir asm/prog --fwd 0 --bht 1
python tools/run_tests.py --dir asm/prog --fwd 0 --bht 0

# interrupts at cycles 200 and 500 (trace re-aligned against iss.py --irq-after)
python tools/run_tests.py --dir asm/prog --irq-at 200,500

# waveform for one program
powershell -File sim/run.ps1 tb_program --plusarg +PROG=asm/prog/fib --wave
```

`run_tests.py` elaborates once per (FWD, BHT) pair and reuses the snapshot
across programs, which cut the 46-program suite from 347 s to 144 s
(`tools/README.md`). Results: `docs/DESIGN.md` §10.10 reports 46/46, 9/9,
5/5 and 7/7 with BHT on and off.

**Interrupt alignment.** The ISS traps after N retired instructions; the RTL
traps at a cycle. `run_tests.py --irq-at` runs the RTL first, reads the
`IRQ_TAKEN retire_index=N` it prints, re-runs `iss.py --irq-after N`, and
diffs (`tools/README.md`). For `irq_demo` that gave 0 differing lines over 633
(`docs/DESIGN.md` §11.4).

---

## 12. Synthesis results

Target: Artix-7 `xc7a35tcpg236-1`, Vivado 2026.1, out-of-context,
post-place-and-route. Reports in `vivado/reports/`; the numbers below are read
from `docs/DESIGN.md` §11.5.

| Design | Period | LUT | FF | BRAM | WNS | fmax |
|---|---|---|---|---|---|---|
| Base (BHT=0) | 10.0 ns | 1245 | 689 | 2 | −2.483 ns | 80.1 MHz |
| Full | 10.0 ns | 1461 | 819 | 2 | −3.235 ns | 75.6 MHz |
| Full | 12.5 ns | 1455 | 819 | 2 | −0.755 ns | 75.4 MHz |
| **Full** | **13.5 ns** | 1424 | 819 | 2 | **+0.052 ns** | **74.4 MHz, met** |

**Headline: 74 MHz with setup met** (`vivado/reports/timing_13.5ns.txt`,
zero failing endpoints). 100 MHz was the target and is not met. The three
runs agree to within 1.2 %, which shows fmax is a property of the design, not
of the constraint. 74 MHz is quoted rather than 75.6 because it is the one a
run actually demonstrated by closing.

**The critical path: load-to-branch.** From `u_dmem/mem_reg` clock to
`u_pc/pc_q_reg/CE`, 12.982 ns, 15 logic levels, 65 % routing:

1. DMEM block-RAM clock-to-output, 2.454 ns, the single largest term
   (`dmem.v:62-68` is the registered read that maps to the BRAM).
2. Byte-lane select and sign/zero extension of the load result
   (`dmem.v:74-95`). Because the word is registered at MEM and extended
   combinationally, this logic executes in the **WB** cycle.
3. The MEM/WB → EX forwarding mux (`cpu_top.v:413`, `cpu_top.v:415-418`).
   EX/MEM cannot serve a load (it holds the address), so a load feeding a
   branch must come through this path.
4. The branch comparator carry chain producing `branch_cond`
   (`branch_unit.v:15-25`).
5. The redirect/flush/stall reduction (`cpu_top.v:498-501`,
   `hazard_unit.v:144-148`).
6. Into the PC register's clock enable (`cpu_top.v:123`).

In words: a load's data comes out of block RAM, gets extended, is forwarded
into a dependent branch, the branch decides, and that decision gates the PC,
all in one cycle. The base-machine number is higher only because the BHT
compare (`cpu_top.v:498`) is absent from the reduction.

**Why the hold violations are not real.** WHS = −0.120 ns on 483 endpoints,
identical at every period. All twenty worst hold paths in `hold.txt` start at
the `rst` input port (fanout 485). `hold_reg2reg.txt` restricts the analysis
to register-to-register paths and is **met** (+0.071 ns full at 10 ns, +0.112
at 13.5 ns, +0.119 base). Out-of-context synthesis has no BUFG, so Vivado
routes the clock to the registers through 0.973 ns of general fabric while
`rst` is declared to arrive at 0 ns (`vivado/constraints.xdc`, input delay
0). The tool therefore sees data "early" relative to a clock a real global
buffer would have delayed identically at both ends. Vivado's own messages say
so (`Timing 38-242` HD.CLK_SRC not set, `Route 35-198` no PARTPIN_LOCS). In a
board-level design with the clock on a BUFG the check disappears.

**Why out-of-context.** `cpu_top` has 363 ports, 361 of them trace/perf
observation bits (`constraints.xdc` header). The package has 106 pins. Trace
and perf ports are declared false paths with a 0 ns output delay so
`check_timing` is clean and they cannot distort the critical path.

**Memory inference.** IMEM → 1 RAMB36E1, DMEM → 1 RAMB36E1, regfile → 12
RAM32M (44 LUTs). This needed explicit `ram_style` attributes (`imem.v:20`,
`dmem.v:21`, `regfile.v:20`); without them Vivado constant-folded IMEM away and
put the regfile in the only block RAM. The earlier "88 MHz" figure came from
that broken netlist and is recorded as superseded in `docs/DESIGN.md` §11.5.

**Two planned timing fixes** (not implemented, feature freeze):

1. **Register the DMEM lane extension into WB.** Move `dmem.v:74-95` behind
   the MEM/WB register so steps 2–3 leave the same cycle as the 2.454 ns BRAM
   read. This reshapes the load-use interlock (the data arrives one stage
   later), so it is a datapath change.
2. **Pipeline the forwarding compare.** Precompute the `rs == rd` match bits
   in ID, where the register numbers are available a cycle early, instead of
   comparing in EX (`forward_unit.v:84-95`).

A third option, letting the BRAMs absorb an output register (Vivado
`Synth 8-7052`), would cut step 1 to ~0.4 ns at the cost of one extra memory
latency cycle, i.e. a pipeline-depth change.

---

## 13. Likely examiner questions and strong answers

**Q1. "You have a CSR write immediately followed by `mret`. Don't you need
to drain the pipeline or stall?"**
No. `csr.v` does its read-modify-write in a single cycle in EX: the read
value is the pre-write value (`csr.v:105-116`) and the new value commits on
the same edge (`csr.v:153-165`). The `mret` reaches EX one cycle later and
reads `mepc_o` (`csr.v:101`) after the write has landed. No interlock, no
drain (`csr.v:5-10`, `docs/DESIGN.md` §6.4). The only forwarding a CSR
instruction needs is on its `rs1` source, and that goes through the ordinary
`fwd_a` mux (`cpu_top.v:444`). `asm/hazard/csr_hazard.s` exercises it.

**Q2. "Why does the ecall handler add 4 to mepc but the interrupt handler
must not?"**
The hardware is symmetric: `mepc ← PC of the instruction in EX`
(`csr.v:146`, `cpu_top.v:457`). The difference is what that instruction *was*.
For `ecall` it is the ecall itself, which has now been handled, so returning
to it would re-trap forever; add 4. For an interrupt it is an innocent
instruction that was squashed and never executed (`cpu_top.v:553`,
`docs/DESIGN.md` §8.2), so it must run after `mret`; do not add 4. The
handler tells the cases apart by `mcause` bit 31 (`cpu_top.v:93-94`).

**Q3. "What does the branch predictor cost, and when does it lose?"**
Hardware: 64 × 2-bit counters (`bht.v:67-70`) plus one 2-bit field in IF/ID
(`if_id.v:52`) and one bit in ID/EX (`id_ex.v:48`); 1461 vs 1245 LUTs full
vs base. Time: a correct taken prediction costs 1 bubble instead of 2; a
correct not-taken prediction costs 0; any mispredict costs 2
(`docs/DESIGN.md` §11.1). It loses on alternating branches, which a 2-bit
counter cannot learn: `bloop` is +400 cycles with BHT on, exactly
446 misses × 2 − 246 taken × 2 (`docs/DESIGN.md` §11.3). It wins big on loop
back-edges: `bpred` −14.5 %.

**Q4. "Two older instructions both write x5. Which one do you forward
from?"**
The one in MEM, i.e. EX/MEM, because it is the newer writer. The ternary
chain at `forward_unit.v:84-86` tests `mem_writes` before `wb_writes`. If
MEM/WB were checked first, `x5 = 100; x5 = x5 + 1; use x5` would read 100
instead of 101. `asm/hazard/fwd_ex_ex.s` ends with exactly that sequence.

**Q5. "Why does a load-use hazard need exactly one stall, not two?"**
The consumer is detected in ID while the load is in EX
(`hazard_unit.v:110-121`). The load's data appears at the end of its MEM
cycle (`dmem.v:62-68`). Without a stall the consumer's EX would start at the
same time the load's MEM starts, one cycle too early. After one bubble the
load is in WB, its data is on `wb_data` (`cpu_top.v:644`), and the MEM/WB
bypass delivers it (`forward_unit.v:85`, `cpu_top.v:416`). See the timing
diagram in chapter 7.1.

**Q6. "Prove that BHT_ENABLE = 0 is really the base machine and not just
'similar'."**
With `ENABLE = 0`, `pred_taken` is constant 0 and `pred_state` constant 01
(`bht.v:79-80`), and the counter array is never written (`bht.v:99`). So
`id_pred_taken` (`cpu_top.v:287`) is always 0, `bht_taken` never fires, and
`br_redirect` (`cpu_top.v:498`) reduces to `ex_branch_valid & branch_cond`,
which is the static not-taken rule. Every BHT-related path is then constant
and synthesis removes it. Empirically, the BHT-off cycle counts in
`docs/DESIGN.md` §11.3 equal the fwd=1 column of §11.2 exactly.

**Q7. "Why did you miss 100 MHz, and what would you do about it?"**
The critical path is load-to-branch: 2.454 ns of block-RAM clock-to-out
(`dmem.v:62-68`), then lane extension (`dmem.v:74-95`), then the MEM/WB→EX
forward mux (`cpu_top.v:413-418`), then the branch compare
(`branch_unit.v:15-25`), then the redirect/stall reduction into the PC
enable (`cpu_top.v:123`), 12.98 ns in total. Setup closes at 13.5 ns = 74 MHz.
Fix 1: register the lane extension into WB so it leaves the BRAM's cycle.
Fix 2: precompute the forwarding `rs == rd` matches in ID. Both are datapath
changes with no architectural effect, deferred under the feature freeze.

**Q8. "Your hold report shows 483 violations. Isn't that a broken
design?"**
No. Every failing hold path starts at the `rst` port; register-to-register
hold is met at +0.071 ns and better (`vivado/reports/hold_reg2reg*.txt`). It
is an out-of-context artifact: no BUFG, so the clock reaches the flops
0.973 ns late through fabric while `rst` is modelled at 0 ns input delay.
Vivado warns about this itself (`Timing 38-242`, `Route 35-198`). It is
period-independent, which is the giveaway that it is not a logic problem.

**Q9. "Why do you forward store data separately? Isn't rs2 already
forwarded for the ALU?"**
The ALU's B input goes through the immediate mux (`cpu_top.v:424`): for a
store, `alu_b` is the offset, so the forwarded `ex_b_val` is not what reaches
memory. The store data has its own path, `ex_store_data`
(`cpu_top.v:420-421`) → EX/MEM `store_data` (`cpu_top.v:572`) → `dmem.wdata`
(`cpu_top.v:602`). `fwd_c` (`forward_unit.v:93-95`) applies the same rule to
that path. Without it, `addi x6,x0,5; sw x6,0(x7)` stores a stale value.
`asm/hazard/store_data_fwd.s` checks it.

**Q10. "How do you know the RTL is correct and not just 'passes your own
tests'?"**
The reference is independent: `tools/iss.py` is a Python instruction-set
simulator written and cross-validated against the assembler before any RTL
(`tools/test_tools.py`, 4300+ checks). Every program-level test diffs the
RTL's WB commit trace (`cpu_top.v:666-674`) line by line against the ISS
trace and checks all 32 registers (`tb/tb_program.v:3-13`). The same programs
run under all four (FORWARDING, BHT) configurations and must produce
identical traces; only cycle counts may change. Directed hazard programs
target each rule by name, and the decode truth table is generated from one
source into both the report and the test vectors. Results are 46/46, 9/9,
5/5, 7/7 (`docs/DESIGN.md` §10.10).

---

## Appendix: file map

| File | Stage | One-liner |
|---|---|---|
| `rtl/pc.v` | IF | PC register with enable |
| `rtl/imem.v` | IF | 4 KB sync-read ROM, `$readmemh` |
| `rtl/bht.v` | IF/EX | 64 × 2-bit direction predictor |
| `rtl/if_id.v` | IF→ID | pc, valid, pred_state |
| `rtl/control.v` | ID | main decoder, 46 encodings |
| `rtl/alu_ctrl.v` | ID | funct3/inst[30] → ALU op |
| `rtl/imm_gen.v` | ID | I/S/B/U/J/Z immediates |
| `rtl/regfile.v` | ID/WB | 32 × 32, async read, WB→ID bypass |
| `rtl/id_ex.v` | ID→EX | full control word + operands |
| `rtl/forward_unit.v` | EX | fwd_a / fwd_b / fwd_c |
| `rtl/hazard_unit.v` | ID | stall, flush_if, flush_id |
| `rtl/alu.v` | EX | 11 ops |
| `rtl/branch_unit.v` | EX | 6 compares |
| `rtl/csr.v` | EX | 5 CSRs, trap, mret, irq qualification |
| `rtl/ex_mem.v` | EX→MEM | res, store_data, rd |
| `rtl/dmem.v` | MEM/WB | 4 KB byte-lane RAM, extension in WB |
| `rtl/mem_wb.v` | MEM→WB | res, rd, trace fields |
| `rtl/perf_counters.v` | WB | 6 counters |
| `rtl/cpu_top.v` | all | the wiring hub |
