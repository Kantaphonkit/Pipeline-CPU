# RISC-V RV32I 5-stage pipelined CPU (Computer Organization, BIT Y4T1)

Verilog-2001 RV32I pipeline (IF/ID/EX/MEM/WB) with full forwarding, load-use interlock,
branch/trap flush, CSRs + external interrupt, and a 2-bit branch history table.
Verified in Vivado 2026.1 xsim against a self-written Python assembler and golden ISS.
Technical design document: **`docs/DESIGN.md`** (midterm report core). Spec: `PROJECT-REQUIREMENTS.md`.

## Status (2026-09-07)

| Item | State |
|---|---|
| ISA | 46 encodings: 37 core RV32I + ecall/ebreak/csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci/mret |
| Verification | 11 unit testbenches, 46 per-instruction + 9 hazard + 5 program-level + 7 bring-up programs, every program byte-exact commit-trace diff vs ISS at all 4 `FORWARDING`×`BHT_ENABLE` combinations |
| CPI (fib/bsort/bloop avg) | 1.39 forwarding on vs 1.84 off (1.32× speedup) |
| Branch prediction | `bpred` demo 95.5 % accuracy, −14.5 % cycles; `fib` 93.4 %; adversarial `bloop` 49.9 % (+10 % cycles, still correct) |
| Interrupt | 2 external interrupts taken in `irq_demo`, mepc/mcause/MIE/MPIE correct, 0 trace diffs |
| Synthesis (xc7a35tcpg236-1, OOC, post-P&R) | 1461 LUT, 819 FF, 2 BRAM (imem + dmem), regfile in 44 LUTs. Setup **met at 13.5 ns = 74 MHz** (WNS +0.052 ns, 0 failing endpoints); 100 MHz not met (WNS −3.235 ns) |
| Hold | WHS −0.120 ns, but every failing path starts at the `rst` input port — an out-of-context artifact (no BUFG, no PARTPIN). Register-to-register hold is **MET at +0.071 ns**. No internal hold violations |
| I-cache | Not implemented (report-only, DESIGN.md §9.3) |

## Quick start (git-bash on Windows; Vivado 2026.1 at `D:/AMDDesigntools/2026.1/Vivado`)

```bash
python tools/test_tools.py                        # assembler/ISS self-check (4323 checks)
python tools/gen_fixtures.py                      # regenerate .hex/.regs/.trace fixtures from asm/**.s
bash sim/run.sh tb_alu                            # any unit testbench: tb/tb_<name>.v -> PASS/FAIL, exit code
bash sim/run.sh tb_program --plusarg +PROG=asm/prog/fib          # one program, regs + trace diff
python tools/run_tests.py --dir asm/insn                          # a suite (46 programs, ~2.5 min)
python tools/run_tests.py --dir asm/prog --fwd 0 --bht 1 --irq-at 200,500   # parameter sweep + interrupts
bash vivado/synth.sh --impl                       # synthesis + place & route of HEAD -> vivado/reports/
bash vivado/synth.sh --impl --period 13.5          # the constraint the design actually closes at
bash vivado/synth.sh --impl --generic BHT_ENABLE=0 --tag base    # characterise the base machine
```
PowerShell equivalents: `sim/run.ps1`, `vivado/synth.ps1`. `-g NAME=VALUE` passes Verilog
parameters (`FORWARDING`, `BHT_ENABLE`).

## Layout

```
rtl/      19 modules; cpu_top.v is the top (ports in docs/INTERFACES.md §6)
tb/       self-checking testbenches; tb_program.v is the generic program runner; tb/bringup/ hazard-free programs
asm/      insn/ (46 per-instruction), hazard/ (9), prog/ (fib, bsort, bloop, bpred, irq_demo), smoke.s
tools/    asm.py, iss.py, test_tools.py, gen_fixtures.py, gen_imm_vectors.py, gen_control_table.py, run_tests.py
sim/      run.sh / run.ps1 (xvlog -> xelab -> xsim batch flow; --elab-only/--sim-only/--tag reuse one snapshot)
vivado/   synth.sh/.ps1/.tcl, create_project.tcl, constraints.xdc,
          reports/{utilization,timing,clocks,memory,hold,hold_reg2reg}[_<period>ns][_<tag>].txt
docs/     DESIGN.md (design doc), INTERFACES.md (binding contracts between tools/RTL/tb), DESIGN.pdf (original plan)
```

## Things to know before touching the flow

- **Vivado cannot run inside this repo path.** xvlog/xelab/xsim/vivado fail on any working directory
  containing non-ANSI characters (`OneDrive/เอกสาร/`). Both run scripts and the synth scripts
  execute inside an ASCII shadow directory under `%LOCALAPPDATA%` (`pcpu_sim_shadow`, `pcpu_synth`)
  with junctions back to `rtl/`, `tb/`, `asm/`, then copy logs/reports back. Moving the repo to an
  ASCII path makes the workaround unnecessary but nothing depends on it.
- **Synthesis is out-of-context.** `cpu_top` exposes ~360 trace/perf bits, more than the part's
  106 I/O pins, so `synth_design -mode out_of_context` is used to characterise the core.
- **Do not run place-and-route and an xsim regression at the same time.** With other applications
  open this machine ran out of memory and both jobs were killed; an orphaned `vivado.exe` keeps
  running and its reports stay in `%LOCALAPPDATA%\pcpu_synth\`. Run them sequentially.
- **Line endings.** `.gitattributes` forces LF checkout; trace/hex fixtures are compared byte-exact.
- **100 MHz is not met**; the design closes at 13.5 ns (74 MHz). The critical path starts at the DMEM
  block RAM's 2.454 ns clock-to-out and runs load → forward → branch compare → PC enable. Candidate
  fixes are in DESIGN.md §11.5.
- **Memory mapping is forced, not inferred.** `rtl/{imem,dmem}.v` carry `(* ram_style = "block" *)` and
  `rtl/regfile.v` `(* ram_style = "distributed" *)`. Without them Vivado deletes the instruction ROM
  outright and puts the register file in the only BRAM, which makes every synthesis number meaningless.
  `vivado/reports/memory*.txt` records where each array actually landed — check it after any RTL change
  to the memories.
- **Synthesis must use a real program image.** `synth.tcl` defaults `IMEM_INIT` to `asm/prog/bpred.hex`;
  a near-empty image lets the ROM be constant-folded away.
- `asm/prog/bloop.s` was written to *defeat* a 2-bit predictor; `asm/prog/bpred.s` is the demo
  where the predictor wins. Both are intentional (DESIGN.md §11.3).
- `li` expands to `lui`+`addi` (distance-1 RAW), so the "NOP-padded" per-instruction programs still
  need forwarding; the truly hazard-free set is `tb/bringup/`.

## Open items

- Midterm report (Sep 10): format/length/language to decide; content is DESIGN.md §1–§11.
- Instructor confirmations pending: Vivado 2026.1 instead of 2019.2; Python ISS instead of Mars4_5.
- Final presentation + demo Sep 17. Feature freeze end of Sep 15.
