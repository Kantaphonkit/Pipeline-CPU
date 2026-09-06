# RV32I 5-Stage Pipelined CPU — Design Document

Computer Organization · BIT Y4T1 · Kantaphon
Living design document; it is the technical core of the midterm report.

The processor is a 32-bit RISC-V RV32I core with a classic in-order five-stage
pipeline (IF → ID → EX → MEM → WB), full forwarding, a load-use interlock,
branch flushing, a simplified M-mode CSR/trap subsystem, and a 2-bit branch
history table. It is written in plain synthesizable Verilog-2001 (no vendor IP,
no block design) and verified in simulation against a Python golden-reference
instruction-set simulator.

---

## 1. Overview and instruction set

### 1.1 Scope

| Property | Value |
|---|---|
| ISA | RISC-V RV32I (user subset) + simplified machine-mode CSRs |
| XLEN | 32 |
| Encodings implemented | **46** (37 core + 9 system) |
| Pipeline | 5 stages, in-order issue, in-order completion |
| Hazard handling | full EX/MEM and MEM/WB forwarding, 1-cycle load-use stall |
| Control flow | `jal` resolved in ID (1 bubble); conditional branches and `jalr` resolved in EX (2 bubbles) |
| Memory | Harvard, 4 KB instruction memory, 4 KB data memory, single-cycle synchronous |
| Privilege | machine mode only, direct-mode trap vector |
| Reset | synchronous, active high, PC ← 0x00000000 |

The instruction count is stated as *46 encodings (37 core + 9 system)*
throughout the report. "Core" is everything except the system group.

### 1.2 The 46 encodings

| Group | Count | Instructions |
|---|---|---|
| R-type | 10 | `add` `sub` `sll` `slt` `sltu` `xor` `srl` `sra` `or` `and` |
| I-arithmetic | 9 | `addi` `slti` `sltiu` `xori` `ori` `andi` `slli` `srli` `srai` |
| Loads | 5 | `lb` `lh` `lw` `lbu` `lhu` |
| Stores | 3 | `sb` `sh` `sw` |
| Branches | 6 | `beq` `bne` `blt` `bge` `bltu` `bgeu` |
| U-type | 2 | `lui` `auipc` |
| Jumps | 2 | `jal` `jalr` |
| System | 9 | `ecall` `ebreak` `csrrw` `csrrs` `csrrc` `csrrwi` `csrrsi` `csrrci` `mret` |

Encodings follow the RISC-V Unprivileged ISA (RV32I) and the Privileged ISA
exactly:

- `ecall` = `0x00000073`, `ebreak` = `0x00100073`, `mret` = `0x30200073`.
- CSR opcode is `0x73`; funct3 selects the operation:
  `001` csrrw, `010` csrrs, `011` csrrc, `101` csrrwi, `110` csrrsi, `111` csrrci.
  The immediate forms take `zimm = inst[19:15]`, zero-extended.
- `fence`, `fence.i` and `wfi` are **not** supported; they decode as illegal.

### 1.3 Instruction formats

| Format | 31:25 | 24:20 | 19:15 | 14:12 | 11:7 | 6:0 | Used by |
|---|---|---|---|---|---|---|---|
| R | funct7 | rs2 | rs1 | funct3 | rd | opcode | R-type |
| I | imm[11:0] | | rs1 | funct3 | rd | opcode | I-arith, loads, `jalr`, CSR ops |
| S | imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode | stores |
| B | imm[12\|10:5] | rs2 | rs1 | funct3 | imm[4:1\|11] | opcode | branches |
| U | imm[31:12] | | | | rd | opcode | `lui`, `auipc` |
| J | imm[20\|10:1\|11\|19:12] | | | | rd | opcode | `jal` |

Register conventions used by the test programs: `x0` is hard-wired zero,
`x1` = `ra`, `x2` = `sp`, `t0`–`t6` are **caller-saved** temporaries, `s0`–`s11`
are callee-saved. `jal`/`jalr` write **rd** — any register; `x1` as the link
register is a software convention, not an architectural rule.

---

## 2. Immediate generation

A single combinational immediate generator (`rtl/imm_gen.v`) produces all six
immediate forms from the raw instruction word, selected by the 3-bit `imm_sel`
signal from the main decoder.

| `imm_sel` | Format | Value |
|---|---|---|
| 0 | I | `{{20{inst[31]}}, inst[31:20]}` |
| 1 | S | `{{20{inst[31]}}, inst[31:25], inst[11:7]}` |
| 2 | B | `{{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}` |
| 3 | U | `{inst[31:12], 12'b0}` |
| 4 | J | `{{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}` |
| 5 | Z | `{27'b0, inst[19:15]}` — CSR `zimm`, **zero**-extended |
| other | — | `32'b0` |

Notes:

- Five of the six are sign-extended; **Z is the only zero-extended immediate**.
- The B and J immediates already contain the implicit `1'b0` least-significant
  bit, i.e. they are byte offsets, not half-word offsets. The upper bits of a
  B/J immediate are scattered across the word so that every immediate bit stays
  in the same physical wire position across formats — this is why RISC-V
  immediate extraction is a fixed wiring pattern with no shifting logic.
- The shift-immediate instructions (`slli`/`srli`/`srai`) reuse the I select.
  This yields the raw sign-extended `inst[31:20]` (so `srai rd,rs1,31` gives
  `0x0000041f`, funct7 bits included). This is harmless because the ALU takes
  only `b[4:0]` as the shift amount.
- `imm_gen` is verified standalone by `tb/tb_imm_gen.v` against vectors whose
  expected values come from the golden-reference simulator, plus hand-computed
  boundary cases for every format (`-2048`, `+2047`, `±4096`, `±1 MiB`).

---

## 3. Control truth table

The main decoder `rtl/control.v` is purely combinational and is a function of
`opcode = inst[6:0]`, `funct3 = inst[14:12]`, `funct7 = inst[31:25]`,
`rs1 = inst[19:15]` (needed only for CSR write suppression) and
`csr_addr = inst[31:20]` (needed only to separate `ecall`/`ebreak`/`mret`).

Signal meanings:

| Signal | Meaning |
|---|---|
| `reg_we` | register file write enable for `rd` (the register file itself drops writes to `x0`) |
| `alu_src_a` (`src_a`) | ALU A operand: 0 = `rs1`, 1 = PC (only `auipc`) |
| `alu_src_b` (`src_b`) | ALU B operand: 0 = `rs2`, 1 = immediate |
| `imm_sel` | immediate format, section 2 |
| `class` (`alu_class`) | ALU decode class: 0 = force ADD, 1 = R-type table, 2 = I-type table, 3 = LUI (pass B) |
| `alu_op` | final 4-bit ALU opcode produced by `alu_ctrl` (section 4) |
| `mem_re` / `mem_we` | data-memory read / write in MEM |
| `wb_sel` | write-back source: 0 = ALU, 1 = memory, 2 = PC+4, 3 = CSR read value |
| `branch` | conditional branch, resolved in EX |
| `jal` | `jal`, resolved in ID |
| `jalr` | `jalr`, resolved in EX |
| `csr_en` | CSR read side (any CSR instruction) |
| `csr_we` | CSR write side actually occurs |
| `csr_imm` | CSR source is `zimm` rather than `rs1` |
| `mret`, `ecall`, `ebreak` | the three fixed system encodings |

Legality constraints enforced by the decoder (anything else raises `illegal`,
which forces every other output to 0 — an illegal instruction executes as a
NOP; the design does not implement an illegal-instruction trap):

- R-type: `funct7` must be `0x00`, or `0x20` with `funct3` = `000` (`sub`) or
  `101` (`sra`).
- Shift immediates: `inst[31:25]` must be `0x00` (`slli`, `srli`) or `0x20`
  (`srai`). **All other I-type instructions ignore `funct7` entirely** — those
  bits are part of the immediate.
- Loads: `funct3` ∈ {000, 001, 010, 100, 101}; stores: {000, 001, 010};
  branches: {000, 001, 100, 101, 110, 111}; `jalr`: `funct3` = 000.
- SYSTEM with `funct3` = 000: `inst[31:20]` must be `0x000` (`ecall`), `0x001`
  (`ebreak`) or `0x302` (`mret`); everything else (including `0x105` = `wfi`)
  is illegal. `funct3` = 100 has no encoding.

The table below is **generated** from the machine-readable truth table in
`tools/gen_control_table.py`, which is also the source of the simulation
vectors that check the RTL — the document and the test cannot drift apart.

<!-- CONTROL-TABLE-BEGIN -->

| Instr | opcode | f3 | funct7 / imm[11:0] | reg_we | src_a | src_b | imm_sel | class | alu_op | mem_re | mem_we | wb_sel | branch | jal | jalr | csr_en | csr_we | csr_imm | mret | ecall | ebreak |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `add` | 0x33 | 000 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sub` | 0x33 | 000 | funct7=0x20 | 1 | 0 | 0 | I(0) | 1 | SUB(1) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sll` | 0x33 | 001 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | SLL(2) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `slt` | 0x33 | 010 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | SLT(3) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sltu` | 0x33 | 011 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | SLTU(4) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `xor` | 0x33 | 100 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | XOR(5) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `srl` | 0x33 | 101 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | SRL(6) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sra` | 0x33 | 101 | funct7=0x20 | 1 | 0 | 0 | I(0) | 1 | SRA(7) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `or` | 0x33 | 110 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | OR(8) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `and` | 0x33 | 111 | funct7=0x00 | 1 | 0 | 0 | I(0) | 1 | AND(9) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `addi` | 0x13 | 000 | -- | 1 | 0 | 1 | I(0) | 2 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `slti` | 0x13 | 010 | -- | 1 | 0 | 1 | I(0) | 2 | SLT(3) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sltiu` | 0x13 | 011 | -- | 1 | 0 | 1 | I(0) | 2 | SLTU(4) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `xori` | 0x13 | 100 | -- | 1 | 0 | 1 | I(0) | 2 | XOR(5) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `ori` | 0x13 | 110 | -- | 1 | 0 | 1 | I(0) | 2 | OR(8) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `andi` | 0x13 | 111 | -- | 1 | 0 | 1 | I(0) | 2 | AND(9) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `slli` | 0x13 | 001 | inst[31:25]=0x00 | 1 | 0 | 1 | I(0) | 2 | SLL(2) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `srli` | 0x13 | 101 | inst[31:25]=0x00 | 1 | 0 | 1 | I(0) | 2 | SRL(6) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `srai` | 0x13 | 101 | inst[31:25]=0x20 | 1 | 0 | 1 | I(0) | 2 | SRA(7) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `lb` | 0x03 | 000 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 1 | 0 | MEM(1) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `lh` | 0x03 | 001 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 1 | 0 | MEM(1) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `lw` | 0x03 | 010 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 1 | 0 | MEM(1) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `lbu` | 0x03 | 100 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 1 | 0 | MEM(1) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `lhu` | 0x03 | 101 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 1 | 0 | MEM(1) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sb` | 0x23 | 000 | -- | 0 | 0 | 1 | S(1) | 0 | ADD(0) | 0 | 1 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sh` | 0x23 | 001 | -- | 0 | 0 | 1 | S(1) | 0 | ADD(0) | 0 | 1 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `sw` | 0x23 | 010 | -- | 0 | 0 | 1 | S(1) | 0 | ADD(0) | 0 | 1 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `beq` | 0x63 | 000 | -- | 0 | 0 | 0 | B(2) | 0 | ADD(0) | 0 | 0 | ALU(0) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `bne` | 0x63 | 001 | -- | 0 | 0 | 0 | B(2) | 0 | ADD(0) | 0 | 0 | ALU(0) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `blt` | 0x63 | 100 | -- | 0 | 0 | 0 | B(2) | 0 | ADD(0) | 0 | 0 | ALU(0) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `bge` | 0x63 | 101 | -- | 0 | 0 | 0 | B(2) | 0 | ADD(0) | 0 | 0 | ALU(0) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `bltu` | 0x63 | 110 | -- | 0 | 0 | 0 | B(2) | 0 | ADD(0) | 0 | 0 | ALU(0) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `bgeu` | 0x63 | 111 | -- | 0 | 0 | 0 | B(2) | 0 | ADD(0) | 0 | 0 | ALU(0) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `lui` | 0x37 | -- | -- | 1 | 0 | 1 | U(3) | 3 | PASSB(10) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `auipc` | 0x17 | -- | -- | 1 | 1 | 1 | U(3) | 0 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `jal` | 0x6F | -- | -- | 1 | 0 | 1 | J(4) | 0 | ADD(0) | 0 | 0 | PC+4(2) | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `jalr` | 0x67 | 000 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | PC+4(2) | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| `ecall` | 0x73 | -- | inst[31:20]=0x000 | 0 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 |
| `ebreak` | 0x73 | -- | inst[31:20]=0x001 | 0 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 |
| `csrrw` | 0x73 | 001 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | CSR(3) | 0 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 0 |
| `csrrs` | 0x73 | 010 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | CSR(3) | 0 | 0 | 0 | 1 | rs1!=0 | 0 | 0 | 0 | 0 |
| `csrrc` | 0x73 | 011 | -- | 1 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | CSR(3) | 0 | 0 | 0 | 1 | rs1!=0 | 0 | 0 | 0 | 0 |
| `csrrwi` | 0x73 | 101 | -- | 1 | 0 | 1 | Z(5) | 0 | ADD(0) | 0 | 0 | CSR(3) | 0 | 0 | 0 | 1 | 1 | 1 | 0 | 0 | 0 |
| `csrrsi` | 0x73 | 110 | -- | 1 | 0 | 1 | Z(5) | 0 | ADD(0) | 0 | 0 | CSR(3) | 0 | 0 | 0 | 1 | rs1!=0 | 1 | 0 | 0 | 0 |
| `csrrci` | 0x73 | 111 | -- | 1 | 0 | 1 | Z(5) | 0 | ADD(0) | 0 | 0 | CSR(3) | 0 | 0 | 0 | 1 | rs1!=0 | 1 | 0 | 0 | 0 |
| `mret` | 0x73 | -- | inst[31:20]=0x302 | 0 | 0 | 1 | I(0) | 0 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| *illegal* | other | -- | see text | 0 | 0 | 0 | I(0) | 0 | ADD(0) | 0 | 0 | ALU(0) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

<!-- CONTROL-TABLE-END -->

Notes on individual rows:

- `csr_we` for `csrrs`/`csrrc`/`csrrsi`/`csrrci` is conditional: the write side
  is suppressed when the source field `inst[19:15]` is zero (`rs1 = x0` for the
  register forms, `zimm = 0` for the immediate forms), as the ISA requires —
  `csrr rd, csr` must not have a write side effect on a read-only-when-zero CSR.
  `csrrw`/`csrrwi` always write, even with `rd = x0`; conversely `rd = x0` does
  not suppress the write.
- CSR instructions set `reg_we = 1` unconditionally; a `rd = x0` case is dropped
  by the register file, and the commit-trace port separately qualifies with
  `rd != 0`.
- `alu_src_b` is driven by the uniform equation `alu_src_b = ~(R-type | branch)`,
  so the system instructions read `1` even though they never use the ALU B
  operand. It is a don't-care that is pinned to a fixed value so that the
  decoder is a total function of the instruction word and every output bit can
  be compared in simulation.
- Branches use `alu_class = 0`; the ALU result is unused because comparison is
  done by the dedicated `branch_unit` and the target by the branch adder.

---

## 4. ALU and ALU control

### 4.1 ALU operations

`rtl/alu.v` is a purely combinational unit with a 4-bit opcode. `b` is the
already-muxed operand (register or immediate), so `b[4:0]` serves as the shift
amount for both register shifts (`rs2[4:0]`) and immediate shifts (`imm[4:0]`).

| `alu_op` | Name | Result |
|---|---|---|
| 0 | ADD | `a + b` |
| 1 | SUB | `a - b` |
| 2 | SLL | `a << b[4:0]` |
| 3 | SLT | `$signed(a) < $signed(b) ? 1 : 0` |
| 4 | SLTU | `a < b ? 1 : 0` |
| 5 | XOR | `a ^ b` |
| 6 | SRL | `a >> b[4:0]` |
| 7 | SRA | `$signed(a) >>> b[4:0]` |
| 8 | OR | `a \| b` |
| 9 | AND | `a & b` |
| 10 | PASSB | `b` (for `lui`, where `b` is the U immediate) |
| others | — | `32'b0` |

Branch comparisons are **not** computed in the ALU; `branch_unit.v` compares
`rs1`/`rs2` directly, which keeps the branch decision off the ALU's critical
path and lets the ALU be shared by the branch's own (unused) ADD.

### 4.2 Second-level ALU decode

`rtl/alu_ctrl.v` maps `alu_class` (from the main decoder) plus `funct3` and
`inst[30]` onto `alu_op`:

| `alu_class` | Meaning | `alu_op` |
|---|---|---|
| 0 | force ADD — address computation for loads/stores, `auipc`, `jal`, `jalr`, branches, CSR ops, illegal | ADD |
| 1 | R-type | `funct3` table below; `inst[30]` selects SUB for `funct3` = 000 and SRA for `funct3` = 101 |
| 2 | I-type arithmetic | same table, but `inst[30]` is consulted **only** for `funct3` = 101 |
| 3 | LUI | PASSB |

| `funct3` | class 1 (`inst[30]`=0 / 1) | class 2 (`inst[30]`=0 / 1) |
|---|---|---|
| 000 | ADD / SUB | ADD / **ADD** |
| 001 | SLL / — | SLL / — |
| 010 | SLT / — | SLT / — |
| 011 | SLTU / — | SLTU / — |
| 100 | XOR / — | XOR / — |
| 101 | SRL / SRA | SRL / SRA |
| 110 | OR / — | OR / — |
| 111 | AND / — | AND / — |

The bolded entry is the classic decode trap this split exists to avoid:
`addi x1, x0, -1` is `0xfff00093`, whose `inst[30]` is 1. A decoder that
consults `inst[30]` for every I-type operation turns that `addi` into a `sub`
and produces `x1 = 1` instead of `-1`. Class 2 therefore ignores `inst[30]`
for `funct3` = 000, and cells marked "—" cannot occur because the main decoder
already rejects those `funct7` values as illegal — which is why `alu_ctrl`
needs no error state of its own.

---

## 5. Datapath

<!-- TODO(step 4): stage-by-stage datapath description, pipeline register field
lists (IF/ID, ID/EX, EX/MEM, MEM/WB), PC-select mux and its priority order,
block diagram. -->

---

## 6. Hazards and pipeline control

<!-- TODO(step 5): forwarding unit truth table (EX/MEM priority over MEM/WB,
x0 suppression, store-data forwarding), load-use interlock, branch/jump flush
timing diagrams, FORWARDING=0 stall-only mode used for the CPI comparison. -->

---

## 7. Memory subsystem

The core is a Harvard machine: instruction and data memories are separate
arrays, so IF and MEM never contend.

| Memory | Size | Words | Index | Initialisation |
|---|---|---|---|---|
| IMEM | 4 KB | 1024 × 32 bit | `addr[11:2]` | `$readmemh` of the assembled program image |
| DMEM | 4 KB | 1024 × 32 bit | `addr[11:2]` | `$readmemh` of the data image when the program has a `.data` section, else zero-filled |

- Both arrays are declared as `reg [31:0] mem [0:1023]` and initialised with
  `$readmemh`, which keeps the RTL portable across Vivado versions and
  inferable as block RAM. No IP catalog primitives are used.
- Address bits above bit 11 are ignored (the space wraps). Both memories are
  addressed `0x00000000`–`0x00000FFF` in their own space.
- **Instruction memory** is a synchronous read with an enable: the instruction
  word appears in the following cycle, i.e. in ID. The enable is `~stall`;
  holding the PC alone is not sufficient during a stall, because the fetched
  word lives in the memory's output register and the PC has already advanced.
  A separate `if_id_valid` bit lets a flush present a NOP to ID regardless of
  the registered instruction word.
- **Data memory** is synchronous for both read and write, so MEM completes in
  one stage. Byte lanes are handled inside the memory: a write updates the
  selected lanes of `mem[addr[11:2]]` according to `addr[1:0]` and the access
  width; a read registers the word plus `addr[1:0]` and the width/sign
  selector, and the lane select with sign or zero extension is combinational on
  those registered values, so the load result is ready in WB.
- Little-endian: byte 0 occupies bits [7:0]. `lb`/`lh` sign-extend,
  `lbu`/`lhu` zero-extend.
- **Misaligned accesses are architecturally don't-care** in this
  implementation: no trap is raised; the word index is `addr[11:2]` and the
  lane comes from `addr[1:0]`. The reference simulator models the same
  behaviour, so simulation and RTL still agree bit for bit.
- Software conventions: execution starts at PC = 0; the first instructions of
  each test program set `sp` (`x2`) = `0x00001000` (top of DMEM, growing down);
  the data section starts at DMEM address 0. Test programs keep the stack and
  the data region from overlapping.
- `ebreak` is the simulation halt: when it retires, the core raises a sticky
  `done` output and the testbench stops the run. `ebreak` is **not** a trap in
  this design.

---

## 8. CSRs, traps and interrupts

Machine mode only, with the minimum register set needed for a demonstrable
external interrupt. Unimplemented bits read as zero and ignore writes;
unimplemented CSR addresses read zero and ignore writes (in both the RTL and
the reference simulator), which keeps the CSR file to a handful of flip-flops.

| CSR | Address | Implemented bits |
|---|---|---|
| `mstatus` | 0x300 | `MIE` = bit 3, `MPIE` = bit 7 |
| `mie` | 0x304 | `MEIE` = bit 11 |
| `mtvec` | 0x305 | bits [31:2] (BASE); bits [1:0] read 00 — **direct mode only** |
| `mepc` | 0x341 | bits [31:2]; bits [1:0] read 00 |
| `mcause` | 0x342 | all 32 bits; written by hardware on a trap, also software-writable |

`mtval`, `mscratch` and `mip` are designed but not implemented — they are not
needed by the demonstration ISR and would only add register bits.

### 8.1 CSR instruction semantics

For all six CSR instructions the **old** value of the CSR is what is written to
`rd`; the write side uses the source operand `src` = `rs1` value (register
forms) or the zero-extended `zimm` (immediate forms):

| Instruction | New CSR value | Write occurs when |
|---|---|---|
| `csrrw` / `csrrwi` | `src` | always |
| `csrrs` / `csrrsi` | `old \| src` | source field `inst[19:15]` ≠ 0 |
| `csrrc` / `csrrci` | `old & ~src` | source field `inst[19:15]` ≠ 0 |

`rd = x0` never suppresses the write side. The read-modify-write is performed
in the EX stage inside `csr.v`, in a single cycle, and `csr.v` forwards the
freshly written value combinationally, so a CSR read immediately following a
CSR write needs no stall.

### 8.2 Trap semantics

Traps are taken at the **EX stage**, which is where the interrupt is attached
to a valid instruction so that `mepc` is always a real program counter. A trap
flushes the younger instructions exactly like a mispredicted branch.

**External interrupt** (`irq` input, level-sensitive) is taken when
`mstatus.MIE = 1`, `mie.MEIE = 1` and `irq = 1`, at an instruction boundary:

1. the instruction in EX is squashed and **not** retired;
2. `mepc ← PC` of that squashed instruction;
3. `mcause ← 0x8000000B` (machine external interrupt);
4. `MPIE ← MIE`, then `MIE ← 0`;
5. `PC ← mtvec`.

Because the interrupted instruction never executed, the ISR must **not**
advance `mepc` — `mret` re-executes it.

**`ecall`** is a synchronous exception: `mepc ← PC of the ecall`,
`mcause ← 11` (environment call from M-mode), same `MIE`/`MPIE` update,
`PC ← mtvec`. Here `mepc` points at the faulting instruction itself, so the ISR
**must** execute `mepc += 4` before `mret`, otherwise the `ecall` re-executes
and the handler loops forever. This asymmetry between the interrupt case and
the exception case is the single most common trap-handling bug and is called
out explicitly in the report.

**`mret`**: `PC ← mepc`, `MIE ← MPIE`, `MPIE ← 1`. The PC-select mux therefore
has an `mepc` input alongside PC+4, the branch target, the `jal` target, the
`jalr` target and `mtvec`.

`mtvec` is used in **direct mode**: the vector address is `mtvec` with its low
two bits forced to zero; vectored mode is not implemented.

---

## 9. Bonus features

<!-- TODO(step 7): 2-bit saturating-counter BHT (64 entries, indexed PC[7:2]),
its integration with the EX-stage flush path and the prediction-accuracy
counters; interrupt demonstration program; the I-cache section (designed, not
implemented — direct-mapped 128 x 16 B, and why it was cut). -->

---

## 10. Verification

<!-- TODO(step 5-6): three verification tiers (unit testbenches, per-instruction
tests, ISS differential testing), the commit-trace format, the test matrix and
its results. Sections completed so far: imm_gen, alu, regfile unit tests, and
the decode test described below. -->

The decode logic of sections 3 and 4 is verified by `tb/tb_control.v`, which
instantiates `control.v` and `alu_ctrl.v` together and drives them from
machine-generated vectors. Each vector is an instruction word plus the packed
expected value of all nineteen decoded signals. The vectors come from
`tools/gen_control_table.py`: the stimulus words are produced by the project
assembler from ordinary source operands, the expected mnemonic of every word is
confirmed by the reference simulator's decoder, and the expected control values
come from the same dictionary that generates the table in section 3. The suite
covers every one of the 46 encodings with randomised registers and immediates
(including the negative immediates and shift amounts that set `inst[30]`, and
the zero/non-zero CSR source cases), plus a pool of illegal encodings — bad
`funct7` values, unsupported `funct3` values, `wfi`, and unknown opcodes — that
must all decode to `illegal` with every other output zero. A set of
hand-computed golden vectors is checked as well, so a bug in the generator
cannot mask a bug in the RTL.

---

## 11. Performance

<!-- TODO(step 8): cycle counts and CPI for the three benchmark programs with
forwarding on and off, load-use stall / flush / mispredict counter readings,
BHT accuracy, and the Vivado synthesis results (fmax, LUT/FF/BRAM utilisation
for the chosen 7-series part). -->
