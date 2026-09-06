# tb/bringup — step-4 bring-up programs

Hand-written, strictly hazard-free RV32I programs used to validate the
step-4 datapath (`rtl/cpu_top.v` with `forward_unit.v` / `hazard_unit.v`
still stubbed out, i.e. no forwarding, no interlock, no flushing).

They live under `tb/` rather than `asm/` because `asm/` is owned by the
per-instruction fixture set; these are testbench material with a single
purpose: prove the bare datapath before the hazard logic exists.

Rules every program here obeys:

* At least **3 NOPs** between any producer and any consumer of its `rd`
  (covers the missing EX/MEM and MEM/WB bypasses; distance 3 is served by
  the register file's WB->ID internal bypass).
* No `li rd, <value outside 12 signed bits>` and no `la` — those expand to
  `lui` + `addi` with an unavoidable distance-1 RAW.  Where a 32-bit
  constant or an address is needed the two halves are written out with
  NOPs between them.
* At least **2 NOPs** after every conditional branch, `jalr`, `ecall` and
  `mret` (they resolve in EX = 2 shadow slots) and after every `jal`
  (resolves in ID = 1 shadow slot, padded to 2 for uniformity).

Fixtures (`.hex`, `.regs`, `.trace`) are generated the same way the `asm/`
fixtures are — `tools/asm.py` then `tools/iss.py` — so the golden values
come from the reference model, never from the RTL.

Programs whose control flow never actually redirects (`bu_alu`, `bu_mem`,
`bu_data`, `bu_branch_nt`, `bu_csr`) are checked with the **full commit
trace** comparison.  Programs that do redirect (`bu_branch_t`, `bu_trap`)
are run with `+NOTRACE`: without the flush logic the RTL legitimately
retires the NOPs sitting in the two shadow slots, which the ISS never
executes, so the traces differ by construction until step 5.

| Program | Covers | Trace-checked |
|---|---|---|
| `bu_alu` | all 10 R-type, all 9 I-arith, `lui`, `auipc`, register shift-amount masking | yes |
| `bu_mem` | `sb`/`sh`/`sw`, `lb`/`lbu`/`lh`/`lhu`/`lw`, every byte lane, sign vs. zero extension | yes |
| `bu_data` | DMEM preloaded from `<prog>.data.hex`, then loads and a store | yes |
| `bu_branch_nt` | all 6 conditional branches, every one not taken | yes |
| `bu_csr` | all 6 CSR ops on all 5 CSRs, unimplemented-CSR behaviour, back-to-back CSR RMW | yes |
| `bu_branch_t` | all 6 conditional branches taken, `jal`, `jalr`, a counted backward loop | no (`+NOTRACE`) |
| `bu_trap` | `ecall` trap entry, `mcause`/`mepc`/`MIE`/`MPIE`, handler, `mret` return | no (`+NOTRACE`) |

Run them with:

```
python tools/run_tests.py --dir tb/bringup            # trace-checked set
python tools/run_tests.py --dir tb/bringup --notrace  # register check only
```
