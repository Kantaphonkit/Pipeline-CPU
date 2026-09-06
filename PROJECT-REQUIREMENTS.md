# PROJECT REQUIREMENTS — RISC-V RV32I Pipelined CPU

Course: Computer Organization (BIT Y4T1) · Created 2026-09-06
Deliverables: midterm report **Sep 10** · final presentation + demo **Sep 17**

## 1. Course task statement (verbatim)

> Design a pipeline CPU based on MIPS/RISC-V or other instruction subsets with more than 16 instructions. And implement the CPU by Verilog HDL. Use the simulation tools to show the function and performance of your CPU.
>
> Bonus items: support interrupt, cache, branch prediction, etc.
>
> The development tool: Vivado 2019.2
> The simulate tool: Mars4_5

## 2. Decisions (FINAL — made by Kantaphon, 2026-09-06)

| Decision | Choice |
|---|---|
| ISA | **RISC-V RV32I subset** (~37 core instructions + CSRs for interrupt bonus) |
| Pipeline | 5-stage in-order: IF → ID → EX → MEM → WB |
| HDL | Synthesizable Verilog (IEEE 1364), Verilog-2001 style, no IP catalog / block design |
| Reuse from MIPS prototype | **NONE.** Clean restart. The old MIPS `pipeline-cpu/` folder is reference-only and must not be copied or modified. |
| Primary toolchain | **Windows 11 + Vivado 2026.1** (xvlog/xelab/xsim batch flow). Course names 2019.2 — version question being confirmed with instructor; keep RTL version-portable (plain Verilog + `$readmemh`, commit a `create_project.tcl`, never a 2026.1 `.xpr`). |
| Golden reference | **Own Python ISS** (`tools/iss.py`) — Mars4_5 is MIPS-only and cannot verify RISC-V; teacher is flexible on this. |
| Assembler | Own Python assembler (`tools/asm.py`) → `.hex` instruction images |
| Bonus commitment | **Branch prediction (2-bit BHT)** + **Interrupt (CSRs + mret, simplified)**. **I-cache CUT** — written up as "designed, not implemented" in the report. |
| Board | Simulation-only + Vivado synthesis report (pick part, e.g. xc7a35tcpg236-1). No FPGA board demo. |

## 3. Requirements (from DESIGN.pdf, corrected per evaluation)

### 3.1 ISA
- RV32I subset per DESIGN.pdf §2: R-type (10), I-arith (9), loads (5), stores (3), branches (6), U-type (2), jumps (2), system (ecall/ebreak + CSR ops + mret — count = 9 encodings, not 7; pick one consistent total and state it in the report).
- All 6 instruction formats; immediates per DESIGN.pdf §6 (verified correct bit-for-bit), PLUS the 6th immediate: CSR `zimm = inst[19:15]`, **zero-extended**, for csrrwi/csrrsi/csrrci.
- ABI correction for report: t0–t6 are **caller-saved temporaries**; s0–s11 are saved. `jal`/`jalr` write **rd** (any register), not "x1" — x1-as-ra is convention only.
- `ebreak` doubles as the testbench **halt signal** (sets a `done` flag). `ecall` = trap with mcause 11 (or drop both from the count if interrupt bonus scope shrinks — decide once, document).

### 3.2 Datapath & hazards (corrections to DESIGN.pdf)
- Branch resolution: conditional branches + `jalr` resolve in **EX** (2-bubble flush). `jal` resolves in **ID** (1 bubble) — target known at decode.
- Forwarding priority: **EX/MEM forwarding wins over MEM/WB**; MEM/WB forwards only when EX/MEM does not match. (DESIGN.pdf §7 wording was backwards — implement the correct rule.)
- Required extras (all classic-bug items, all mandatory):
  - Register file WB→ID **internal bypass** (or write on negedge) — WB writing the register ID reads same cycle.
  - **x0 suppression** in forwarding unit AND regfile (never forward from / write to x0).
  - `alu_ctrl` must **not** decode `inst[30]` for non-shift I-type ops (else `addi` with negative imm decodes as `sub`).
  - Shift amount: register shifts use `rs2[4:0]`; immediate shifts use `imm[4:0]`.
  - **Store-data forwarding** for rs2 of `sw/sb/sh` through EX.
  - `mepc` path in the PC-select mux (for `mret`), alongside PC+4 / branch / jal / jalr / mtvec.
- Trap semantics: for a synchronous exception, `mepc` = faulting PC — ISR must advance `mepc` by 4 before `mret` or it loops forever. `mtvec` direct mode (low bits = 00). Document both.

### 3.3 Memory subsystem (must be specified, was missing)
- Harvard: separate IMEM/DMEM, both plain `reg [31:0] mem [0:N-1]` + `$readmemh`, 1-cycle synchronous read/write (MEM completes in one stage).
- Sizes: IMEM 4KB (1024 words), DMEM 4KB. Little-endian byte lanes for lb/lh/lbu/lhu/sb/sh.
- Misaligned access: defined as don't-care, documented.
- Reset: synchronous, active-high, PC ← 0x0, pipeline registers cleared, regfile uninitialized (x0 reads 0).
- Entry convention: program starts at PC=0; `sp` initialized by software (first instructions); data region at top of DMEM.

### 3.4 Bonus scope
- **BHT**: 64-entry 2-bit saturating counter, indexed PC[7:2], predict in IF, flush on mispredict, prediction-accuracy counter exposed. Demo on loop-heavy program.
- **Interrupt (simplified)**: CSRs mstatus (MIE/MPIE only), mie, mtvec, mepc, mcause (drop mtval/mscratch/mip from RTL; mention as designed). csrrw/csrrs/csrrwi + mret. External irq input (testbench-driven). Demo: timer-like interrupt toggling a counter; ISR saves/restores registers.
- **I-cache: NOT implemented.** Report section only: direct-mapped 128×16B (2KB), parameters from DESIGN.pdf §8c, analysis of why cut (needs multi-cycle main memory model to be meaningful; whole test program fits in 2KB so hit rate would be ~99% trivially).

### 3.5 Verification (replaces DESIGN.pdf §10 Spike plan)
- Tier 1: Vivado 2026.1 xsim batch (`xvlog` → `xelab` → `xsim`) via `run.ps1`.
- Tier 2: self-checking testbenches — per-instruction tests (one per instruction, Python-assembled, golden register/memory state checked, PASS/FAIL printed) — this is the midterm evidence.
- Tier 3: `tools/iss.py` Python ISS emitting a commit trace (`<pc> <insn_hex> x<rd>=<value> [mem[addr]=<value>]`); Verilog testbench `$fwrite`s the identical format from WB; diff the files. Diff-test on Fibonacci, bubble sort, branch-heavy loop.
- Pass criteria: every per-instruction test PASS; zero diff lines on all three programs; interrupt demo shows correct mepc/mcause/ISR effect.
- Performance: perf counters in RTL (cycles, instructions retired, load-use stalls, flushes, mispredicts). Report CPI with forwarding **on/off** (compile-time parameter) — that comparison is the "show performance" requirement. Vivado synthesis: fmax, LUT/FF/BRAM for the chosen part.

## 4. Timeline (hard deadlines in bold)

| Date | Milestone |
|---|---|
| Sep 6–7 | Repo scaffold, asm.py retarget to RV32I, iss.py, unit-test imm_gen/alu/regfile standalone |
| Sep 7–8 | Decode + control truth table, datapath wired 5-stage, NOP-padded straight-line tests pass |
| Sep 8–9 | Forwarding + load-use stall + branch flush; all per-instruction tests pass |
| Sep 9 | Fibonacci/sort/branch-loop running; CPI counters live. **Write midterm report.** |
| **Sep 10** | **Midterm report due.** |
| Sep 11–12 | ISS diff-testing at scale, bug fixing; synthesis run → fmax + utilization |
| Sep 13 | BHT bonus + accuracy measurement |
| Sep 14–15 | Interrupt/CSR bonus. **Hard feature freeze end of Sep 15.** |
| Sep 16 | Performance table, slides, demo script, rehearsal |
| **Sep 17** | **Final presentation + demo.** |

Risk rule: if the interrupt bonus is not working by end of Sep 14, cut it to BHT-only and bank the working 37-instruction machine. A working pipeline with clean CPI numbers demos better than a broken three-bonus machine.

## 5. Instructor confirmations pending (Kantaphon to send)
1. Vivado 2026.1 acceptable in place of 2019.2?
2. RISC-V RV32I with self-written Python reference model acceptable in place of Mars4_5 (Mars is MIPS-only)?

## 6. Reference documents
- `DESIGN.pdf` — original design plan (base document; toolchain section superseded by this file)
- `DESIGN-evaluation-opus.md` — full Opus evaluation, 2026-09-06 (source of the corrections in §3)
