# Evaluation: RISC-V RV32I Pipeline CPU Design Plan

## Verdict

**Not a complete design plan for this course — it is a strong ISA/microarchitecture spec (~70%) bolted to a nearly absent project plan (~20%).**

The RV32I content is genuinely good: the immediate generation is correct (all five formats check out bit-for-bit), the CSR addresses are correct, the module decomposition is sane, and the ISA subset comfortably clears the 16-instruction bar. If the only question were "does this student understand RV32I," the answer is yes.

But as a document to submit in 4 days and execute in 11, it has three blockers:

1. **The toolchain section is fiction on the actual machine.** macOS, Icarus, GTKWave, Spike — none exist here. Section 1 and Section 11 describe an environment that does not exist, and the verification plan (§10) depends entirely on Spike, which is the load-bearing element.
2. **There is no schedule, no scope-cut list, and no risk plan.** With three bonus items, a full RTL restart, and 11 days, the absence of a timeline is the single most dangerous gap.
3. **The control unit — the actual heart of the design — is deferred.** "Full per-instruction truth table generated in control.v … see CLAUDE.md" means the design document does not contain the design.

Everything else below is fixable in a day.

---

## 1. Completeness grade by section

| Section | Grade | Assessment |
|---|---|---|
| ISA subset (§2) | **A−** | Correct encodings, correct formats, right scope. Count errors (below) and missing `fence`, missing CSR zimm format. |
| Datapath (§3) | **B−** | Structurally right, but text-only (no block diagram), self-contradictory on branch resolution stage, silent on memory timing and on the `mepc` return path. |
| Module breakdown (§4) | **B** | Good decomposition. Missing: memory modules (`imem.v`/`dmem.v`), performance counters, trap/CSR-write-port arbitration. |
| Control (§5) | **C** | Signal list is fine; the per-instruction truth table — the content that matters — is deferred to another file. For a design document this is the biggest content hole. |
| Immediates (§6) | **A** | All five expressions verified correct. Best section in the document. |
| Hazards (§7) | **B−** | Right three-hazard structure. Forwarding priority statement is wrong or at best dangerously ambiguous. Missing regfile WB→ID bypass, x0 suppression, store-data forwarding. |
| Bonus (§8) | **B+ as scope / D as plan** | Well-chosen and technically described, but zero effort estimates, zero integration analysis with the hazard unit, no cut order. |
| Build order (§9) | **C** | Sequence is logically clean but schedule-blind, and step 1 (build a whole single-cycle machine first) is the wrong call here. |
| Verification (§10) | **C+** | Right instincts. Golden reference is unavailable, no pass/fail criteria, no coverage matrix, no program-termination mechanism. |
| Performance (§10) | **B** | Correct metric set. But no counter hardware in the module list, no target FPGA part, no baseline for comparison. |
| Deliverables / logistics (§11) | **D** | Wrong OS, wrong tools, no timeline, no report outline, no demo plan, no board decision, no fallback. |

**Overall: ~65–70%.** Excellent as a spec, incomplete as a plan.

---

## 2. What is missing that the course and midterm report will require

**Blocking for the midterm report (4 days):**

- **A timeline with milestones.** Not present in any form. Midterm reports for this kind of course are graded largely on "is this project going to land."
- **A report outline.** Nothing in §11 says what the report contains. You need: block diagram, pipeline stage diagram, per-instruction control table, hazard case table, test results table, current status, remaining plan.
- **Diagrams.** The document has none. A pipeline CPU design doc without a datapath figure will read as incomplete regardless of the prose quality.
- **Golden-reference strategy that works today.** Spike is gone. This must be replaced in the document, not just in your head.

**Blocking for the RTL (technical gaps):**

- **Memory subsystem definition.** Nothing specifies: Harvard vs unified, IMEM/DMEM sizes, address map, whether reads are combinational or 1-cycle synchronous (this directly determines whether MEM works in one stage), `$readmemh` init, little-endian byte-lane selection for `lb/lh/sb/sh`, and misalignment policy (recommend: define as don't-care, document it).
- **Reset strategy.** Sync or async, active level, reset PC value, which pipeline registers clear vs. hold, regfile reset behavior.
- **Program termination / halt.** Your MIPS prototype had a custom halt. RV32I has no halt. Decide now: `ebreak` sets a `done` flag that the testbench watches. Otherwise your testbench cannot know when to check results.
- **Stack pointer / entry convention.** What is `sp` initialized to, where does the program start, where does data live.
- **Trap semantics detail.** `ecall`/`ebreak` are listed in the ISA table but never given behavior. They need the same trap path as interrupts, and they expose the classic `mepc` trap: for a synchronous exception `mepc` holds the faulting PC, so a naive `mret` loops forever unless the ISR advances `mepc` by 4. Decide and document.
- **FPGA target part.** §10 promises fmax and LUT/FF/BRAM numbers. Vivado cannot produce those without a part. Pick one (e.g. `xc7a35tcpg236-1`, Basys 3) even for synthesis-only. Also make an explicit **no-board** decision — the task statement says "use the simulation tools," so simulation + synthesis report is sufficient; state that rather than leaving it open.
- **Performance counter hardware.** §10 says counters, §4 has no counter module. Add `perf_counters.v`: cycles, instructions retired, load-use stalls, flushes, (later) mispredicts.
- **Structural hazards.** §10's stall breakdown lists "structural," but a Harvard design with single-cycle memories has none. Either remove it or state that it only appears on I-cache miss.
- **Risk register and fallback.** One paragraph: "if X slips, I cut Y." Its absence is what makes an 11-day three-bonus plan read as unrealistic.

---

## 3. Toolchain rewrite: recommended verification stack for Windows + Vivado only

**Do not install anything new this week.** No WSL, no Icarus, no Spike, no GNU toolchain. Every hour spent on toolchain installation is an hour not spent on RTL, and xsim already demonstrably works — your MIPS prototype passed in it yesterday.

Recommended three-tier stack:

**Tier 1 — Simulator: Vivado 2026.1 xsim, batch mode.**
`xvlog` → `xelab` → `xsim`, driven from a `run.ps1` that mirrors your existing `run.sh`. Vivado's own waveform viewer replaces GTKWave; dump with `$dumpfile`/`$dumpvars` or xsim's native WDB. This is a one-line change to §1 and costs nothing.

**Tier 2 — Self-checking tests (the pattern you already have working).**
Each assembly test ends with a known register/memory state; the testbench compares against a hardcoded golden vector and prints PASS/FAIL. This is exactly what already works in the MIPS prototype — port the harness, not the RTL. Zero new tooling. This is your midterm evidence.

**Tier 3 — Golden reference: write your own RV32I ISS in Python. This is the Spike replacement.**
Extend `tools/asm.py` into `tools/iss.py`: a per-instruction interpreter over a 32-entry register array and a byte-addressable memory dict. For a 37-instruction RV32I subset this is roughly 250–350 lines and about half a day, and it is *faster* than getting Spike running on Windows. Have it emit a commit trace, one line per retired instruction:

```
<pc> <insn_hex> x<rd>=<value> [mem[<addr>]=<value>]
```

Then have the Verilog testbench `$fwrite` the identical format from the WB stage, and diff the two files. That is a real golden reference, it is defensible in a report (arguably *more* defensible than "I used Spike" — you built the model), and it doubles as your assembler's own test.

**Vivado version portability (2019.2 vs 2026.1).** Two concrete mitigations, both cheap:
- **Never commit a 2026.1 `.xpr`.** A 2026.1 project file will not open in 2019.2. Commit a `create_project.tcl` that builds the project from the RTL file list instead.
- **Stay in plain synthesizable Verilog-2001/SV-2005.** No IP catalog, no block design, no BRAM IP wizard — use a plain `reg [31:0] mem [0:N-1]` with `$readmemh`, which infers BRAM anyway and opens in any version.

With those two rules, version becomes a non-issue whichever way the instructor answers.

---

## 4. Schedule feasibility

**The 8-step build order is not realistic as written. Steps 1–4 are; steps 5–7 (all three bonuses) are not.**

Two changes that recover the schedule:

**(a) Delete step 1. Do not build a single-cycle machine first.** "Correct, then fast" is right pedagogy for someone who has never pipelined a CPU. You pipelined one yesterday. Building a complete single-cycle RV32I first costs ~1.5–2 days for a datapath you will then dismantle. Go straight to 5-stage.

**(b) Reuse the MIPS prototype as scaffolding.** The RTL is not the deliverable, but the *structure* is: hazard-unit topology, forwarding-unit shape, pipeline register conventions, testbench harness, golden-value checker, Python assembler framework, run script, performance counters. That is realistically 40–50% of the non-RTL work already done. Retargeting a working 20-instruction MIPS pipeline to RV32I is a fundamentally different task from starting cold — the new work is decode/control, imm_gen, and the wider ISA.

**Bonus triage — cut the cache.**

| Bonus | Cost | Recommendation |
|---|---|---|
| BHT (2-bit, 64-entry) | ~0.5 day | **Do it.** Cheapest bonus by far, purely additive, mispredict-flush path already exists, and the accuracy counter is an easy demo slide. |
| Interrupt (CSR + mret) | ~1.5 days | **Do it, simplified.** `mtvec`/`mepc`/`mcause`/`mstatus.MIE/MPIE`, `csrrw`/`csrrs`/`csrrwi`, `mret`, external irq taken at an IF/ID boundary. Skip `mtval`, `mscratch`, `mip` bit-granularity, vectored `mtvec`. Highest impressiveness per hour. |
| I-cache (2KB direct-mapped) | ~2+ days | **Cut.** It requires a multi-cycle main-memory model, an IF-stage stall path into the hazard unit, and a line-fill state machine — it is the only bonus that destabilizes a working pipeline. Write it up as "designed, not implemented" with the parameters from §8c and a paragraph of analysis. That still earns design credit at near-zero risk. |

**Realistic schedule:**

| Date | Work |
|---|---|
| Sep 6 (today) | Fix the design doc (toolchain, timeline, control table, memory spec). Retarget assembler to RV32I. Write `iss.py`. Unit-test `imm_gen`, `alu`, `regfile`. |
| Sep 7 | Full decode/control table. Datapath wired, 5 stages, no hazard logic. Straight-line (NOP-padded) tests pass. |
| Sep 8 | Forwarding + load-use stall + branch flush. All per-instruction tests pass. |
| Sep 9 | Fibonacci / bubble sort / branch loop running. CPI counters live. **Write the midterm report.** |
| **Sep 10** | **Midterm report due — submit.** |
| Sep 11–12 | ISS diff-testing at scale, bug fixing. Vivado synthesis run → fmax + utilization. |
| Sep 13 | BHT bonus + accuracy measurement. |
| Sep 14–15 | Interrupt / CSR bonus. **Hard feature freeze end of Sep 15.** |
| Sep 16 | Performance table, slides, demo script, rehearsal. |
| **Sep 17** | **Final presentation + demo.** |

The one rule that protects this: **no new features after Sep 15.** A working 37-instruction pipeline with clean CPI numbers and one bonus demos far better than a broken three-bonus machine.

---

## 5. Next 48 hours

1. **Email the instructor today** — one message, two questions: (a) Vivado 2026.1 acceptable in place of 2019.2? (b) RISC-V RV32I with a self-written reference model in place of Mars4_5, since Mars is MIPS-only? "Not strict" is fine, but you want it in writing before you stake a restart on it. Send it now so the answer arrives before you're committed.
2. **Rewrite §1 and §11 of DESIGN.md** for Windows + Vivado xsim + Python. Delete every mention of macOS, Icarus, GTKWave, and Spike. This is 30 minutes and it is the difference between a plan and a plan that describes your actual machine.
3. **Add a timeline section and a risk/cut section** to the document (the table above, plus "cache is cut if not started by Sep 15").
4. **Write the per-instruction control truth table into §5** — all 37 rows. Do not leave it in CLAUDE.md. This is the section that proves you designed the machine, and writing it out will surface decode bugs before they cost you simulation time.
5. **Retarget `tools/asm.py` to RV32I** and write `tools/iss.py`. Cross-validate them against each other on the immediates.
6. **Write and exhaustively test `imm_gen.v` and `alu.v` standalone** before wiring anything. Your own document says this is where the bugs live — it's right.
7. **Write `run.ps1`** (xvlog/xelab/xsim) and prove the flow end-to-end on a trivial module today, so the toolchain is never in question later.
8. **Decide and write down:** target part, memory sizes and timing, reset scheme, `ebreak`-as-halt. Four decisions, ten minutes, they unblock everything downstream.

---

## 6. Technical errors and questionable choices

**Correct — verified, no action needed:** all five immediate expressions (I/S/B/U/J bit fields and widths check out exactly); all eight CSR addresses (0x300, 0x304, 0x305, 0x340–0x344); `jalr` target `(rs1 + imm) & ~1`; the cache arithmetic (128 × 16 B = 2 KB). Your §6 warning that imm_gen is where beginner bugs live is right, and you got it right.

**Real errors:**

1. **Forwarding priority is stated backwards (or at best ambiguously).** §7 says "MEM→EX takes precedence over EX→EX (newer data)." The instruction in the MEM stage (forwarded from EX/MEM) holds *newer* data than the one in WB (from MEM/WB). The correct rule: **EX/MEM forwarding wins over MEM/WB forwarding**, and MEM/WB only forwards when EX/MEM does not match. Your naming makes it unclear which you meant; the parenthetical justification is wrong either way. Fix the wording before you code it — this produces intermittent wrong-value bugs that are miserable to debug.

2. **Branch resolution stage is self-contradictory.** §3 puts the branch compare and target adder in **ID**; §7 says branches resolve in **EX** with 2 bubbles. Pick EX. Resolving in ID requires a separate ID-stage comparator, new ID forwarding paths, and an extra stall class (ALU→branch = 1 stall, load→branch = 2 stalls) — that is a day you don't have. **Exception:** `jal` is unconditional and its target is known at decode, so resolve `jal` in ID (1 bubble) and conditional branches + `jalr` in EX (2 bubbles). Cheap win, easy to justify in the report.

3. **`t0-t6=saved` is wrong.** `t0`–`t6` are temporaries (caller-saved); `s0`–`s11` are the saved registers. Cosmetic in the RTL, but an instructor will notice it in the report.

4. **"x1 = return address for jal/jalr" is an ABI convention, not architecture.** `jal`/`jalr` write **rd**, whatever rd is. If this sentence becomes hardware, `jal x0, label` (an unconditional jump that discards the link) breaks. Make sure the WB mux writes rd.

5. **System instruction count is wrong.** The row lists ecall, ebreak, mret, csrrw/csrrs/csrrc + i-variants = **9**, not 7. Total is 46 encodings, not 44. The overview also says "~37" while the table says 44 — pick one number and be consistent; the grader will count.

6. **"6 immediate formats I/S/B/U/J" lists five.** The genuine sixth is the CSR immediate: `csrrwi/csrrsi/csrrci` use `zimm = inst[19:15]`, **zero-extended, not sign-extended**. imm_gen does not cover it. If you do the interrupt bonus, add it.

7. **Missing: mepc in the PC-select mux.** §3 lists PC+4 / branch / jal / jalr / mtvec — no `mepc` path, so `mret` has nowhere to go. Add it.

8. **Missing: register file WB→ID bypass.** §4 specifies "two async read ports, one sync write" with no mention of what happens when the instruction in WB writes the register that ID is reading in the same cycle. Either write on the negedge or add an internal bypass mux. This is a top-three classic pipeline bug.

9. **Missing: x0 write suppression in the forwarding logic.** The forward unit must not forward when `rd == x0`, and RegWrite to x0 must be a no-op. Another classic.

10. **Missing: shift amount source.** `sll/srl/sra` use only `rs2[4:0]`; `slli/srli/srai` use `imm[4:0]` with `inst[30]` selecting arithmetic. Related trap: **`alu_ctrl` must not decode `inst[30]` for non-shift I-type ops** — otherwise `addi` with a negative immediate (bit 30 set) decodes as `sub`. This bug is nearly universal on first attempts.

11. **Missing: store-data forwarding.** `lw x1, ...` followed by `sw x1, ...` doesn't need a stall — the value can be forwarded into the MEM stage. Not required, but if you don't handle rs2-as-store-data forwarding in EX at all, ordinary `add`/`sw` sequences will store stale data.

12. **Cache design (if you ever build it): the demo won't show anything without a slow main memory.** If IMEM already returns in one cycle, a 1-cycle-hit I-cache has zero measurable benefit — the "hit rate vs uncached baseline" comparison is meaningless. §8c gestures at this ("simple memory-mapped main memory") but doesn't commit to a miss penalty. Also note that a 2 KB cache will hold your entire test program, so hit rate will be ~99% after cold misses; that's fine, but say so rather than presenting it as a result. Reinforces the recommendation to cut it.

13. **`ecall`/`ebreak` have no specified behavior.** Listed in the ISA table, absent from §8a. If they're in your instruction count, they need semantics (mcause 11 and 3 respectively, trap to mtvec) — otherwise drop them from the count and use `ebreak` purely as your testbench halt signal.

14. **`mtvec` mode bits unspecified.** Low two bits select direct vs. vectored. Declare direct mode (bits = 00) and be done.

15. **Performance methodology has no baseline.** "CPI = cycles / instructions" is a number, not a result. Make forwarding a compile-time parameter so you can report CPI with and without it on the same program — that turns one number into an actual performance analysis for a near-zero cost, and it's exactly what "show the performance of your CPU" is asking for.

---

*Note: your global instructions ask me to save useful output to the Obsidian vault, but I have no file tools available in this session, so nothing was written. If you'd like this evaluation captured, re-run in a session with tool access and I'll file it under `01-Projects/` alongside the RISC-V CPU project note.*