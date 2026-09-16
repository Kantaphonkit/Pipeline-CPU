# Pipeline CPU Project — Project Proposal

**Course:** Computer Organization
**Project:** RISC-V RV32I 5-Stage Pipelined CPU in Verilog
**Team:** 杨辉宗 1820232064 (Design), 吴宏庆 1820232044 (Coding), 王伟成 1820232061 (Testing)

> **How to read this document.** This is a proposal, and it is backed by a working
> prototype. Sections 1 to 5 state what we propose to build and why we chose it.
> Sections 6 and 7 are feasibility evidence: measurements taken from a prototype that
> already runs, presented to show that the proposal is achievable rather than to claim
> the work is finished. Sections 8 to 10 state who delivers what, by when, and what we
> do if a risk lands.

---

## 1. Objective and success criteria

### 1.1 The task

The course task is to design a pipelined CPU supporting an instruction subset of more
than 16 instructions, implement it in Verilog HDL, and use simulation tools to
demonstrate both the function and the performance of the CPU. Bonus items are offered
for interrupt support, cache, and branch prediction.

### 1.2 What we propose to deliver

We propose a RISC-V RV32I subset: a classic 5-stage in-order pipeline (IF, ID, EX, MEM,
WB) with full data-hazard forwarding, a load-use interlock, EX-stage branch resolution,
and a flush-based recovery for control hazards. The design supports 46 instruction
encodings (37 core RV32I instructions plus 9 system encodings: CSR operations,
ecall/ebreak, mret), well above the 16-instruction minimum.

| Deliverable | Commitment |
|---|---|
| Machine | A 5-stage in-order RV32I pipeline, 46 encodings, full forwarding, a load-use interlock and flush-based control recovery |
| Bonus ×2 | A 2-bit branch predictor and machine-mode interrupts, each built so it can be switched off, because a feature that cannot be disabled cannot be measured |
| Toolchain | An assembler and an independent reference model, because the tool named in the brief cannot execute this instruction set |
| Evidence | A self-checking test suite, a design document, and a synthesis report for `xc7a35tcpg236-1` |

### 1.3 Success criteria — how we will know it is done

These four criteria are the acceptance test for the proposal. Every later section is
written to answer one of them.

| # | Criterion | What satisfies it |
|---|---|---|
| 1 | **Correct** | Every instruction checked against an independent implementation, byte for byte, rather than against our own expectations |
| 2 | **Function** | Shown in simulation, with every test stating its own PASS or FAIL verdict and a nonzero exit on failure |
| 3 | **Performance** | Measured by switching a feature off and re-running the same programs. A number with no baseline proves nothing |
| 4 | **Synthesis** | An fmax and a utilisation figure on a named part, with the critical path identified |

### 1.4 Explicitly out of scope

- **No FPGA board bring-up.** The task asks for simulation tools, so we deliver
  simulation plus a synthesis report on a named part.
- **No instruction cache.** The reasoning is in section 2, and it is a measurement
  argument rather than a schedule one.

### 1.5 Design decisions summary

| Property | Decision |
|---|---|
| ISA | RISC-V RV32I user subset + simplified machine-mode CSRs (46 encodings) |
| Pipeline | 5 stages, in-order issue, in-order completion |
| Data hazards | Full EX/MEM and MEM/WB forwarding with a compile-time shutoff for the performance comparison; 1-cycle load-use interlock |
| Control flow | jal resolved in ID (1 bubble); conditional branches and jalr resolved in EX (2 bubbles) |
| Bonus scope | Branch prediction (64-entry 2-bit BHT) and interrupts (CSRs + mret) proposed for implementation; I-cache designed but deliberately not implemented (section 5.3) |
| Memory | Harvard architecture: 4 KB IMEM + 4 KB DMEM, single-cycle synchronous, `$readmemh` initialised |
| Toolchain | Vivado 2026.1 (xvlog/xelab/xsim batch flow) with a self-written Python assembler and Python golden-model ISS (Mars4_5 is MIPS-only and cannot verify RISC-V) |
| Target | Simulation plus synthesis report (`xc7a35tcpg236-1`); no FPGA board demo |

---

## 2. Design choices and what was ruled out

Each row below is a decision we took, the alternative we rejected, and the reason. The
instruction-cache row is the one we would most like to be judged on, because cutting a
bonus item is a decision that has to be defended rather than assumed.

| Decision | We chose | Instead of | Why |
|---|---|---|---|
| ISA | RISC-V RV32I, 46 encodings | MIPS | A clean orthogonal encoding we could write our own assembler and reference model for, and 2.9× the 16-instruction minimum |
| Pipeline | 5-stage in-order | Single-cycle, or a deeper pipeline | The shallowest design that still exposes all three hazard classes, which is the point of the exercise. A deeper pipe would add hazard distance without adding anything new to demonstrate |
| Branch resolution | `jal` in ID, branches and `jalr` in EX | Resolving everything in one stage | `jal` needs no register value, so resolving it early is free and costs 1 bubble instead of 2. A branch needs a comparison, and performing it in EX keeps the comparator off the decode path |
| Bonus A | 2-bit branch history table | Static prediction only | Cheap in area, and its accuracy is a number we can report honestly — including the workload where it loses |
| Bonus B | CSRs, traps and `mret` | — | Exercises privileged state and trap semantics, and is demonstrable from a testbench-driven interrupt line without external hardware |
| **Bonus C** | **Instruction cache — CUT** | **Building it anyway** | **Behind a single-cycle memory a hit and a miss cost the same, so CPI would not move at all. The whole test suite fits in 2 KB, so the hit rate would read ~99 % on every program. Designed and written up, deliberately not built** |
| Reference model | Our own Python ISS | Mars4_5, as the brief names | Mars executes MIPS. It cannot assemble or check RISC-V, so there was no oracle available to borrow |
| Target | Simulation + synthesis report | FPGA board demo | The brief asks for simulation. Synthesis still yields fmax and utilisation without board bring-up risk |

The cache decision is worth restating plainly: **a figure that reads 99 % on every
program says nothing about the design.** Section 5.3 documents the cache that was
designed, so the analysis is delivered even though the hardware is not.

---

## 3. Proposed design — microarchitecture

The datapath is a textbook 5-stage RISC-V pipeline. Each stage is separated by a
pipeline register (IF/ID, ID/EX, EX/MEM, MEM/WB); the register file is written in WB and
read in ID with an internal write-through bypass so that a result written and re-read in
the same cycle is seen immediately. The PC select mux chooses between PC+4, the ID-stage
jal target, the EX-stage branch/jalr target, the trap vector mtvec, and mepc on mret.

Every stage boundary is an explicit register carrying a stall input and a flush input,
which is what allows the hazard logic of section 4 to be added without modifying the
datapath.

### 3.1 Pipeline stages

| Stage | Function |
|---|---|
| IF | Instruction fetch from IMEM; BHT lookup indexed by the fetch PC, with the 2-bit counter state carried into IF/ID alongside the instruction; PC register holds the selected next PC |
| ID | Decode; immediate generation (6 formats incl. CSR zimm); register read; jal resolved here (target computable in ID); a branch the carried BHT state predicts taken is redirected here too, on the same 1-bubble path; hazard detection for the load-use interlock |
| EX | ALU; branch condition evaluation and target computation (branches + jalr resolved here, 2-bubble flush); CSR address and data routing; forwarding muxes for both ALU operands and store data |
| MEM | Data memory access: loads, stores; the BRAM word is registered on the MEM edge (byte/halfword lane select and sign/zero extension happen in WB) |
| WB | Register file write-back, selecting among ALU result, memory data, PC+4 (jal/jalr), and CSR read data |

### 3.2 Instruction set proposed (46 encodings)

| Group | Count | Instructions |
|---|---|---|
| R-type | 10 | add, sub, sll, slt, sltu, xor, srl, sra, or, and |
| I-arith | 9 | addi, slti, sltiu, xori, ori, andi, slli, srli, srai |
| Loads | 5 | lb, lh, lw, lbu, lhu |
| Stores | 3 | sb, sh, sw |
| Branches | 6 | beq, bne, blt, bge, bltu, bgeu |
| U-type | 2 | lui, auipc |
| Jumps | 2 | jal, jalr |
| System | 9 | ecall, ebreak, csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, mret |

Encodings follow the RISC-V Unprivileged and Privileged ISA specifications exactly.
`ebreak` doubles as the testbench halt signal (it sets a done flag the testbench watches,
since RV32I has no halt instruction). `fence` and `wfi` are not supported and decode as
illegal.

---

## 4. Proposed design — hazard scheme

### 4.1 Data hazards and forwarding

The forwarding unit compares the source registers of the instruction in EX against the
destination registers travelling in EX/MEM and MEM/WB. EX/MEM forwarding has priority
over MEM/WB; MEM/WB forwards only when EX/MEM does not match. Both units suppress x0
(the forwarding unit never forwards from x0, and the register file never writes it).
Store instructions get their rs2 data forwarded through the EX-stage store-data path as
well. A compile-time parameter `FORWARDING` allows the entire bypass network to be
disabled, producing a stall-only machine used as the baseline in the performance
comparison.

The priority rule is load-bearing: when both older instructions write the same
architectural register, the one in MEM is the newer writer, and testing MEM/WB first
would resurrect a stale value.

### 4.2 Load-use interlock

When the instruction in EX is a load and the instruction in ID consumes its destination
register, the hazard unit freezes PC and IF/ID for one cycle and injects a bubble into
ID/EX. The load result is then delivered by the MEM/WB forwarding path.

### 4.3 Control hazards

`jal` is resolved in ID (1 bubble) because its target is computable at decode.
Conditional branches and `jalr` resolve in EX: a taken branch or `jalr` squashes the two
younger instructions in IF and ID (2 bubbles). Traps (`ecall` and external interrupts)
and `mret` use the same 2-bubble flush machinery. Flushes of wrong-path instructions are
architectural no-ops: they never write the register file or memory and are never counted
as retired instructions.

A redirect always overrides a stall, because the instruction that raised the stall is
being killed anyway and waiting for it would deadlock the redirect.

### 4.4 CSR hazards

CSR instructions perform their read-modify-write in the EX stage in a single cycle: the
value written to rd is the old CSR value, and the new value is committed on the same
clock edge. An instruction one slot behind reaches EX a cycle later and already sees the
updated register, so no CSR interlock is needed; `csrw mepc` immediately followed by
`mret` works for the same reason. The register-side source (rs1) reaches the CSR through
the normal EX forwarding path, and the CSR read value is selected in EX so that a later
consumer of rd forwards the CSR value rather than an unused ALU result.

Trap return follows the two RISC-V cases. For a synchronous trap (`ecall`) mepc holds
the address of the `ecall` itself, so the handler must add 4 to mepc before `mret` or the
`ecall` re-executes forever. For an external interrupt the instruction in EX is squashed
before it executes and mepc points at it, so the handler must **not** advance mepc;
`mret` re-executes that instruction. In both cases `mret` restores MIE from MPIE.

This asymmetry is the single most common trap-handling bug, and it is called out here
rather than left implicit.

---

## 5. Proposed bonus scope

Two of the three bonus items are proposed for implementation. The third is designed and
analysed on paper, and section 2 gives the reason.

### 5.1 Branch prediction — 2-bit saturating BHT

A 64-entry branch history table of 2-bit saturating counters, indexed by PC[7:2]. The
BHT is looked up in IF and its counter state travels with the instruction; if the
instruction decodes as a conditional branch and the counter predicts taken, ID redirects
the PC to PC + immB at a cost of one bubble. The branch resolves in EX; a misprediction
in either direction triggers the standard 2-bubble flush. A correctly predicted not-taken
branch costs nothing, so the predictor can only win on branches that are actually taken.

The predictor is strictly a performance optimisation: with `BHT_ENABLE` off, the machine
is bit-for-bit the base pipeline, so correctness never depends on it. Accuracy and cycle
deltas are measured with dedicated counter hardware.

The counter is a four-state saturating machine: strongly not taken, weakly not taken, weakly taken, strongly taken. A taken outcome moves one step towards strongly taken and a not-taken outcome one step the other way, with both ends saturating. The prediction is the high bit of the counter. Reset places every entry in weakly not taken, so a branch that has not been seen before behaves exactly like the machine with no predictor, and a loop's backward branch reaches a taken prediction after a single observation.

### 5.2 Interrupts — CSRs and mret

A simplified machine-mode interrupt implementation: mstatus (MIE/MPIE), mie, mtvec
(direct mode), mepc, mcause; csrrw/csrrs/csrrc and their immediate forms plus `mret`. An
external irq input, driven by the testbench, demonstrates a timer-like interrupt whose
ISR saves and restores registers, toggles a counter, and returns with `mret`. An
interrupt raised while MIE=0 is held pending rather than dropped.

The entry sequence at the pipeline level is as follows. The instruction in EX when the interrupt is sampled is squashed rather than retired, so it never reaches memory or the register file and never appears in the commit trace. The two younger instructions, in ID and IF, are killed. The two older instructions, already past EX, retire normally, so up to two further instructions commit after the trap fires and before the handler's first instruction does. The handler is then fetched from mtvec. Because the interrupted instruction never executed, `mret` re-runs it.

### 5.3 Instruction cache — designed, not implemented

A direct-mapped 128-line × 16-byte (2 KB) I-cache was designed (parameters and hit/miss
analysis documented in the design document) but deliberately not implemented: the whole
test programs fit in 2 KB, so the hit rate would be a trivial ~99 % and would demonstrate
nothing. This document delivers the design and the reasoning behind the cut in place of
the hardware.

---

## 6. Feasibility evidence — verification method and results

This section and the next answer success criteria 1, 2 and 3. The results are presented
as evidence that the proposal is achievable, not as the endpoint of the work: two timing
improvements are still planned in the RTL, so the same regression will be re-run as the
final acceptance pass after the feature freeze, and the numbers here are preliminary
until then. The remaining work is listed in sections 9 and 10.

### 6.1 Three-tier verification strategy

| Tier | What | State on the prototype |
|---|---|---|
| Tier 1 — Simulator | Vivado 2026.1 xsim batch flow (xvlog → xelab → xsim) driven by a run script; every testbench is self-checking and prints PASS/FAIL with a nonzero exit on failure | Operational |
| Tier 2 — Self-checking tests | Unit testbenches per module (immediate generator, ALU, register file, control, branch unit, memories, PC, counters, BHT, interrupt) plus per-instruction assembly programs with golden register/memory results | 11 unit testbenches and 46 per-instruction programs, all passing |
| Tier 3 — Golden reference | Self-written Python ISS executes the same assembled programs and emits a commit trace (pc, instruction, register writes, memory writes); the RTL testbench emits the identical format from write-back and the files are diffed byte-for-byte | Assembler/ISS cross-validated (4,323 tool-level checks); every program-level test trace-exact against the ISS |

The methodological point behind tier 3 is that a final-state check tells you the answer
is wrong, whereas a trace diff tells you *which instruction* went wrong. For a five-stage
pipeline that is the difference between an afternoon of debugging and a week of it.

Every expected value is generated by the reference model rather than hand-written, so a
test cannot agree with the RTL merely because the same person wrote both.

### 6.2 Verification results on the prototype

The following results are from the regression run against the current RTL, at all four
combinations of the `FORWARDING` and `BHT_ENABLE` parameters. They are the feasibility
evidence for criteria 1 and 2, and they will be re-measured after the planned timing
work, which is why they are reported as preliminary.

| Suite | Scope | Result on the prototype |
|---|---|---|
| Unit testbenches (11) | imm_gen 1,865 vectors; ALU 5,072; regfile 76; control 667; branch_unit 16,072; dmem 32; imem 10; PC 12; perf counters 19; BHT 2,600 checks; interrupt 22 assertions | PASS — all suites green |
| Toolchain self-check | Assembler vs ISS cross-validation | PASS — 4,323 checks |
| Per-instruction programs (46) | One program per encoding, golden register/memory state checked | 46/46 PASS at all four forwarding × BHT configurations |
| Hazard programs (9) | Directed forwarding, load-use, branch-flush and CSR-hazard cases | 9/9 PASS at all four configurations |
| Program-level diff tests | Fibonacci, bubble sort, branch-heavy loop, branch-prediction demo, interrupt demo — RTL commit trace diffed against the ISS trace | 5/5 programs trace-exact against the ISS at all four configurations, interrupt demo included |

The suite is driven by `tools/run_tests.py`, which runs each program in turn and prints a PASS or FAIL line per program followed by a TOTAL row carrying cycles, retired instructions, load-use stalls, flushes and CPI. The exit code is nonzero if any program fails, so a regression cannot pass by being misread.

The same behaviour is observable directly in simulation. Around a load-use hazard the stall signal is high for exactly one cycle while the PC and the IF/ID register hold their values, and the forwarding select switches to the MEM/WB path on the following cycle. On a taken branch the two flush signals assert together, and the commit-trace valid signal never asserts for either killed instruction.

### 6.3 Performance measurement method

Performance counters inside the RTL count cycles, retired instructions, load-use stalls,
flushes, and (with the BHT enabled) predictions and mispredictions, so CPI is measured
directly by the testbench in integer arithmetic (CPI ×1000). Two comparisons are
reported: (1) CPI with forwarding on vs off on the same programs, which isolates the
benefit of the bypass network; and (2) cycles with the BHT enabled vs disabled, which
isolates branch-prediction accuracy. Synthesis reports LUT/FF/BRAM utilisation and fmax
for the `xc7a35tcpg236-1` part.

This is the method that satisfies success criterion 3: a feature is switched off and the
same programs are re-run, so every figure carries its own baseline.

---

## 7. Feasibility evidence — measured on the prototype

These are measurements on the current prototype RTL. They will be re-measured after the
planned timing work, one change of which alters when a load result becomes available and
can therefore move CPI.

### 7.1 Forwarding on versus off

Forwarding on vs off isolates the bypass network's contribution: CPI 1.39 vs 1.84 on
average, a 1.32× speedup.

| Program | Insns | Cycles (fwd on) | CPI | Cycles (fwd off) | CPI | Speedup |
|---|---|---|---|---|---|---|
| fib (Fibonacci) | 658 | 900 | 1.368 | 1,489 | 2.263 | 1.65× |
| bsort (bubble sort) | 1,366 | 1,880 | 1.376 | 2,601 | 1.904 | 1.38× |
| bloop (branch loop) | 2,878 | 4,019 | 1.396 | 4,913 | 1.707 | 1.22× |
| **Total / average** | **4,902** | **6,799** | **1.387** | **9,003** | **1.837** | **1.32×** |

Fibonacci gains the most because its inner loop is a tight dependent chain, so every one
of those RAW hazards is a stall at `fwd=0` and free at `fwd=1`. The branch loop gains the
least, and the reason is instructive: its load-use stall count is zero even with
forwarding enabled, because its loop bodies compute independent quantities. A program
with no producer-consumer adjacency gives the bypass network nothing to save.

With forwarding enabled, everything above CPI 1.0 is control-flow bubbles and load-use
stalls. There is no other source of delay in this design.

### 7.2 Branch prediction

The branch-prediction demo program (bpred, all loop back-edges conditional, 86 % of
dynamic branches taken) reaches 95.5 % prediction accuracy with the 2-bit BHT and saves
14.5 % of cycles; Fibonacci reaches 93.4 %. An adversarial program written to defeat a
2-bit predictor (alternating taken/not-taken) measures 49.9 % accuracy and costs 10 %
more cycles. We included it on purpose to show where the predictor's limits are.

The honest summary is that a 2-bit table helps loop-dominated code, is neutral on
exit-dominated code, and hurts on alternating branches. It is a cheap heuristic, not a
guarantee, and reporting the adversarial case is more useful than hiding it.

### 7.3 Synthesis

After pinning all three memory arrays to their intended resources (`ram_style`
attributes; IMEM and DMEM now map to block RAM, the register file to LUT RAM), the
post-route synthesis of the full design (out-of-context, `xc7a35tcpg236-1`) reports
**1,461 LUTs, 819 FFs, and 2 BRAMs**. The design closes setup timing at a 13.5 ns
period, i.e. **74 MHz** (WNS +0.052 ns, zero failing endpoints); an 80 MHz attempt does
not close. Register-to-register hold is met at every constraint point; the only hold
flags in the report are paths from the `rst` input port, an artefact of out-of-context
synthesis where no clock buffer is modelled.

The critical path is the load-to-branch chain: the DMEM block RAM clock-to-output
(2.454 ns, the largest single term), the byte-lane select and sign extension of the load
result in WB, the MEM/WB-to-EX forwarding mux delivering that result to a dependent
branch in EX, the branch comparator, and the redirect logic into the PC register clock
enable. Two timing fixes — registering the DMEM output extension into WB, and
precomputing forwarding match bits in ID — are documented for the final report.

This satisfies success criterion 4: 74 MHz is measured rather than estimated, and the
path that limits it is identified, which is what makes the two planned fixes a scheduled
task rather than a hope.

---

## 8. Team organisation

The team is three members with explicit ownership: one designer, one coder, one tester.
Every deliverable has exactly one owner; cross-review is by reading, not by silent edits.

| Role | Member | Responsibilities | State |
|---|---|---|---|
| Design | 杨辉宗 | Microarchitecture specification; instruction subset and format decisions; hazard and forwarding scheme design; memory subsystem and reset strategy; the design document (block diagram, control truth table, pipeline-register fields); design review of all RTL before commit | Complete — the design document is the source the RTL was written against |
| Coding | 吴宏庆 | All Verilog RTL (19 modules: 5 pipeline registers, datapath units, forwarding/hazard/branch units, CSR file, BHT, performance counters, memories, top level); the Python assembler and golden ISS; simulation scripts; fixes from test failures | Complete for the 46-encoding core plus both bonus features; fix-on-fail loop continues with testing |
| Testing | 王伟成 | Verification plan; unit testbenches and per-instruction programs; golden vectors and expected results; RTL-vs-ISS trace diffing; performance measurement (CPI, forwarding on/off, BHT accuracy); synthesis reporting; final demo script | Green — all suites green at all four build configurations; final regression, waveform capture and demo packaging remaining (section 9) |

Interface contracts between the three roles are written down (module boundaries and file
formats between design, RTL, and testbench), which is what lets the three workstreams
overlap: the tester's fixtures were generated before the RTL froze, and the coder's fixes
are re-verified by the tester's regression rather than by self-report.

---

## 9. Deliverables, owners, milestones and risk

### 9.1 Deliverables — one owner each

| Artefact | Owner | State |
|---|---|---|
| Design document and control truth table | Design | Complete |
| 19 RTL modules, plain Verilog-2001 | Coding | Complete |
| Assembler and reference model | Coding | Complete |
| Self-checking test suite | Testing | Complete |
| Performance measurements | Testing | Preliminary |
| Synthesis report: fmax and utilisation | Testing | One run remaining |
| Live demo and script | All three | Sep 16 |

### 9.2 Work plan to the final demo

| Date | Milestone | Owner | State |
|---|---|---|---|
| Sep 8–9 | Complete the forwarding-on/off × BHT-on/off sweep over all suites; consolidate the results table | Testing | Complete |
| Sep 10 | Proposal submitted (this document) | All | This document |
| Sep 11–12 | Full regression at scale; bug-fixing; final synthesis run with fmax and utilisation | Testing / Coding | Upcoming |
| Sep 13 | Branch-prediction accuracy measurement; performance chapter of final report | Testing | Upcoming |
| Sep 14–15 | Interrupt demo polish; feature freeze end of Sep 15 | Coding / Testing | Upcoming |
| Sep 16 | Performance tables, slides, demo script, rehearsal | All | Upcoming |
| Sep 17 | Final presentation and demo | All | Upcoming |

### 9.3 Standing risk register

Risks are listed with the mitigation decided in advance, so that no decision has to be
improvised under time pressure.

| # | Risk | Mitigation, decided in advance | State |
|---|---|---|---|
| R1 | The two RTL timing improvements do not close cleanly | Freeze on the current 74 MHz build, whose results are already verified, rather than ship an untested faster one. Decision point: end of Sep 14 | Live |
| R2 | A timing change shifts the measured CPI | One of the changes alters when a load result becomes available, so it can move CPI. Every performance figure is re-measured after the feature freeze, not before. Figures in section 7 are labelled preliminary for this reason | Live |
| R3 | The instructor requires Vivado 2019.2 rather than 2026.1 | The RTL is plain Verilog-2001 with no IP catalog and no block design, and a project-generation script is committed instead of a version-locked project file | Contingent |
| R4 | The interrupt bonus does not stabilise | Cut to a BHT-only machine and bank the working 37-instruction core. A working pipeline with clean CPI numbers demonstrates better than a broken three-bonus machine | **Retired** — the interrupt bonus was green on 7 September, so this rule was never exercised |

---

## 10. Commitments and remaining work

### 10.1 Where each commitment stands

| Item | State |
|---|---|
| Design (microarchitecture, hazards, memory, control) | Complete — documented in the design document with block diagram and control truth table |
| RTL implementation (46 encodings + forwarding + stall + flush) | Complete — 19 Verilog modules, plain synthesizable Verilog-2001 |
| Bonus: branch prediction (BHT) | Implemented; accuracy and cycle deltas measured |
| Bonus: interrupts (CSRs + mret) | Implemented; directed test and ISS trace diff both passing |
| Bonus: I-cache | Designed only, by deliberate decision — section 5.3 documents the design and the reason |
| Verification (unit + per-instruction + diff tests) | Green at all four build configurations on the current RTL; final regression after the timing work |
| Performance (CPI, forwarding comparison, BHT accuracy) | Preliminary figures in section 7; final figures after the full sweep |
| Synthesis (fmax, utilisation) | Placed and routed; setup timing met at 74 MHz; final run after feature freeze |
| Final demo | Planned (demo script, slides) — Sep 16–17 |

### 10.2 What remains

Between this proposal and the final demo: two timing improvements, the final regression
on the frozen RTL, the final synthesis run, and the demo package.

None of that is new design work. Every success criterion set out in section 1.3 has
already been met once on a prototype that runs the full instruction subset with both
bonus features. What remains is finishing the measurement on a machine that already
works, and packaging it for the demonstration on 17 September.
