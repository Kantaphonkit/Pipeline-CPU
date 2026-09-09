# PROBLEMO Fixes Applied — what was fixed, and what the audit misunderstood

Repo: `Pipeline-CPU` · Fixes executed by Fable (Claude Code, opus) on 2026-09-07, verified by Hermes against the committed reports.
Commits: `7d9f30d` → `7036629` (5 commits). Nothing pushed. Not committed: this file, PROBLEMO.md, PROBLEMO-evaluation.md.

---

## What was fixed

### Fix 1 — PROBLEMO 2.1: memory mapping pinned, synthesis re-measured (2.1 fully done)
`ram_style` attributes on all three arrays; synth now initializes IMEM with a real program (bpred.hex) instead of smoke.hex.
Result: the audit's diagnosis was right, and reality was worse than it claimed — no array was where DESIGN.md said:

| Array | Before | After |
|---|---|---|
| imem 1024×32 | constant-folded into LUT logic, ABSENT from netlist | RAMB36E1 @ u_imem |
| dmem 1024×32 | 512 RAMS64E distributed LUT RAM | RAMB36E1 @ u_dmem, byte-write lanes |
| regfile 32×32 | the design's ONLY RAMB36E1 (wrong) | 12 × RAM32M = 44 LUTs |

Post-route: 2173 → 1461 LUT, 960 → 819 FF, 1 → 2 BRAM. Simulation-neutrality verified: all 5 prog tests byte-exact vs ISS with identical cycle counts.

### Fix 2 — PROBLEMO 2.2 steps 1–3: constraints cleaned, met-constraint point found
check_timing now clean (was 2 inputs + 361 outputs unconstrained). Four measured configs committed (10 / 12.5 / 13.5 ns + base machine). **80 MHz does not close** (WNS −0.755 @ 12.5 ns); the design meets timing at **13.5 ns = 74 MHz** (WNS +0.052, 0 failing endpoints). The old "fmax ≈ 88 MHz" claim is retracted — it was measured on a netlist with no instruction memory.
Hold checked for the first time ever: reg-to-reg hold MET everywhere (+0.071 ns); the −0.120 ns WHS is an OOC artifact on the rst port only, not a real bug.

### Fix 3 — PROBLEMO 2.4: snapshot reuse in the regression
run.sh gains --elab-only/--sim-only; run_tests.py batches per (fwd,bht). asm/insn suite: 346.8 s → 144.2 s (2.4×), output byte-identical (full result table diffed, not just verdicts).

### Fix 4 — PROBLEMO 2.8: docs
DESIGN.md §11.5 rewritten from the new reports (real critical path: DMEM BRAM clock-to-out → lane-extend → MEM→EX forward → branch compare → redirect; the correct mapping cost ~13 MHz vs the fake LUTRAM version — the honest trade). Old evaluation doc marked HISTORICAL. README numbers reconciled, 88 MHz claim removed.

---

## What the audit (PROBLEMO.md) misunderstood or got wrong

1. **2.1 was understated, not just "narrative wrong".** It framed the fix as rewriting a paragraph. In truth every synthesis number (LUT/FF/fmax) was invalid — the netlist had no instruction memory and the one BRAM was the register file. It required a re-measurement, not a rewording. (Its proposed critical-path explanation was also a hypothesis; §11.5 is now written from the actual report.)
2. **2.2's fix was partially unsound.** `set_output_delay 0` on all 361 trace ports would have newly timed observation-only endpoints — the audit proposed exactly that. In practice BOTH were needed and it took measurement to learn: false_path alone doesn't clear check_timing (361 → 360), output_delay alone would distort the critical path. The audit's "80 MHz should close" assumption was also wrong — it doesn't (−0.755 ns).
3. **Hold timing never mentioned.** The audit never asked about WHS/TNS; the fix flow produced the first hold analysis (reg-to-reg met; rst-port WHS is an OOC artifact).
4. **2.7 items are not problems.** mscratch is spec-dropped (audit's own table says so), csr_rdata gating is harmless (audit admits it), the BHT aliasing premise confuses program size with branch spacing, and the illegal-trap + decoder-refactor suggestions are scope creep before the demo. None were done, per decision.
5. **2.5 was only half-diagnosed.** The real blocker it identified (tb_program's relative $readmemh paths in project mode) is not fixed by its proposed bigger glob — deferred until the instructor answers the 2019.2 question, since it's a contingency path.
6. **Missed entirely:** that the trace-laden cpu_top as synth top was the root cause of the unconstrained-port noise (addressed by Fix 2), and that a batch regression and P&R must not run concurrently on this machine (16 GB).

## Not fixed (deliberately)
- 2.2 step 4 RTL timing surgery, 2.7(1), 2.7(2) — skipped per scope decision.
- 2.3 waveforms/.wcfg/PNGs, 2.5 project-mode test, 2.6 instructor emails + report format — need Kantaphon (GUI, decisions).
- Remaining deliverables: midterm report, demo script, datapath block diagram.
