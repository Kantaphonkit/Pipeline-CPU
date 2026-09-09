# DESIGN.md — Errata and Proposed Corrections

Written 2026-09-09, after the REVIEW-midterm.md audit and its independent
re-verification (Claude Code pass). The report (`Report/midterm-report.docx`)
and slide draft (`Report/presentation-draft.md`) have already been corrected;
this file lists the two places where `docs/DESIGN.md` itself still carries a
known error, with the exact old text, the evidence, and the proposed new text.

This file is for audit purposes: verify each claim against the RTL before
accepting the correction. Nothing in this file changes the RTL — every fix is
a documentation-only edit.

---

## Error 1 — Critical-path stage attribution (§11.5, lines 1743–1744)

**Current text (wrong):**

> 2. the byte-lane select and sign/zero extension (2 × LUT6), still in MEM;
> 3. the MEM → EX forwarding mux into the EX operand;

**Why it is wrong.** The DMEM block RAM registers the read data on the MEM
clock edge; the byte-lane select and sign/zero extension are combinational
logic on that *registered* value, i.e. they execute during WB, not MEM.
The forward that carries the load result to a dependent instruction is the
MEM/WB → EX path, not MEM → EX — the EX/MEM path deliberately never carries
load data (the load-use interlock guarantees a consumer never reaches EX
while its load is only as far as MEM).

This is the same error as review finding 1.4, already fixed in the report
and slides; DESIGN.md §11.5 still has the wrong copy.

**Evidence to check:**

- `rtl/dmem.v:62-67` — word, address bits and funct3 registered on the MEM
  clock edge; lines 74-97 do the lane select and extension on the
  registered values.
- `rtl/cpu_top.v:413` — `fwd_src_wb = wb_data`; `cpu_top.v:644` —
  `wb_data = (wbs_wb_sel == WB_MEM) ? dmem_rdata : wbs_res` (two-way WB mux).
- `rtl/forward_unit.v:45-50` — comment: the EX/MEM path never carries load
  data; by the time the consumer reaches EX the load is in WB and the 2'b01
  (MEM/WB) path carries real load data.
- `vivado/reports/timing.txt:204-206` — critical-path source is
  `u_dmem/mem_reg/CLKBWRCLK` (the BRAM output register, valid after the MEM
  edge), destination `u_pc/pc_q_reg[31]/CE`.
- DESIGN.md itself already says the load result is valid during WB at
  §5.2 (lines 376-380) and §7 (lines 814-819) — §11.5 contradicts them.

**Proposed replacement text:**

> 2. the byte-lane select and sign/zero extension (2 × LUT6) of the load
>    result in WB, on the BRAM's registered output;
> 3. the MEM/WB-to-EX forwarding mux delivering that result to a dependent
>    instruction in EX;

---

## Error 2 — tb_irq assertion count (§8, line 1196; §10, line 1547)

**Current text (wrong):**

- Line 1196: "with 21 assertions over the whole trap"
- Line 1547 (verification table row): "| `tb_irq` | 21 assertions | PASS | PASS |"

**Why it is wrong.** `tb/tb_irq.v` contains 22 `check(` call sites, not 21.
The report has already been corrected to 22; DESIGN.md still says 21 in both
places, so the project's own documents disagree with the testbench.

**Evidence to check:**

- `grep -c 'check(' tb/tb_irq.v` → 22
- `grep -o 'check(' tb/tb_irq.v | wc -l` → 22 (both counts agree)

**Proposed replacement text:**

- Line 1196: "with 22 assertions over the whole trap"
- Line 1547: "| `tb_irq` | 22 assertions | PASS | PASS |"

---

## Verification commands

Run from the repo root:

```bash
# Error 1 — confirm the extension is combinational in WB, forward is MEM/WB→EX
sed -n '62,97p' rtl/dmem.v
sed -n '413p;644p' rtl/cpu_top.v
sed -n '45,50p' rtl/forward_unit.v
sed -n '204,206p' vivado/reports/timing.txt

# Error 2 — confirm the assertion count
grep -c 'check(' tb/tb_irq.v        # expect 22

# Confirm the wrong text is still present in DESIGN.md (before the fix)
grep -n "still in MEM\|MEM → EX" docs/DESIGN.md
grep -n "21 assertion" docs/DESIGN.md
```

All checks were executed on 2026-09-09 and the outputs matched the claims
above. After applying the corrections, the two `grep`s in the last block
should return nothing.
