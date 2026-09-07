# PROBLEMO.md — Project completeness audit, findings and improvement plan

Repo: `Pipeline-CPU` (RISC-V RV32I 5-stage pipeline, Computer Organization BIT Y4T1)
Audit date: 2026-09-07 · Audited commit: `3672325` (`main`, clean tree)
Deadlines: midterm report **Sep 10**, feature freeze **end of Sep 15**, final presentation + demo **Sep 17**

> **Caveat on evidence.** This audit was performed from a macOS checkout where
> Vivado 2026.1 / xsim are not installed. Nothing in `sim/`, `tools/run_tests.py`
> or `vivado/` was re-executed. Every statement about simulation or synthesis
> results below is taken from the committed artefacts (`vivado/reports/*.txt`,
> `docs/DESIGN.md` §10–§11, `README.md`, git history) and from reading the RTL,
> testbenches and scripts. Items marked **[VERIFY ON WINDOWS]** need one run on
> the Windows machine to confirm.

---

## 0. One-paragraph verdict

The project is **feature-complete against `PROJECT-REQUIREMENTS.md`** and is
roughly **eight days ahead** of the schedule in §4 of that spec (the spec had the
BHT on Sep 13 and interrupts on Sep 14–15; both were committed Sep 7). All eight
steps of the build order in `CLAUDE.md` are done, every suite is reported green
at all four `FORWARDING` × `BHT_ENABLE` combinations, synthesis reports exist,
and `docs/DESIGN.md` already contains the technical core of the midterm report.
What remains is (a) the report and demo deliverables, which only Kantaphon can
drive, and (b) a short list of engineering loose ends — one of which (the
synthesis narrative in DESIGN.md §11.5) is very likely **factually wrong** and
must be fixed before it is quoted in a report. The extra schedule slack makes
every item below affordable before the Sep 15 freeze.

---

## 1. Recap — what has been done

### 1.1 Timeline: planned vs actual

| Spec milestone (PROJECT-REQUIREMENTS §4) | Planned | Actual (git log) | Commit |
|---|---|---|---|
| Repo scaffold, asm.py, iss.py, unit-test imm_gen/alu/regfile | Sep 6–7 | Sep 6–7 | `16fde1b`, `0f051c6`, `8533a87` |
| Decode + control truth table | Sep 7–8 | Sep 7 | `7c65184` |
| 5-stage datapath, NOP-padded tests | Sep 7–8 | Sep 7 | `d7f9155` |
| Forwarding + load-use + flush, all per-insn tests | Sep 8–9 | Sep 7 | `28768aa` |
| fib / sort / branch-loop + CPI counters | Sep 9 | Sep 7 | `28768aa` |
| **Midterm report** | **Sep 10** | not started (DESIGN.md is the draft) | — |
| ISS diff-testing at scale; synthesis → fmax + utilization | Sep 11–12 | Sep 7 | `813311b`, `62d5413` |
| BHT bonus + accuracy | Sep 13 | Sep 7 | `c958efe` |
| Interrupt/CSR bonus | Sep 14–15 | Sep 7 | `c958efe` |
| Performance table, slides, demo script, rehearsal | Sep 16 | not started | — |
| **Final presentation + demo** | **Sep 17** | — | — |

Seventeen commits in total, one per green milestone, all in the
`rv32i: <what works>` / `docs:` / `vivado:` / `sim:` format CLAUDE.md asks for.

### 1.2 Build-order checklist (CLAUDE.md "Implementation order")

| # | Step | Status | Evidence |
|---|---|---|---|
| 1 | `asm.py` + `iss.py`, cross-validated on all immediate formats before RTL | **Done** | `tools/test_tools.py`, 4323 checks; 54 hand-computed encodings written before the assembler existed (DESIGN.md §10.2) |
| 2 | Unit-test `imm_gen`, `alu`, `regfile` standalone | **Done** | `tb/tb_imm_gen.v` (1865 vectors incl. B/J bit-11 traps), `tb/tb_alu.v` (5072), `tb/tb_regfile.v` (76) |
| 3 | Full decode `control.v` + `alu_ctrl.v`, truth table in DESIGN.md | **Done** | 667 vectors; table is *generated* from `tools/gen_control_table.py` into DESIGN.md §3 with a `--check` staleness guard |
| 4 | 5-stage datapath, no hazard logic, NOP-padded programs | **Done** | `tb/bringup/` 7 programs; `d7f9155` |
| 5 | Forwarding + load-use + flush, all per-insn tests | **Done** | 46 insn + 9 hazard programs trace-exact; `28768aa` |
| 6 | Program-level diff tests vs ISS | **Done** | fib / bsort / bloop / bpred / irq_demo, byte-exact trace diff |
| 7 | Bonus A BHT; Bonus B interrupt/CSR; I-cache report-only | **Done** | `rtl/bht.v`, `rtl/csr.v`, `tb/tb_bht.v` (2600 checks), `tb/tb_irq.v` (21 assertions), DESIGN.md §9.3 for the cache write-up |
| 8 | Vivado synthesis → fmax + utilization | **Done, but see §2.1** | `vivado/reports/{timing,utilization,clocks}.txt`, post-P&R, OOC |

### 1.3 Non-negotiable correctness rules (CLAUDE.md) — each one has a test

| Rule | Where implemented | Where tested |
|---|---|---|
| EX/MEM forwarding beats MEM/WB | `rtl/forward_unit.v:84-95` | `asm/hazard/fwd_ex_ex.s` (x5=100, x5+=1, consumer must see 101); mutation "priority swapped" recorded as caught |
| Never forward from / write to x0 | `forward_unit.v:80-81`, `regfile.v:18-30` | `asm/hazard/x0_hazard.s`, `tb_regfile`; mutation recorded |
| `alu_ctrl` ignores `inst[30]` for non-shift I-type | `rtl/alu_ctrl.v`, DESIGN.md §4.2 | `tb_control` addi-with-bit30 goldens; mutation recorded |
| Register shifts use `rs2[4:0]`, immediate shifts `imm[4:0]` | ALU takes `b[4:0]` after the operand mux (`alu.v`) | `tb_alu` all 32 shift amounts; `asm/insn/{sll,srl,sra,slli,srli,srai}.s` |
| Regfile WB→ID bypass | `regfile.v:18-24` | `tb_regfile`, `asm/hazard/fwd_wb_id.s`; mutation recorded |
| Store-data forwarding | `fwd_c` in `forward_unit.v:93-95`, `cpu_top.v:420-421` | `asm/hazard/store_data_fwd.s` |
| Branches + jalr in EX (2 bubbles), jal in ID (1 bubble) | `cpu_top.v:285-291, 490-538`; `hazard_unit.v:147-148` | `asm/hazard/branch_flush.s` (poison in every shadow slot); cycle counts in DESIGN.md §11.1 |
| mepc in PC mux; ISR advances mepc by 4 on sync trap; mtvec direct | `cpu_top.v:530-538`, `csr.v:145-152` | `tb/bringup/bu_trap.s`, `asm/insn/{ecall,mret}.s`, `tb/tb_irq.v` |
| ebreak = halt / done flag | `cpu_top.v:652-661` | every program ends in `ebreak`; `tb_program` waits on `done` |
| Every testbench self-checking, PASS/FAIL, nonzero exit | `sim/run.sh:207-219` greps `^PASS`/`^FAIL` | all 12 `tb/*.v` follow the one-PASS-line contract in `docs/INTERFACES.md` §7 |

### 1.4 Reported results (from DESIGN.md §10.10 / §11, not re-run here)

| Metric | Value |
|---|---|
| Encodings | 46 (37 core + 9 system) |
| Unit testbenches | 11, all PASS |
| Program suites | 46 insn + 9 hazard + 5 prog + 7 bring-up + smoke, all trace-exact at 4 parameter combinations |
| CPI fwd=1 / fwd=0 (fib+bsort+bloop) | 1.387 / 1.837 → 1.32× |
| BHT | `bpred` 95.5 % acc, −14.5 % cycles; `fib` 93.4 %; `bloop` (adversarial) 49.9 %, +10 % cycles |
| Interrupt demo | 2 IRQs, 633/633 trace lines match ISS |
| Synthesis (xc7a35t, OOC, post-P&R, 10 ns constraint) | 2173 LUT, 960 FF, 1 BRAM, WNS −1.393 ns → "fmax ≈ 88 MHz" |

### 1.5 Things that were done unusually well (keep these prominent in the report)

1. **ISS-first, fixtures-from-ISS.** No golden value in the repo is hand-typed.
   That is why datapath bring-up took two days instead of a week.
2. **Generated control table.** DESIGN.md §3 and `tb_control`'s vectors share
   one source (`tools/gen_control_table.py`), with `--check` to detect drift.
3. **Mutation table** (DESIGN.md §10.4), including the two mutations that
   *correctly* do not fail (inverted BHT training, over-approximated interlock).
   That is the difference between "tests pass" and "tests are trusted".
4. **Interrupt alignment** (DESIGN.md §9.2): measuring the retire index from
   the RTL and feeding it back to the ISS is the right way to diff-test an
   asynchronous event, and it is explained honestly.
5. **The jal/BHT-redirect-under-stall combinational-loop analysis** (DESIGN.md
   §6.3) is a real bug story with a real fix, ideal report material.
6. **Adversarial benchmark reported, not hidden** (`bloop` gets slower with
   the BHT and the arithmetic is shown to close exactly).

---

## 2. Findings — problems and improvement areas

Ordered by impact on the two deliverables. Each item has: what was observed,
evidence, why it matters, the recommended action, and an acceptance criterion.
Suggested routing per CLAUDE.md (`opus-engineer` for subtle work,
`sonnet-worker` for mechanical work) is given where a subagent fits.

### 2.1 [HIGH — report correctness] DESIGN.md §11.5 synthesis narrative is very likely wrong

**Observed.** DESIGN.md §11.5 states:

> "IMEM maps to one `RAMB36E1` in both designs … DMEM … distributed LUT RAM …
> The register file infers as distributed RAM (`RAM32M`) in both."

and describes the full-design critical path as "the EX/MEM destination-register
register through the forwarding/hazard compare logic and into a register-file
read address".

**Evidence in `vivado/reports/`:**

- `timing.txt:205-207`, `:265`: the single `RAMB36E1` in the netlist is named
  **`regs_reg_r1_0_31_0_5_i_7`**. `regs` is the register-file array
  (`rtl/regfile.v:16`); `r1` = read port 1; `0_31` = 32 entries. The IMEM array
  is named `mem` (`rtl/imem.v:14`). So the one block RAM holds (part of) the
  **register file**, not the instruction memory.
- `utilization.txt:191`: `RAMS64E = 512`. DMEM is 1024 × 32; a RAMS64E is 64 × 1;
  1024/64 × 32 = 512. So **all** distributed-RAM cells are DMEM.
- `utilization.txt:199,201`: `RAMD32 = 68`, `RAMS32 = 20` — consistent with the
  rest of the register file's two read ports.
- Nothing in the utilization report is large enough to be a 1024 × 32 IMEM.
- `vivado/synth.tcl:62` feeds `IMEM_INIT=asm/smoke.hex`, a ~20-instruction
  program. A read-only array with constant contents and no write port is a ROM;
  Vivado routinely collapses a mostly-zero ROM into a handful of LUTs.

**Most likely explanation.** IMEM was optimised into logic because its
contents are a tiny constant, and Vivado, freed from any BRAM pressure and
timing-driven, pushed one slice of the register file into a BRAM by absorbing
the ID/EX output register (`rs1_val_q`) as the BRAM's synchronous-read
register. That also explains why the critical path *ends at a BRAM address
pin*: the ID/EX flush term (`stall | flush_id`, `cpu_top.v:315`) now sits in
front of the BRAM address/enable, so the path is

`EX/MEM.rd_addr → fwd_a select → forwarded operand → branch comparator (carry chain, "bht_misses_i_*") → branch_cond → br_redirect → flush_id → ID/EX enable → regfile BRAM address`

i.e. **the EX-stage branch resolution feeding the ID/EX flush**, which is the
classic 5-stage critical path — not merely "the forwarding compare into a
register-file address" as §11.5 says.

**Why it matters.** §11.5 is verbatim report material. The BRAM count, the
"IMEM in BRAM" claim, the "DMEM moved to LUT RAM because of timing" story and
the critical-path description would all be challenged by an instructor who
reads the report alongside the utilization table. Also, because IMEM depends on
the loaded program, **the utilization and fmax numbers are program-dependent**
and are not a characterisation of a real 4 KB instruction memory.

**Action.**
1. Pin the memory mapping so the reports describe the design rather than the
   smoke program:
   - `rtl/imem.v`: `(* ram_style = "block" *) reg [31:0] mem [0:1023];`
   - `rtl/dmem.v`: `(* ram_style = "block" *)` (or `"distributed"` if the
     timing argument is to be kept — but then say so as a *choice*).
   - `rtl/regfile.v`: `(* ram_style = "distributed" *) reg [31:0] regs [0:31];`
   These attributes are plain Verilog-2001 comments-with-meaning, portable to
   Vivado 2019.2, and do not alter simulation.
2. Optionally initialise IMEM at synthesis with a *large* image (e.g.
   `asm/prog/bpred.hex`) so a ROM-to-logic collapse cannot happen even without
   the attribute.
3. Re-run `bash vivado/synth.sh --impl` on Windows. Read `synth.log` for
   `Synth 8-5584` / `Synth 8-3971` / ROM-inference messages and record them.
4. Rewrite DESIGN.md §11.5 (both table rows, the "Memory inference" paragraph,
   and the critical-path paragraph) from the new report. Delete the sentence
   about DMEM moving to LUT RAM for timing reasons unless the new log says so.
5. Update the README status row (`1 BRAM` etc.).

**Acceptance.** `utilization.txt` shows ≥ 2 `RAMB36E1`/`RAMB18E1` with instance
names under `u_imem` (and `u_dmem` if pinned to block); the BRAM in the
critical path, if any, is named `u_imem/…` or `u_dmem/…`; every number quoted
in §11.5 matches the report files at the same commit.

**Routing.** `opus-engineer` for the re-run + rewrite (needs interpretation of
the synth log); ~half a day. **[VERIFY ON WINDOWS]**

### 2.2 [HIGH — report quality] Timing is not met; report a met constraint

**Observed.** `timing.txt:141-144`: WNS −1.393 ns, 390 failing endpoints,
"Timing constraints are not met." README and DESIGN.md derive "fmax ≈ 88 MHz"
from `1/(10 ns + 1.39 ns)`.

**Why it matters.** "fmax ≈ 88 MHz" extrapolated from a *failed* 100 MHz run is
an estimate, not a measurement; P&R effort and the tool's behaviour change when
the constraint is achievable. A report that says "constraints met at 80 MHz"
is stronger than one that says "constraints not met at 100 MHz, we think 88".

**Action.**
1. After 2.1, set `create_clock -period 12.500` in `vivado/constraints.xdc`
   (80 MHz) and re-run `--impl`. If WNS ≥ 0, that is the reported operating
   point. If it still fails, step to 13.3 ns (75 MHz).
2. Keep the 10 ns run as a second row ("target 100 MHz: not met, WNS x") so the
   narrative "here is the gap and here is why" survives.
3. Add the two constraint-hygiene lines the report flags
   (`timing.txt:89,96`: 2 inputs and 361 outputs without delay constraints):
   `set_input_delay 0 -clock clk [all_inputs]` /
   `set_output_delay 0 -clock clk [all_outputs]` (or `set_false_path` on the
   trace/perf ports, which are observation-only). This removes the "HIGH"
   warnings from `check_timing`.
4. Then, with the schedule slack, attempt the fixes already listed in §11.5:
   - (a) precompute the `rs == rd` match bits in ID (they are known a cycle
     early) — removes the fwd-select decode from the path;
   - (b) pin the regfile to distributed RAM (from 2.1) — removes the BRAM setup
     time (0.566 ns, `timing.txt:274-275`) and the absorbed flush logic;
   - (c) the base machine's own bottleneck (DMEM → lane-extend → WB mux → fwd
     mux) is addressed by moving lane extension after the MEM/WB register
     (needs the MEM/WB register to carry `addr[1:0]` and `funct3`, and the
     load data to become a MEM/WB field — a small datapath change, trace
     format unchanged).
   Each is a behaviour-preserving change; the full regression must stay
   trace-exact at all four parameter combinations afterwards.

**Acceptance.** A committed `timing.txt` whose Design Timing Summary says
"All user specified timing constraints are met" at the reported clock;
DESIGN.md §11.5 and README quote that clock as fmax; `check_timing` shows
0 unconstrained ports.

**Routing.** 1–3 `sonnet-worker` (mechanical); 4 `opus-engineer` (touches
forwarding/hazard/WB paths). **[VERIFY ON WINDOWS]**

### 2.3 [MEDIUM — demo] No waveform artefacts exist

**Observed.** CLAUDE.md's layout lists `sim/ # run.ps1, waveform configs`.
`sim/` contains only `run.ps1` and `run.sh`. No `.wcfg`, no `.wdb`, no
screenshots anywhere in the repo or docs. `sim/run.sh --wave` and
`run.ps1`'s equivalent already produce a `.wdb` (`run.sh:156-158,179-181`).

**Why it matters.** The course task says "use the simulation tools to show the
function and performance". A self-checking PASS line proves function to an
engineer; a lecturer at a demo expects to *see* a forward, a stall and a flush
in a waveform. This is the single most visible gap for Sep 17.

**Action.**
1. Record three `.wdb` files with `--wave`:
   - `asm/hazard/mixed` (forwarding + load-use + flush in one stream),
   - `asm/prog/irq_demo` with `+IRQ_AT1=200` (trap entry, mepc, mret),
   - `asm/prog/bpred` at `BHT_ENABLE=1` vs `0` (predicted-taken redirect).
2. In the Vivado GUI, build one `.wcfg` per program with a curated signal list
   (`pc_q`, `if_id_pc`, `ex_pc`, `fwd_a/b/c`, `stall`, `flush_if/id`,
   `branch_cond`, `br_redirect`, `mstatus_mie`, `mepc`, `trace_valid`,
   `trace_pc`), grouped and radix-set. Commit the `.wcfg` files under `sim/wave/`
   (they are small XML; `.wdb` stays ignored per `.gitignore`).
3. Export PNG screenshots of the three key moments into `docs/img/` and
   reference them from DESIGN.md §6.1, §6.2, §6.3 and §8.3 next to the ASCII
   timing diagrams that are already there.
4. Write `docs/DEMO.md`: the exact command sequence for the live demo
   (regression → one program with trace diff → CPI fwd on/off → BHT on/off →
   irq_demo → open `.wcfg`), with expected output lines, so the demo is
   reproducible under pressure.

**Acceptance.** `sim/wave/*.wcfg` committed; three PNGs in `docs/img/`
referenced from DESIGN.md; `docs/DEMO.md` runs top to bottom on the Windows
machine in under 10 minutes.

**Routing.** GUI work is Kantaphon's; `sonnet-worker` for `DEMO.md`.

### 2.4 [MEDIUM — regression speed] Every program re-runs xvlog + xelab

**Observed.** `sim/run.sh:125-169` compiles all of `rtl/*.v` and elaborates a
fresh snapshot on every invocation; `tools/run_tests.py:174` calls `run.sh`
once per program. README quotes ~6.5 min for the 46-program insn suite;
DESIGN.md §10.9 says 5–10 s per launch, most of it compile/elab.

**Why it matters.** The full matrix (insn + hazard + prog + bringup, × 4
parameter combinations, plus irq runs) is ~70 programs × 4 ≈ 280 launches ≈
30–45 min. That discourages re-running the whole matrix after each small
change in 2.2(4), which is exactly when it must be re-run.

**Action.** Add a `--reuse-snapshot` mode to `run.sh`/`run.ps1` (or a new
`sim/run_batch.sh`) that runs xvlog/xelab once per (`tb`, generics) pair and
then invokes `xsim <snapshot> -f xsim_args.f` per program. `tb_program` already
takes everything it needs via plusargs (`tb_program.v:12-23`), so no testbench
change is needed. `run_tests.py` groups programs by `(fwd, bht)` and calls the
batch entry point. Keep the existing one-shot path as the default so nothing
else changes.

**Acceptance.** `python tools/run_tests.py --dir asm/insn` completes in
< 2 min with identical PASS/FAIL and PERF output.

**Routing.** `sonnet-worker`, ~2 h. **[VERIFY ON WINDOWS]**

### 2.5 [MEDIUM — deliverable risk] The project-mode fallback is untested and incomplete

**Observed.** `vivado/create_project.tcl` is the repo's answer to the
"Vivado 2019.2?" question (PROJECT-REQUIREMENTS §2, §5): the portable
alternative to a committed `.xpr`. But:
- `create_project.tcl:59` globs only `$repo_root/asm/*.hex`, i.e. just
  `smoke.hex`. `asm/insn/`, `asm/hazard/`, `asm/prog/`, `tb/bringup/` and
  `tb/vectors/*.hex` are not added, so project-mode simulation of
  `tb_program`, `tb_imm_gen`, `tb_control` or `tb_dmem` would fail on
  `$readmemh`.
- The script has never been run (no mention in README, git log, or DESIGN.md;
  README's quick start uses only the non-project flow).
- `tb_program` loads the image hierarchically from a path relative to the
  simulator's working directory (`tb_program.v:24-27`), which differs between
  the shadow-dir batch flow and project mode (`vivado/project/rv32i_cpu.sim/…`).

**Why it matters.** If the instructor insists on 2019.2 or wants to open the
design in the GUI, this script is what gets handed over. Handing over an
untested script is a risk with an easy fix.

**Action.**
1. Extend the glob to `asm/**/*.hex`, `asm/**/*.regs`, `asm/**/*.trace`,
   `tb/bringup/*`, `tb/vectors/*`; mark them simulation-only.
2. Set `sim_1`'s top to `tb_smoke` and add
   `set_property -name {xsim.simulate.xsim.more_options} -value {-testplusarg PROG=…}`
   as a documented example.
3. Run it once (`vivado -mode batch -source vivado/create_project.tcl`) from
   an ASCII path, launch `tb_smoke` in the GUI, confirm PASS. Note that the
   generated project lands under `vivado/project/` which is git-ignored.
4. Add a "Project mode (GUI / 2019.2 fallback)" section to README.

**Acceptance.** `tb_smoke` and `tb_program +PROG=asm/prog/fib` pass from a
freshly generated project in the GUI; README documents the steps.

**Routing.** `sonnet-worker` for the Tcl; Kantaphon for the GUI check.
**[VERIFY ON WINDOWS]**

### 2.6 [MEDIUM — pending decisions] Open items only Kantaphon can close

| Item | Where | Status | Risk |
|---|---|---|---|
| Midterm report format / length / language | README "Open items" | undecided, due in 3 days | High: DESIGN.md is 1708 lines; it must be *cut*, not written |
| Vivado 2026.1 vs 2019.2 confirmation | PROJECT-REQUIREMENTS §5.1 | pending | Medium: 2.5 mitigates |
| Python ISS instead of Mars4_5 | PROJECT-REQUIREMENTS §5.2 | pending | Medium: DESIGN.md §10.1 already contains the argument |
| Instruction count stated in the report | §3.1 "pick one consistent total" | **Resolved**: 46 = 37 + 9 (DESIGN.md §1.1) | none |
| `ecall`/`ebreak` in the count | §3.1 | **Resolved**: both in; ebreak is halt, not a trap (DESIGN.md §5.5) | none |

**Action.** Send both instructor questions today (a two-line email each; the
arguments are in DESIGN.md §10.1 and PROJECT-REQUIREMENTS §2). Decide the
report format today so the Sep 8–9 writing slot is usable.

**Suggested midterm report skeleton (from DESIGN.md sections).** Target
8–12 pages:
1. Overview + ISA (§1.1–1.2, one table)
2. Datapath block diagram (§5.1 — redraw as a real figure; the ASCII art is
   fine for the doc, not for a report)
3. Control (§3 table, trimmed to the 46 rows and 8 most important columns)
4. Hazards: forwarding rule, load-use, flush (§6.1–6.3 tables + the three
   pipeline diagrams)
5. Bonus design (§8 CSR table, §9.1 FSM + cost table; §9.3 I-cache paragraph)
6. Verification method (§10.1 three tiers, §10.4 mutation table)
7. Results so far (§10.10 table, §11.2 CPI table, §11.3 BHT table)
8. Synthesis (§11.5 — **after 2.1/2.2 are done**)
9. Status vs plan and remaining work (this file's §3)

### 2.7 [LOW — RTL hygiene] Small design cleanups, none affecting correctness

1. **`id_uses_rs1` / `id_uses_rs2` live in `cpu_top.v:261-266`, not in
   `control.v`.** They are decode outputs (which instructions really read rs1/rs2)
   and belong in the decoder so that the generated truth table (§3) is the
   *whole* decode and `tb_control` covers them. Today they are derived from
   opcode compares that duplicate knowledge the decoder already has. Move them
   into `control.v` as two more outputs, add two columns to
   `tools/gen_control_table.py`'s `CONTROL` dictionary, regenerate, and let
   `tb_control` check them. Mechanical; `sonnet-worker`; regression must stay
   identical (cycle counts included, since these gate the interlock).

2. **Illegal instructions execute as NOPs** (DESIGN.md §3, `control.v` zeroes
   the control word; `cpu_top.v:40-42`). An illegal-instruction trap
   (`mcause = 2`, `mepc = faulting PC`, same path as `ecall`) is ~10 lines in
   `cpu_top` (OR `ex_valid & ex_illegal` into `trap_taken`, pick the cause) plus
   the matching rule in `iss.py` (currently exit code 3) and a per-insn test
   `asm/insn/illegal.s`. It makes the CSR bonus look complete and it is the
   natural answer to "what happens on a bad opcode?" in the Q&A. Optional;
   `opus-engineer` because the ISS/trace contract changes.

3. **BHT index `pc[7:2]`** (`bht.v:72-73`) covers a 256-byte window; `bpred.s`
   and `bloop.s` are larger than 1 KB, so distinct branches alias. The spec
   chose this index (PROJECT-REQUIREMENTS §3.4), so keep it, but say in the
   report that it is a spec parameter and quantify the effect (DESIGN.md §9.1
   already does for `asm/insn`). A one-line experiment — `pc[9:4]` or
   `pc[8:3]`, or 256 entries with `pc[9:2]` — reported as a sensitivity table
   would be a cheap, good-looking addition. `sonnet-worker`.

4. **`mscratch` is absent** (DESIGN.md §8). The ISR in `irq_demo.s` therefore
   saves registers on the stack, which is fine for the demo but means the
   handler is not re-entrant-safe if `sp` is corrupt. Not required by the spec
   (§3.4 explicitly drops mscratch). Mention as a known simplification; do not
   implement.

5. **`csr_rdata` gated by `csr_en`** (`csr.v:116`). Harmless, but it puts a
   32-bit AND on the CSR read path for no architectural reason; the WB mux
   already selects by `wb_sel`. Leave it unless it appears in a timing path.

6. **Testbench irq model vs ISS irq model differ by design** (level held vs
   one-shot sample; `tb_program.v:107-119`). Documented, and the alignment
   method in §9.2 handles it. Keep, but the report should state it in one
   sentence so an examiner does not think it is an inconsistency.

### 2.8 [LOW — repo hygiene]

- `README.md` and DESIGN.md §11.5 must be updated together with 2.1/2.2; add
  a `python tools/gen_control_table.py --check`-style consistency check for the
  numbers in README (or simply a checklist line in `docs/DEMO.md`).
- `docs/DESIGN-evaluation-opus.md` (the evaluation of the *original* plan) is
  now historical. Keep it, but add a one-line header pointing to DESIGN.md as
  the current document, so nobody quotes its "65–70 % complete" verdict.
- `CLAUDE.md`'s layout block still lists `sim/ # run.ps1, waveform configs`
  and `vivado/ # create_project.tcl, synthesis reports`; after 2.3 add
  `sim/wave/` there.
- `.claude/agents/*.md` and this file are fine to keep in the repo, but if the
  repo is handed to the instructor consider whether the orchestration files
  should be present; they are harmless but are not project content.
- No CI. Not required for a course project; the batch driver + exit codes
  already give the same guarantee when run manually.

---

## 3. Proposed plan, Sep 7 → Sep 17

The spec timeline had bonus work through Sep 15. All of that is done, so the
remaining ten days can be spent on the items above and on the deliverables.
The feature freeze (end of Sep 15) still applies to 2.2(4) and 2.7(2).

| Date | Work | Owner |
|---|---|---|
| **Sep 7 (today)** | Send both instructor questions (2.6). Decide report format. Start 2.1 (ram_style attributes + re-synth) and 2.2(1–3) (met-constraint run). | Kantaphon; opus-engineer |
| Sep 8 | Finish 2.1/2.2: rewrite DESIGN.md §11.5 + README from the new reports. Record `.wdb`s for 2.3. Draft midterm report §1–§6 from DESIGN.md. | opus-engineer; Kantaphon |
| Sep 9 | Midterm report §7–§9, figures (datapath block diagram, three waveform PNGs). Proof-read against the reports. | Kantaphon |
| **Sep 10** | **Submit midterm report.** | Kantaphon |
| Sep 11 | 2.4 (snapshot reuse) so the full matrix runs in minutes. 2.5 (project-mode fallback) and GUI check. | sonnet-worker; Kantaphon |
| Sep 12 | 2.7(1) (move rs-usage into control.v) and 2.7(3) (BHT index sensitivity). Full matrix regression. | sonnet-worker |
| Sep 13–14 | 2.2(4) timing fixes, one at a time, full matrix after each; keep whichever meets the target without breaking trace-exactness. Optionally 2.7(2) illegal trap. | opus-engineer |
| **Sep 15** | **Feature freeze.** Final synth run, final reports committed, README/DESIGN.md numbers reconciled. | orchestrator |
| Sep 16 | `docs/DEMO.md` rehearsal, slides (reuse report figures), performance table, backup screenshots in case the live demo fails. | Kantaphon |
| **Sep 17** | **Presentation + demo.** | Kantaphon |

Risk rule (same spirit as PROJECT-REQUIREMENTS §4): if 2.2(4) has not produced
a met 100 MHz run by end of Sep 14, stop and report the met 80 MHz run from
2.2(1). A clean, documented 80 MHz core with a correct critical-path analysis
is better than a half-applied timing fix.

---

## 4. Summary table

| # | Item | Severity | Effort | Blocks | Verify on Windows |
|---|---|---|---|---|---|
| 2.1 | Synthesis narrative (BRAM = regfile, IMEM pruned) is wrong in DESIGN.md §11.5 | High | ½ day | Midterm §8, final slides | Yes |
| 2.2 | Timing not met; report a met constraint; constraint hygiene; then try fixes | High / Medium | ½ day + 2 days optional | Midterm §8 | Yes |
| 2.3 | No waveform configs / screenshots / demo script | Medium | 1 day | Sep 17 demo, report figures | Yes (GUI) |
| 2.4 | Regression recompiles per program (~6.5 min / 46 programs) | Medium | 2 h | Fast iteration for 2.2(4) | Yes |
| 2.5 | `create_project.tcl` untested; misses `asm/**` fixtures | Medium | 2 h | 2019.2 fallback | Yes |
| 2.6 | Report format + two instructor confirmations pending | Medium | — | Midterm | — |
| 2.7 | RTL hygiene: rs-usage in decoder, illegal trap, BHT index note, mscratch note | Low | ½–1 day | nothing | Yes |
| 2.8 | Doc/repo hygiene | Low | 1 h | nothing | No |

Everything in §1 is done and verified by the committed suites; nothing in §2
is a correctness bug in the CPU. The two high-severity items are about the
*report telling the truth about the synthesis result*, which is fixable in a
day and should be fixed before Sep 10.
