# Proposal conversion — what changed

The deck was written as a progress report. It is now framed as a proposal backed by a
working prototype. Both formats carry the same 20 main slides plus 3 appendix slides:
`rv32i-midterm-deck.html` and `RV32I Pipeline Midterm.pptx`.

---

## 1. Slides added

| Index | Slide | What it supplies |
|---|---|---|
| **2** | Objective and success criteria | The course task verbatim, four delivery commitments, four criteria for judging them, and what is explicitly out of scope |
| **5** | Design choices, and what we ruled out | An eight-row decision table: choice, alternative, reason. The cache cut is argued on measurement grounds |
| **8** | Deliverables, owners, milestones, risk | Seven deliverables each with one owner and a state, the milestone list, and a three-row risk register |

---

## 2. Edits applied

| Index | Slide | Change |
|---|---|---|
| 1 | Title | Key message now opens on intent, not status: *"What we propose to build, why we chose it, and the prototype that already shows it works."* |
| 7 | Status → **What already works** | Rebuilt. The "Still open" and "Route to the final demo" panels are gone, since slide 8 now owns milestones and risk. The six evidence rows are split across two equal panels. New eyebrow, "Feasibility". |
| 14 | Synthesis | Key message reframes 74 MHz as measured feasibility rather than a finished result |
| 17 | Results | Key message now names the suite as the acceptance criterion set on slide 2 |
| 18 | Performance | Key message ties the measurement back to the baseline promise on slide 2 |
| 20 | Close | Title is now *"What we are committing to, and why we can"*. Third panel heading is *"Between here and Sep 17"*. The closing line states that every criterion is already met once. |

The member slides at 3, 9 and 15 were left alone. Division of labour is core proposal
content, and stating it as already delivered is a strength.

**Also fixed:** the pipeline mini-map and the section progress bars in the top-right rail
were too close, and in the PowerPoint file they actually overlapped. They are now
separated by a clear gap in both formats.

---

## 3. Slide index map

Use this if you are following the speaker scripts, which still carry the old numbering.

| Old | New | Slide |
|---|---|---|
| 1 | 1 | Title |
| — | **2** | **Objective and success criteria** |
| 2 | 3 | Design — member work task |
| 3 | 4 | Scope: 46 encodings |
| — | **5** | **Design choices, what we ruled out** |
| 4 | 6 | Datapath |
| 5 | 7 | What already works |
| — | **8** | **Deliverables, owners, milestones, risk** |
| 6 | 9 | Coding — member work task |
| 7 | 10 | Forwarding |
| 8 | 11 | Stall and flush |
| 9 | 12 | Branch prediction |
| 10 | 13 | Interrupts |
| 11 | 14 | Synthesis |
| 12 | 15 | Testing — member work task |
| 13 | 16 | Verification tiers |
| 14 | 17 | Results |
| 15 | 18 | Performance |
| 16 | 19 | Waveform |
| 17 | 20 | Close |
| A1–A3 | A1–A3 | Appendix, unchanged |

---

## 4. Still open — your decisions

**Length.** Twenty main slides is 45 seconds each in a fifteen-minute slot.

| Running order | Slides | Seconds each |
|---|---|---|
| As it stands | 20 | 45 |
| With the cut below | 16 | 56 |

If the slot is tight, move slides 10, 11, 12 and 13 — forwarding, stall and flush, branch
prediction, interrupts — behind the close, next to the appendix. A proposal states the
approach rather than walking every mechanism, and slide 6 already shows the bypasses, the
interlock and the redirects. Bring them back only if asked. Keep slide 14, synthesis, in
the main run; a proposal that already carries a measured fmax is unusually strong.

To move a slide: in PowerPoint drag it below slide 20 in the thumbnail pane; in the HTML
file move the whole `<section>` block and lower `var MAIN = 20` by one per slide moved.

**Speaker scripts.** `speaker-scripts.md` still uses the old numbering and
progress-report wording. It needs a rewrite pass once you decide on the cut above, since
that changes both the running order and the per-slide timings.

**Names.** `[ name ]` still appears on slides 1, 3, 9 and 15.

**Screenshots.** Slide 17 needs the regression console output; slide 19 needs the xsim
waveform. Both slides carry the exact command to run.
