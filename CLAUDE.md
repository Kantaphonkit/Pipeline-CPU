# CLAUDE.md — RISC-V RV32I Pipelined CPU Implementation Handoff

You (Claude Code) are implementing this course project for Kantaphon. **Read `PROJECT-REQUIREMENTS.md` in this folder first — it is the authoritative spec.** This file tells you how to work.

## Context

- Course: Computer Organization (BIT Y4T1). Midterm report **Sep 10**, final presentation + demo **Sep 17** (2026).
- The design source is `docs/DESIGN.pdf`; a full expert evaluation of it is at `docs/DESIGN-evaluation-opus.md`. Where DESIGN.pdf and PROJECT-REQUIREMENTS.md conflict, PROJECT-REQUIREMENTS.md wins (it contains deliberate corrections — e.g. forwarding priority, branch resolution stage, toolchain).
- There is an old MIPS prototype elsewhere on this machine (NOT in this repo). **Do not seek it out, copy, or reuse anything from it.** Clean restart is a deliberate decision.

## Environment

- Windows 11, git-bash shell. Vivado **2026.1** at `D:/AMDDesigntools/2026.1/Vivado` — run xsim in batch mode (`xvlog`, `xelab`, `xsim`) from bash or a `run.ps1`. No Icarus, no GTKWave, no Spike — do not install anything; use xsim only.
- Python 3.11 available for `tools/asm.py` and `tools/iss.py`.
- Version portability rules: plain synthesizable Verilog-2001 only; memories as `reg [31:0] mem [0:N-1]` + `$readmemh`; no IP catalog, no block designs, no `.xpr` committed — provide `vivado/create_project.tcl` instead.

## Repo layout to create

```
RISCV-CPU/
  PROJECT-REQUIREMENTS.md   # spec (exists)
  CLAUDE.md                 # this file
  rtl/                      # pc.v, if_id.v, id_ex.v, ex_mem.v, mem_wb.v, regfile.v,
                            # alu.v, alu_ctrl.v, imm_gen.v, control.v, branch_unit.v,
                            # forward_unit.v, hazard_unit.v, csr.v, bht.v,
                            # perf_counters.v, imem.v, dmem.v, cpu_top.v
  tb/                       # per-instruction + program-level + irq testbenches (self-checking)
  asm/                      # test programs (.s) + expected results
  tools/asm.py              # RV32I assembler -> .hex
  tools/iss.py              # Python golden-reference ISS, emits commit traces
  sim/                      # run.ps1, waveform configs
  vivado/                   # create_project.tcl, synthesis reports
  docs/                     # DESIGN.md (rewritten design doc), report drafts
```

## Implementation order (follow strictly — each step gates the next)

1. `tools/asm.py` (RV32I subset) and `tools/iss.py` (golden reference). Cross-validate them against each other on all immediate formats BEFORE any RTL.
2. Unit-test `imm_gen.v`, `alu.v`, `regfile.v` standalone in xsim. The document's own warning: imm_gen is where the bugs live. Do not skip this.
3. Full decode: `control.v` + `alu_ctrl.v` with the complete per-instruction truth table (write the table into `docs/DESIGN.md` too — it is report material).
4. Wire the 5-stage datapath with NO hazard logic; verify with NOP-padded straight-line programs.
5. Forwarding + load-use stall + branch flush; all per-instruction tests pass.
6. Program-level tests (Fibonacci, bubble sort, branch loop) diff-tested against `iss.py` traces.
7. Bonus A: BHT. Bonus B: interrupt/CSR (simplified set per spec). I-cache is NOT implemented — report-only.
8. Vivado synthesis → fmax + utilization report.

## Non-negotiable correctness rules (classic-bug checklist)

- Forwarding priority: EX/MEM over MEM/WB. MEM/WB only when EX/MEM doesn't match.
- Never forward from or write to x0, in both forward_unit and regfile.
- `alu_ctrl` must not decode `inst[30]` for non-shift I-type ops.
- Register shifts use `rs2[4:0]`; immediate shifts use `imm[4:0]`.
- Regfile: WB→ID internal bypass (or negedge write).
- Store-data (rs2) forwarding for sw/sb/sh.
- Branches + jalr resolve in EX (2-bubble flush); jal resolves in ID (1 bubble).
- mepc in PC mux for mret; ISR advances mepc by 4 for synchronous traps; mtvec direct mode.
- ebreak = testbench halt signal (done flag).
- Every testbench is self-checking: golden values hardcoded or diffed against iss.py; print PASS/FAIL; exit nonzero on FAIL.

## Working conventions

- Commit after every green milestone, message format: `rv32i: <what works>` (e.g. `rv32i: imm_gen passes all format tests`).
- Never weaken a test to make it pass. If a requirement is ambiguous, check PROJECT-REQUIREMENTS.md; if still unclear, stop and ask — do not guess on spec-level decisions.
- Keep `docs/DESIGN.md` updated as the living design doc (it becomes the midterm report's technical core).
- Feature freeze end of Sep 15. After that: bugfix, measurement, slides only.
- If interrupt bonus is not working by end of Sep 14, cut it (per spec §4 risk rule) — do not let it destabilize the machine.
