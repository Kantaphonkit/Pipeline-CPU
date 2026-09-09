# Review of the midterm report and presentation draft

Reviewed: `Report/midterm-report.docx`, `Report/presentation-draft.md`,
`PROBLEMO-fixes-applied.md`, and the regenerated `vivado/reports/*.txt`.
Reviewed against: `rtl/*.v`, `docs/DESIGN.md`, `README.md`, git history.
Commit reviewed: `b6e9dd2` ("Add report"), clean tree.
Review date: 2026-09-09. Presentation: 2026-09-10.

Framing agreed with Kantaphon: the midterm presents a **working prototype,
not a finished project**. The review therefore checks two things:
(1) every technical statement must be true of the RTL as it exists, and
(2) every "unfinished" statement must name work that is genuinely still open,
so that neither the repo nor the report contradicts it.

> Scope note. This review was done on a macOS checkout without Vivado. No
> simulation or synthesis was re-run. Every synthesis number below is read from
> the committed report files, which were produced by Vivado on the Windows
> machine. Every RTL statement is checked by reading the Verilog. Nothing in
> this review depends on running a tool, and the "Validate" commands at the end
> run on any machine with Python 3 and git.

---

## 0. Summary

| # | Finding | Severity | Where | Fix effort |
|---|---|---|---|---|
| 1 | CSR instructions described as "complete out of MEM and drain the pipeline" — the RTL does a single-cycle RMW in EX with no drain | **High** | report §3.4; slides Speaker 2 slide 2 | 2 min |
| 2 | "ISR is written with an mepc-advance-by-4 prologue" — true for `ecall` only; the interrupt ISR must not advance mepc | **High** | report §3.4 | 2 min |
| 3 | Predictor said to select the next PC in IF — lookup is in IF, the redirect fires in ID (1 bubble) | Medium | report §2.1 IF row, §6.1; slides Speaker 2 slide 3 | 3 min |
| 4 | Critical path described with lane-extension "in MEM" and a "MEM-to-EX" forward — load data appears in WB, the forward is MEM/WB→EX | Medium | report §5; `docs/DESIGN.md` §11.5 steps 2–3 | 3 min |
| 5 | "Verification sweep in progress" — the repo shows it ran green at all 4 configurations on Sep 7; report §6.2 itself quotes the result | Medium (consistency) | report §4, §4.2, §8, §9; slides S1 slide 4–5, S3 slides 2, 4 | 10 min |
| 6 | "Timing met" — every timing file, including 13.5 ns, prints "Timing constraints are not met" because of the hold flag on `rst` | Low | report §5, §9; slides S2 slide 4 | 2 min |
| 7 | Placeholders: Member A/B/C, date "7 September", "4 × 5 min" with three speakers, misplaced team bullet | Low | report header, §7; slides line 1, line 37 | 5 min |
| 8 | No figures at all in the docx; no diagram slide in the draft | Medium (quality) | both | 1–2 h |
| 9 | Audit files (`PROBLEMO*.md`) and orchestration files committed at repo root | Low (hand-over) | repo | decision |

Findings 1–4 are wrong regardless of framing. Finding 5 is where the
prototype framing must be re-anchored (section 2). Findings 6–9 are polish.

---

## 1. Technical statements that do not match the RTL

### 1.1 CSR hazards — report §3.4, slides Speaker 2 slide 2 (`presentation-draft.md:55`)

**Draft says.**
> "CSR instructions complete out of the MEM stage and drain the pipeline
> behind them, so the architectural CSRs are never observed in a half-updated
> state."

**RTL says.** `rtl/csr.v:5-10` (module header):
> "Lives in the EX stage. Everything is single-cycle: the read value presented
> on csr_rdata is the PRE-write architectural value, and the modified value is
> committed on the same posedge. A CSR instruction and the instruction behind
> it are therefore never in conflict … so no CSR interlock is needed."

`rtl/cpu_top.v:442-464` instantiates `csr` in the EX section with
`csr_we = ex_valid & ex_csr_we & ~trap_taken & ~halt`. There is no drain
signal, no CSR-related stall term in `rtl/hazard_unit.v` (its only stall
inputs are load-use / RAW, lines 110-144), and `docs/DESIGN.md` §6.4
(lines 721-736) is titled "CSR hazards — There are none to interlock."

**Why it matters.** It describes a mechanism that does not exist. One
follow-up question ("how does the drain work?") has no answer in the code.

**Replacement.**
> CSR instructions perform their read-modify-write in the EX stage in a single
> cycle: the value written to rd is the old CSR value, and the new value is
> committed on the same clock edge. An instruction one slot behind reaches EX
> a cycle later and already sees the updated register, so no CSR interlock is
> needed; `csrw mepc` immediately followed by `mret` works for the same reason.
> The register-side source (rs1) goes through the normal EX forwarding path,
> and the CSR read value is selected in EX so that a later consumer of rd
> forwards the CSR value rather than an unused ALU result.

Slide bullet:
> CSR: read-modify-write in EX in one cycle, so the next instruction already
> sees the new value; no interlock, and rs1 forwards like any operand.

### 1.2 mepc advance — report §3.4

**Draft says.**
> "The ISR is written with an mepc-advance-by-4 prologue because mepc holds
> the faulting PC of a synchronous trap; mret restores MIE from MPIE."

**RTL / spec say.** `rtl/csr.v:35-38`:
> "a synchronous trap leaves mepc pointing AT the ecall, so the handler must
> add 4 before mret or it re-traps forever. An external interrupt leaves mepc
> at the not-yet-executed instruction, and the handler must NOT add 4."

`docs/DESIGN.md` §8.2 (lines 886-895) states the same asymmetry and calls it
"the single most common trap-handling bug". The interrupt demo
`asm/prog/irq_demo.s` does not advance mepc; `tb/tb_irq.v` asserts that the
first instruction to retire after `mret` is the one at mepc.

**Why it matters.** As written, a reader concludes the interrupt ISR adds 4,
which would skip an instruction. It is also the best Q&A point the report
has, so it should be stated precisely.

**Replacement.**
> Trap return follows the two RISC-V cases. For a synchronous trap (`ecall`)
> mepc holds the address of the `ecall` itself, so the handler must add 4 to
> mepc before `mret` or the `ecall` re-executes forever. For an external
> interrupt the instruction in EX is squashed before it executes and mepc
> points at it, so the handler must **not** advance mepc; `mret` re-executes
> that instruction. In both cases `mret` restores MIE from MPIE.

### 1.3 Where the predictor acts — report §2.1 (IF row), §6.1; slides S2 slide 3

**Draft says.** §2.1 IF: "BHT lookup and predicted-next-PC select".
§6.1: "The BHT is looked up in IF and steers the predicted next PC".

**RTL says.** `rtl/cpu_top.v:140-154` looks the BHT up with `pc_q` in IF and
carries `pred_state` through `if_id`. The redirect is in ID:
`cpu_top.v:287-291`
```
wire id_pred_taken = if_id_valid & id_branch & if_id_pred_state[1];
assign bht_taken   = id_pred_taken & ~stall & ~ebreak_pending;
assign redirect_id = jal_taken | bht_taken;
```
`docs/DESIGN.md` §9.1 table (lines 1001-1007): Lookup IF, Carry IF/ID,
**Act ID**, Resolve EX. Cost table (lines 1020-1025): correctly predicted
taken costs **1 bubble**, not 0.

**Why it matters.** "Select in IF" implies a zero-cost correct prediction. The
actual design is a direction predictor without a BTB; the 1-bubble cost is
why `bsort` gains nothing and why `bloop` loses.

**Replacement, §2.1 IF row.**
> Instruction fetch from IMEM; BHT lookup indexed by the fetch PC, with the
> 2-bit counter state carried into IF/ID alongside the instruction; PC
> register holds the selected next PC

Add to the ID row after "jal resolved here":
> a branch the carried BHT state predicts taken is redirected here too (same
> 1-bubble path as jal)

**Replacement, §6.1.**
> The BHT is looked up in IF and its counter state travels with the
> instruction; if the instruction decodes as a conditional branch and the
> counter predicts taken, ID redirects the PC to PC + immB at a cost of one
> bubble. The branch resolves in EX; a misprediction in either direction
> triggers the standard 2-bubble flush. A correctly predicted not-taken branch
> costs nothing, so the predictor can only win on branches that are actually
> taken.

### 1.4 Critical-path wording — report §5; `docs/DESIGN.md` §11.5 steps 2–3

**Draft says.** "…through the lane extension, the MEM-to-EX forwarding mux,
and the branch compare…". DESIGN.md §11.5 step 2: "the byte-lane select and
sign/zero extension (2 × LUT6), **still in MEM**"; step 3: "the **MEM → EX**
forwarding mux".

**RTL says.** `rtl/dmem.v` registers the word on the MEM clock edge; the
extension is combinational on the registered value, i.e. during WB
(`docs/DESIGN.md` §5.2 line 376-380: "the load result is valid during WB";
§7 line 814-819). The forward that carries it is the MEM/WB path:
`cpu_top.v:413` `fwd_src_wb = wb_data`, `cpu_top.v:644`
`wb_data = (wbs_wb_sel == WB_MEM) ? dmem_rdata : wbs_res`. The EX/MEM path
deliberately never carries load data (`rtl/forward_unit.v:45-50`).

The timing report agrees: `vivado/reports/timing.txt:204-206` source
`u_dmem/mem_reg/CLKBWRCLK` (the BRAM output, valid after the MEM edge),
destination `u_pc/pc_q_reg[31]/CE`.

**Why it matters.** "Forward from MEM" for a load contradicts the report's own
§3.2, which says the load result "is then delivered by the MEM/WB forwarding
path".

**Replacement (report §5; apply the same to DESIGN.md §11.5 steps 2–3).**
> The critical path is the load-to-branch chain: the DMEM block RAM's
> clock-to-output (2.45 ns, the single largest term), the byte-lane select
> and sign extension of the load result in WB, the MEM/WB-to-EX forwarding
> mux delivering that result to a dependent branch in EX, the branch
> comparator, and the redirect logic into the PC register's enable.

---

## 2. The prototype framing — what is genuinely unfinished

The draft anchors "unfinished" on the verification sweep. The repo does not
support that anchor:

| Draft claim | Repo evidence against it |
|---|---|
| §4.2: "46/46 PASS with forwarding on; full BHT on/off sweep in progress" | `docs/DESIGN.md` §10.10 (line 1533): "Program suites were run at all four FORWARDING × BHT_ENABLE combinations"; `README.md` status row: "every program byte-exact … at all 4 combinations"; commit `c958efe` (Sep 7): "all suites trace-exact at 4 FORWARDING x BHT combos" |
| §4.2: "Program-level diff tests … full suite in progress" | report §6.2 itself: "The interrupt demo is diff-tested against the golden ISS (0 differing trace lines)" |
| §8 / S1 slide 5: "if the interrupt bonus is not fully green by Sep 14, it is cut" | S2 slide 3 on the same deck: "Interrupts … Directed interrupt test passes"; `tb/tb_irq.v` 21 assertions PASS at both forwarding and both BHT settings (DESIGN.md §9.2) |

What **is** still open, and can carry the framing honestly:

1. **Two RTL timing fixes are planned** (`docs/DESIGN.md` §11.5, "The 100 MHz
   target is not met", fixes 1 and 2; `PROBLEMO-fixes-applied.md` "Not fixed
   (deliberately): 2.2 step 4 RTL timing surgery"). Fix 1 (registering the
   load lane-extension) can change load latency, hence the load-use stall
   count, hence CPI. **Every number in the report is therefore preliminary.**
2. **The full regression must be re-run** after those fixes. That is a
   genuine "final verification pass", not the first one.
3. **Final synthesis** after the feature freeze (S2 slide 4 already says this).
4. **Waveform captures, demo script, slides** (PROBLEMO 2.3, not started).
5. **Instructor confirmations** (Vivado 2026.1; Python ISS) — status unknown
   at review time; check before presenting.

### 2.1 Replacement wording for the framing passages

**§4 opening.** Old: "Verification is member C's workstream and is in progress
at the midterm date."
> Verification has been run end-to-end once against the current RTL and is
> green. Because two timing fixes are still planned in the RTL, the same
> regression will be re-run as the final acceptance pass after the feature
> freeze, and the numbers in this report are preliminary until then.

**§4.2 rows.**
> Per-instruction (46): 46/46 PASS at all four forwarding × BHT
> configurations on the current RTL
> Hazard (9): 9/9 PASS at all four configurations
> Program-level: 5/5 programs trace-exact against the ISS at all four
> configurations; the interrupt demo is aligned to the RTL's measured trap
> points

**§5 opening.** Old: "These are early measurements … taken during the
verification runs."
> These are measurements on the current prototype RTL. They will be
> re-measured after the planned timing fixes, one of which may change load
> latency and therefore CPI.

**§8 risk rule and S1 slide 5.** Old: interrupt cut rule.
> Interrupts were green on Sep 7, so the interrupt cut rule was never
> exercised. The live risk rule is now the timing work: if the RTL timing
> fixes do not close cleanly by end of Sep 14, we freeze on the current
> 74 MHz build, whose results are already verified, rather than ship an
> untested faster one.

**§9 status rows.**
> Verification: green at all four configurations on the current RTL; final
> regression after the timing fixes
> Bonus interrupts: implemented, directed test and ISS diff both passing;
> final regression pending

**S1 slide 4 NEXT.** Replace "Verification sweep (forwarding × BHT on/off)
and consolidation" with "Timing fixes, final regression, final synthesis, demo
packaging".

**S3 slide 2** (`presentation-draft.md:79-80`).
> Per-instruction 46/46, hazard 9/9, program-level 5/5, all trace-exact
> against the ISS at every forwarding × BHT configuration on the current RTL.

**S3 slide 4** (`presentation-draft.md:88`).
> Re-run the full regression after the timing fixes, lock the final numbers,
> write the performance chapter, build the demo.

---

## 3. Polish items

### 3.1 "Timing met" wording — report §5, §9; S2 slide 4 (`presentation-draft.md:63`)

`vivado/reports/timing_13.5ns.txt:141` shows WNS +0.052, TNS 0, 0 failing
setup endpoints, **but WHS −0.120 with 483 failing hold endpoints**, and
line 144 prints "Timing constraints are not met." `hold_13.5ns.txt:15-18`
shows every listed hold path starts at the `rst` port;
`hold_reg2reg_13.5ns.txt:15` shows register-to-register hold MET at +0.112.
README and DESIGN.md §11.5 already explain this as an out-of-context artefact
(no BUFG modelled; Vivado's own `[Timing 38-242]` / `[Route 35-198]`
warnings).

Replace "closes timing at 74 MHz" with:
> The design closes **setup** timing at a 13.5 ns period, i.e. 74 MHz
> (WNS +0.052 ns, zero failing endpoints). Register-to-register hold is met at
> every constraint point; the only hold flags in the report are paths from the
> `rst` input port, an artefact of out-of-context synthesis where no clock
> buffer is modelled.

### 3.2 Placeholders

- Report header: "Member A (Design), Member B (Coding), Member C (Testing)" →
  real names; also §7 table.
- Report header: "Date: 7 September 2026" → 10 September 2026.
- `presentation-draft.md:1`: "4 × 5 min" → "3 × 5 min".
- `presentation-draft.md:37`: the "Team: one designer, one coder, one tester…"
  bullet sits under "Slide 4: Status"; move to slide 1 or slide 5.

### 3.3 Figures

The docx contains no images (checked: `word/media/` is empty). The deck has
no diagram slide. Minimum set:

| Slide | Figure | Source to redraw from |
|---|---|---|
| S1 | datapath block diagram | `docs/DESIGN.md` §5.1 (ASCII) |
| S2 | three pipeline timing diagrams: EX/MEM forward, load-use stall, taken-branch flush | `docs/DESIGN.md` §6.1 (lines 562-572), §6.2 (597-606), §6.3 (637-647) |
| S3 | bar chart: cycles fwd on/off (fib, bsort, bloop) and BHT on/off (fib, bpred, bloop) | `docs/DESIGN.md` §11.2, §11.3 |
| S3 | one waveform screenshot (load-use stall or branch flush) | Windows: `bash sim/run.sh tb_program --plusarg +PROG=asm/hazard/load_use --wave`, open the `.wdb`, show `stall`, `flush_id`, `pc_q`, `fwd_a` |
| S3 | screenshot of the `run_tests.py` summary table | Windows: `python tools/run_tests.py --dir asm/prog` |

### 3.4 Repository hand-over

`PROBLEMO.md` (commit `5dd66d3`) and `PROBLEMO-fixes-applied.md` (commit
`b6e9dd2`) are at the repo root; the second records an internal audit
argument. `CLAUDE.md` and `.claude/agents/` describe the orchestration
set-up. Decide whether these ship if the repo is handed to the instructor;
if not, move the audit files to `docs/audit/` or drop them from the
submission copy. Also: `PROBLEMO-fixes-applied.md:4` says PROBLEMO.md was
"not committed"; it was (`5dd66d3`).

---

## 4. Statements checked and found correct

So the reviewer can see what was verified, not only what was wrong:

| Statement | Checked against |
|---|---|
| 46 encodings = 37 core + 9 system | DESIGN.md §1.2; `asm/insn/` has 46 programs |
| EX/MEM forwarding beats MEM/WB; x0 never forwarded; store data forwarded | `rtl/forward_unit.v:80-95` |
| 1-cycle load-use stall, bubble into ID/EX, served by MEM/WB forward | `rtl/hazard_unit.v:116-125`, DESIGN.md §6.2 |
| jal in ID (1 bubble); branch/jalr in EX (2 bubbles); traps and mret reuse the flush | `cpu_top.v:289, 490-501`; `hazard_unit.v:147-148` |
| Flushed instructions never write and are never counted | DESIGN.md §5.3, §6.3; `cpu_top.v:646-649` |
| BHT: 64 entries, 2-bit, indexed PC[7:2], off = bit-for-bit base machine | `rtl/bht.v:67-80`; DESIGN.md §9.1 "BHT_ENABLE = 0 … reproduces the static machine's cycle counts exactly" |
| CSRs: mstatus MIE/MPIE, mie, mtvec direct, mepc, mcause; interrupt held while MIE = 0 | `rtl/csr.v:12-19, 130`; DESIGN.md §8.3 |
| CPI 1.387 vs 1.837, 1.32×; per-program 1.65× / 1.38× / 1.22× | DESIGN.md §11.2 table |
| BHT 95.5 % on bpred, −14.5 % cycles; fib 93.4 %; bloop 49.9 %, +10 % | DESIGN.md §11.3 table |
| 1,461 LUT, 819 FF, 2 BRAM; 74 MHz setup-met; 80 MHz does not close (−0.755) | `utilization.txt:35,40,106`; `timing_13.5ns.txt:141`; `timing_12.5ns.txt:141` |
| IMEM and DMEM in `RAMB36E1`, regfile in 44 LUTs | `vivado/reports/memory.txt`; `utilization.txt:37` |
| Register-to-register hold met | `hold_reg2reg*.txt:15` (+0.071 / +0.112 / +0.119) |
| The 88 MHz figure was measured on a netlist with no IMEM | previous `timing.txt` (commit `62d5413`) endpoint `regs_reg_r1_0_31_0_5_i_7` = regfile in the only BRAM; PROBLEMO.md §2.1; `PROBLEMO-fixes-applied.md` Fix 1 |
| I-cache designed only; 2 KB direct-mapped; ~99 % hit rate would prove nothing | DESIGN.md §9.3 |

---

## 5. Validate this review

Run from the repo root. Each command should print what the note says.

```bash
# 1. CSR RMW is single-cycle in EX, no interlock (finding 1.1)
sed -n '5,10p' rtl/csr.v
grep -n "csr" rtl/hazard_unit.v            # expect: one comment line only (line 28), no stall term
grep -n "^### 6.4" -A3 docs/DESIGN.md      # "There are none to interlock."

# 2. mepc rule differs for ecall vs interrupt (finding 1.2)
sed -n '35,38p' rtl/csr.v

# 3. BHT redirect happens in ID (finding 1.3)
sed -n '287,291p' rtl/cpu_top.v
grep -n "| Act | ID |" docs/DESIGN.md

# 4. Load data is forwarded from WB, never from EX/MEM (finding 1.4)
sed -n '413p;644p' rtl/cpu_top.v
sed -n '45,50p' rtl/forward_unit.v
sed -n '204,206p' vivado/reports/timing.txt

# 5. Sweep already ran at all four configurations (finding 2)
grep -n "all four" docs/DESIGN.md | head -3
git log --oneline | grep "4 FORWARDING x BHT"
grep -n "at all 4" README.md

# 6. 13.5 ns run: setup met, hold flag on rst only (finding 3.1)
sed -n '141p;144p' vivado/reports/timing_13.5ns.txt
sed -n '15,18p' vivado/reports/hold_13.5ns.txt
sed -n '15p' vivado/reports/hold_reg2reg_13.5ns.txt

# 7. The draft still contains the wrong phrases (all should return matches
#    BEFORE the fix and none AFTER)
grep -n "drain the pipeline\|4 × 5 min\|46/46 PASS with forwarding on" Report/presentation-draft.md
python3 - <<'EOF'
import zipfile, re
x = zipfile.ZipFile('Report/midterm-report.docx').read('word/document.xml').decode()
text = ''.join(re.findall(r'<w:t[^>]*>(.*?)</w:t>', x, flags=re.S))
for bad in ["drain the pipeline", "mepc-advance-by-4 prologue",
            "predicted-next-PC select", "steers the predicted next PC",
            "MEM-to-EX forwarding", "sweep in progress", "Member A",
            "7 September 2026", "closes timing at"]:
    print(("STILL PRESENT " if bad in text else "fixed         ") + bad)
print("images:", [n for n in zipfile.ZipFile('Report/midterm-report.docx').namelist() if n.startswith('word/media')])
EOF
```

Expected after the edits: every line of the Python check prints `fixed`, the
`grep` on the draft prints nothing, and `images:` lists at least one file.
