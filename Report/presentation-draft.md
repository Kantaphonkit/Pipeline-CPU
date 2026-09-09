# Midterm Presentation Draft — 3 × 5 min

Rough speaker notes. Numbers come from the midterm report and the post-fix synthesis reports. Adjust wording to your own voice.

Framing for every speaker: the story is "the machine is built and running; what's left is measurement and packaging." Lead each section with what is DONE, close with what comes NEXT. Never present the remaining work as design risk — it is execution work on a finished design.

---

## Speaker 1 — Design (group leader, overall project, ~5 min)

### Slide 1: Title
- Pipeline CPU Project — Midterm Progress
- Team: 3 members (Design / Coding / Testing). RISC-V RV32I, Verilog, Vivado 2026.1.
- Team: one designer, one coder, one tester, one owner per deliverable, cross-review by reading.

### Slide 2: Task and scope — DONE
- Course task: pipelined CPU, 16+ instruction subset, simulated function and performance; bonuses for interrupts, cache, branch prediction.
- Ours: 5-stage in-order pipeline (IF/ID/EX/MEM/WB), full forwarding, load-use interlock, EX-stage branch resolution, flush recovery.
- 46 instruction encodings (37 RV32I + 9 system), nearly 3x the 16-instruction minimum. All designed, all implemented, all running.

### Slide 3: Key design decisions (what we already built)
- 5-stage textbook RISC-V datapath with pipeline registers; register file write-through so WB-to-ID same-cycle reads work.
- PC select mux: PC+4, jal target (ID), branch/jalr target (EX), mtvec, mepc.
- Harvard memory: 4 KB IMEM + 4 KB DMEM, single-cycle sync.
- Bonus scope: BHT branch prediction and interrupts implemented; I-cache designed only, cut on purpose (test programs fit in 2 KB, ~99% hit rate would prove nothing).

### Slide 4: Status — what's done vs what's next
DONE (as of Sep 8):
- Design document complete; RTL complete; both implemented bonuses working in simulation
- Machine runs the full 46-encoding instruction set
- Synthesis mapping fixed; setup timing met at 74 MHz (13.5 ns), register-to-register hold met

NEXT (to Sep 17):
- Timing fixes, final regression, final synthesis, demo packaging
- Performance chapter, demo script, slides

### Slide 5: Plan and risk
- Milestones Sep 8–17: timing fixes, full regression + final synthesis, performance chapter, feature freeze Sep 15, demo Sep 17.
- Risk rule: interrupts were green on Sep 7, so the interrupt cut rule was never exercised. The live risk rule is now the timing work: if the RTL timing fixes do not close cleanly by end of Sep 14, we freeze on the current 74 MHz build, whose results are already verified, rather than ship an untested faster one.

---

## Speaker 2 — Coding (~5 min)

### Slide 1: What I built — DONE
- All RTL: 19 Verilog modules, plain synthesizable Verilog-2001. 5 pipeline registers, datapath units, forwarding/hazard/branch units, CSR file, BHT, performance counters, memories, top level. Complete, all running.
- Plus the toolchain: self-written Python assembler and a Python golden-model ISS (Mars4_5 is MIPS-only, can't verify RISC-V).

### Slide 2: Hazard machinery — built and verified per-instruction
- Forwarding: EX/MEM priority over MEM/WB, x0 never forwarded, store rs2 forwarded through EX.
- Load-use: 1-cycle stall, bubble injection, result delivered by MEM/WB forwarding.
- Control: jal in ID (1 bubble); branches and jalr in EX (2 bubbles); traps and mret reuse the same flush. Wrong-path instructions never write and never count as retired.
- CSR: read-modify-write in EX in one cycle, so the next instruction already sees the new value; no interlock, and rs1 forwards like any operand.

### Slide 3: Bonus features — implemented, running
- BHT: 64-entry, 2-bit saturating counters, indexed PC[7:2], looked up in IF. Strictly a performance feature: with BHT_ENABLE off it's bit-for-bit the base pipeline, correctness never depends on it.
- Interrupts: mstatus/mie/mtvec/mepc/mcause, CSR instructions, mret, external irq input. Interrupt while MIE=0 is held pending, not dropped. Directed interrupt test passes.
- A compile-time FORWARDING parameter turns the whole bypass network off for the baseline comparison.

### Slide 4: Synthesis status — done once, one final run next
- DONE: post-fix synthesis closes setup timing at 74 MHz (13.5 ns, WNS +0.052, zero failing endpoints); 1,461 LUTs, 819 FFs, 2 BRAMs. 80 MHz attempt does not close. Register-to-register hold met at every constraint point; the only hold flags are paths from the rst input port, an artefact of out-of-context synthesis with no clock buffer modelled.
- We also caught and fixed a synthesis mapping bug: the first run's 88 MHz was measured on a netlist with no real instruction memory. After pinning memories to block RAM, the honest number is 74 MHz.
- NEXT: one final synthesis run after feature freeze (Sep 11–12); fix-on-fail loop continues with testing.

---

## Speaker 3 — Testing (~5 min)

### Slide 1: Strategy, three tiers — all built and operational
- Tier 1: xsim batch flow (xvlog → xelab → xsim), self-checking testbenches, nonzero exit on fail.
- Tier 2: 11 unit testbenches + 46 per-instruction programs with golden register/memory results.
- Tier 3: golden reference. Python ISS runs the same assembled programs, emits a commit trace; the RTL emits the identical format; files are diffed byte-for-byte.

### Slide 2: Results so far — everything run so far is green
- Unit testbenches: all 11 green (imm_gen 1,865 vectors, ALU 5,072, branch_unit 16,072, BHT 2,600, and so on).
- Assembler-vs-ISS cross-validation: 4,323 checks PASS.
- Per-instruction 46/46, hazard 9/9, program-level 5/5, all trace-exact against the ISS at every forwarding × BHT configuration on the current RTL.

### Slide 3: Performance measured — preliminary numbers already in hand
- CPI with forwarding on vs off, same programs: 1.39 vs 1.84 average, 1.32x speedup (fib 1.65x, bsort 1.38x, bloop 1.22x).
- BHT: 95.5% accuracy on the branch-heavy demo, saves 14.5% of cycles; fib 93.4%.
- Adversarial alternating-branch program: 49.9% accuracy, 10% more cycles. That's the predictor's real limit, and we report it.

### Slide 4: What's next
- Re-run the full regression after the timing fixes, lock the final numbers, write the performance chapter, build the demo.
- On track for Sep 17. Nothing outstanding is new engineering; it is finishing measurement on a machine that already works.

---

## Note for the group leader

The first synthesis run reported 88 MHz, but that number was invalid: the toolchain had folded the instruction memory into logic and put block RAM where the register file belonged, so timing was measured on a netlist with no real IMEM. After pinning the memories with ram_style attributes (IMEM/DMEM to block RAM, regfile to LUT RAM), the honest result is setup timing met at 13.5 ns (74 MHz, WNS +0.052) with register-to-register hold met; the only hold flags are on paths from the rst port, an artefact of out-of-context synthesis with no clock buffer modelled. If asked why the number dropped, explain the mapping fix; finding and fixing it is the stronger story. A final post-feature-freeze run is still scheduled for Sep 11-12.
