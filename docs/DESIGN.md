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

`rtl/cpu_top.v` wires the five stages together. Every boundary between two
stages is an explicit pipeline-register module (`if_id.v`, `id_ex.v`,
`ex_mem.v`, `mem_wb.v`), each with the same four control inputs — `clk`, `rst`,
`stall` (hold the current contents) and `flush` (overwrite with a bubble) — so
the interlock and flush logic of section 6 plugs in without touching the
datapath.

### 5.1 Block diagram

```
        IF              |        ID             |        EX            |   MEM      |     WB
========================|=======================|======================|============|=============
                        |                       |                      |            |
  +----------------+    |   control.v           |  +--------+          |            |
  |  PC-select mux |    |   alu_ctrl.v          |  | fwd A  |--+       |            |
  |  (5.4)         |    |   imm_gen.v           |  +--------+  |       |            |
  +-------+--------+    |                       |  +--------+  +->+---------+       |
          |             |   regfile.v read      |  | fwd B  |---->|  alu.v  |--+    |
      +---v---+         |   (async, WB->ID      |  +--------+     +---------+  |    |
      | pc.v  |----+    |    internal bypass)   |  +--------+                  |    |
      +-------+    |    |                       |  | fwd C  |--- store data ---|--+ |
          |        |    |   jal target          |  +--------+                  |  | |
      +---v----+   |    |   = IF/ID.pc + immJ   |  branch_unit.v -> taken      |  | |
      | imem.v |   |    |         |             |  csr.v  RMW / trap / mret    |  | |
      | (sync) |   |    |         |             |  branch & jalr targets       |  | |
      +---+----+   |    |         |             |  res = ALU | PC+4 | CSR      |  | |
          |        |    |         |             |         |                    |  | |
   [ IF/ID: pc, valid ] |    [  ID/EX  ]        |    [  EX/MEM  ]              |  | |
   + imem output reg    |                       |                              |  | |
                        |                       |                       +------v--v-+
                        |                       |                       |  dmem.v   |
                        |                       |                       | we/re/addr|
                        |                       |                       |   wdata   |
                        |                       |                       +-----+-----+
                        |                       |                             | rdata
                        |                       |                       [ MEM/WB ]  |
                        |                       |                             |     |
                        |                       |                          +--v-----v--+
                        |                       |                          |  wb mux   |
                        |                       |                          +-----+-----+
                        |                       |                                |
                        |                       |          regfile write  <------+------> trace_* ,
                        |                       |          (x0 suppressed)              retire pulse
          ^             |         ^             |         ^
          |             |         |             |         |
          +-- jal target (ID) ----+             |         |
          +-- trap / mret / branch / jalr target (EX) ----+
```

The instruction word itself is not duplicated into `if_id.v`: `imem.v` is a
synchronous-read memory, so its own output register *is* the instruction half
of the IF/ID boundary. `if_id.v` carries the matching `pc` and `valid` bits and
is clocked by the same enable, and ID substitutes a `nop` (`0x00000013`) for the
instruction word whenever `valid` is 0. Registering the instruction a second
time would add a wasted cycle of fetch latency.

### 5.2 Stage by stage

**IF** — the PC register (`pc.v`) drives `imem.v`, whose registered output is
read by ID on the next cycle. The PC-select mux (section 5.4) chooses the next
PC. The fetch enable is `~halt & (redirect | ~stall)`: a redirect always
re-fetches, even during a stall, because the stalling instruction is being
killed anyway.

**ID** — `control.v` produces the full control word from the instruction,
`alu_ctrl.v` reduces `alu_class`/`funct3`/`inst[30]` to a 4-bit ALU opcode, and
`imm_gen.v` builds the immediate. The register file is read combinationally
with the mandatory WB→ID internal bypass, so an instruction can read a register
that the instruction three slots ahead of it is writing this very cycle. `jal`
resolves here: its target is `PC + immJ`, known without any register value, so
it costs a single shadow slot instead of two.

**EX** — three forwarding muxes select the ALU A operand, the ALU B operand and
the store data. `alu.v` computes the result; `branch_unit.v` evaluates the
branch condition from the *forwarded* register values rather than from the ALU,
keeping the compare off the ALU path. Conditional branches (`PC + immB`) and
`jalr` (`(rs1 + immI) & ~1`) resolve here, as do `ecall` (trap entry) and `mret`.
`csr.v` performs its read-modify-write in this same cycle.

The ALU / `PC+4` / CSR choice is also made in EX and travels down as
`EX/MEM.res`. That placement is deliberate: the EX/MEM forwarding source must be
the value the instruction will actually write back, which for `jal`/`jalr` is
the link address and for `csrr*` is the old CSR value — forwarding the raw ALU
output would forward a jump target instead.

**MEM** — `dmem.v` performs the byte-lane write or the synchronous read.
`EX/MEM.res` is the effective byte address and `EX/MEM.store_data` the forwarded
`rs2`. The load word is registered inside `dmem.v` and lane-selected and
extended combinationally, so the load result is valid during WB.

**WB** — the write-back mux is a two-way choice between `MEM/WB.res` and the
load data, because the other three sources were already resolved in EX. The
result goes to the register-file write port (suppressed for `x0`), to the
commit-trace port, and to the `retire` pulse that increments the instruction
counter.

### 5.3 Pipeline-register fields

Every register's bubble encoding is *all fields zero*, which is a genuine NOP
control word (`reg_we = mem_re = mem_we = csr_we = branch = jalr = mret =
ecall = ebreak = 0`) with `valid = 0`, so a flushed slot has no architectural
effect and is neither retired nor traced. `flush` has priority over `stall` in
all four registers.

| Register | Field | Width | Purpose |
|---|---|---|---|
| **IF/ID** | `valid` | 1 | 0 = bubble; ID substitutes a `nop` for the instruction word |
| | `pc` | 32 | PC of the fetched instruction (jal target base, and the future `mepc`) |
| | *(instruction)* | 32 | held in `imem.v`'s output register, clocked by the same enable |
| **ID/EX** | `valid` | 1 | a real instruction occupies this slot |
| | `illegal` | 1 | decoded as illegal: executes as a NOP, never retires, never traced |
| | `pc` | 32 | trace, `PC+4` link value, branch target base, `mepc` on a trap |
| | `inst` | 32 | commit trace only |
| | `rs1_addr`, `rs2_addr` | 5, 5 | forwarding comparisons |
| | `rd_addr` | 5 | write-back destination, forwarding comparisons |
| | `rs1_val`, `rs2_val` | 32, 32 | register-file read values (pre-forwarding) |
| | `imm` | 32 | selected immediate (also the CSR `zimm`) |
| | `alu_op` | 4 | ALU opcode from `alu_ctrl.v` |
| | `alu_src_a` | 1 | 0 = rs1, 1 = PC (`auipc` only) |
| | `alu_src_b` | 1 | 0 = rs2, 1 = immediate |
| | `funct3` | 3 | branch condition, load/store width, CSR operation |
| | `branch` | 1 | conditional branch: resolve in EX |
| | `jalr` | 1 | `jalr`: resolve in EX |
| | `mem_re`, `mem_we` | 1, 1 | MEM-stage access |
| | `reg_we` | 1 | writes `rd` |
| | `wb_sel` | 2 | 0 ALU, 1 MEM, 2 PC+4, 3 CSR |
| | `csr_en`, `csr_we`, `csr_imm` | 1, 1, 1 | CSR read side / write side / `zimm` form |
| | `csr_addr` | 12 | CSR number |
| | `mret`, `ecall`, `ebreak` | 1, 1, 1 | system instructions |
| **EX/MEM** | `valid`, `illegal` | 1, 1 | as above |
| | `pc`, `inst` | 32, 32 | commit trace |
| | `rd_addr`, `reg_we` | 5, 1 | write-back and forwarding |
| | `wb_sel` | 2 | selects load data vs. `res` in WB |
| | `res` | 32 | ALU result, or `PC+4`, or the old CSR value; for a store or load it is the effective byte address |
| | `store_data` | 32 | forwarded `rs2` for `sb`/`sh`/`sw` |
| | `funct3` | 3 | load/store width and signedness |
| | `mem_re`, `mem_we` | 1, 1 | drives `dmem.v` |
| | `ebreak` | 1 | sets the sticky halt when it retires |
| **MEM/WB** | `valid`, `illegal` | 1, 1 | qualify retire and trace |
| | `pc`, `inst` | 32, 32 | commit trace |
| | `rd_addr`, `reg_we` | 5, 1 | register-file write port |
| | `wb_sel` | 2 | write-back mux select |
| | `res` | 32 | non-memory result; also the trace's store address |
| | `mem_we` | 1 | a store retired (trace) |
| | `mem_val` | 32 | store data masked to width, captured at MEM (trace only) |
| | `ebreak` | 1 | sticky halt |

The load data is deliberately *not* a MEM/WB field: `dmem.v` already registers
the memory word on the MEM clock edge and presents the extended value
combinationally during WB.

### 5.4 PC-select mux

| Priority | Source | Resolved in | Next PC |
|---|---|---|---|
| 1 | reset | — | `0x00000000` |
| 2 | trap (`ecall`, later an external interrupt) | EX | `mtvec` |
| 3 | `mret` | EX | `mepc` |
| 4 | taken conditional branch | EX | `PC + immB` |
| 5 | `jalr` | EX | `(rs1 + immI) & ~1` |
| 6 | `jal` | ID | `PC + immJ` |
| 7 | branch prediction (bonus) | IF | predicted target |
| 8 | sequential | — | `PC + 4` |

Ordering rules that the table encodes:

- Everything resolved in EX outranks anything resolved in ID or IF, because the
  EX instruction is older — an ID-stage `jal` that loses to an EX-stage branch
  is itself on the wrong path and will be flushed.
- Trap and `mret` outrank the branch/`jalr` targets so that a trapping branch
  goes to the handler rather than to its own target.
- A redirect overrides a stall. The stall signal normally holds the PC and the
  IF/ID register, but the instruction that raised it is being killed by the
  redirect, so the fetch enable is `redirect | ~stall` and `flush` beats `stall`
  inside every pipeline register.

Because branches and `jalr` resolve in EX, a taken one leaves **two** shadow
slots (the instructions already in ID and IF); `jal`, resolved in ID, leaves
**one**. Killing those slots is the flush logic of section 6.

### 5.5 Halting, illegal instructions, and the commit trace

`ebreak` is not a trap: it flows through the pipeline normally, is counted and
traced like any other instruction, and then raises a sticky `done` flag as it
retires. `done` freezes the whole pipeline, so nothing behind the `ebreak`
commits and the trace ends exactly at the `ebreak` line.

An illegal instruction is decoded to an all-zero control word, i.e. it executes
as a NOP with no trap. It keeps `valid = 1` but carries an `illegal` flag, and
both the retire pulse and the trace are qualified with `valid && !illegal`, so
it is neither counted nor traced.

The commit-trace port is driven from the MEM/WB register outputs:
`trace_valid` is the retire pulse, `trace_rd_we` additionally requires
`rd != 0`, `trace_mem_addr` is `MEM/WB.res` (the effective byte address of a
store) and `trace_mem_val` is the store data masked to its width, captured from
`dmem.v` at MEM. That is exactly the information the Python reference model
prints, so the two traces can be diffed line by line.

---

## 6. Hazards and pipeline control

Two small combinational modules hold all of it. `rtl/forward_unit.v` decides
where each EX-stage operand comes from; `rtl/hazard_unit.v` decides when the
front of the pipe has to wait and when part of it has to be thrown away. The
datapath of section 5 is unchanged by either: the pipeline registers already
carry `stall` and `flush` inputs, and every comparison input these two modules
need is already routed.

### 6.1 Data hazards and the forwarding unit

An instruction reads its registers in ID but the three instructions ahead of it
have not written theirs back yet. Four distances matter, counting from the
consumer:

| Distance | Producer is in… | Covered by |
|---|---|---|
| 1 | EX (its result appears at the EX/MEM boundary) | EX/MEM bypass, select `2'b10` |
| 2 | MEM (its result appears at the MEM/WB boundary) | MEM/WB bypass, select `2'b01` |
| 3 | WB (writing the register file this cycle) | the register file's WB→ID internal bypass |
| ≥ 4 | already retired | ordinary register read |

Distance 3 is handled inside `regfile.v`, not here: the read ports return
`wdata` whenever `we && waddr == raddr && waddr != 0`, so ID sees the value the
WB stage is writing in the same cycle. Without that bypass a fourth forwarding
path — or a third stall class — would be needed.

Three EX operands need a select of their own, because three different consumers
read a register in EX:

| Select | Feeds | Source register |
|---|---|---|
| `fwd_a` | ALU operand A, `branch_unit` rs1, CSR write source | rs1 |
| `fwd_b` | ALU operand B **and** `branch_unit` rs2 — taken before the rs2/immediate mux, because a branch compares rs2 even though the ALU sees the immediate | rs2 |
| `fwd_c` | store data on its way to `dmem.wdata` | rs2 |

`fwd_b` and `fwd_c` compute the same function; they are kept apart so the
store-data path is visible in the datapath and can be tested on its own.

**Truth table** (identical for all three selects; `rs` is that operand's source
register, `mem_*` is the EX/MEM register, `wb_*` the MEM/WB register):

| `FORWARDING` | `mem_reg_we && mem_rd != 0 && mem_rd == rs` | `wb_reg_we && wb_rd != 0 && wb_rd == rs` | select | operand value |
|---|---|---|---|---|
| 0 | — | — | `2'b00` | ID/EX register value |
| 1 | yes | — | `2'b10` | EX/MEM `res` |
| 1 | no | yes | `2'b01` | WB write data |
| 1 | no | no | `2'b00` | ID/EX register value |

Two rules are load-bearing:

- **EX/MEM outranks MEM/WB.** When both older instructions write the same
  architectural register, the one in MEM is the *newer* writer, and its value is
  what the architecture says this instruction reads. Testing MEM/WB first would
  resurrect the stale value. The last block of `asm/hazard/fwd_ex_ex.s` is
  exactly that trap: `x5 = 100`, then `x5 = x5 + 1`, then a consumer that must
  see 101 while 100 is still sitting in MEM/WB.
- **Never forward from x0.** A producer whose `rd` is x0 wrote nothing — the
  register file suppresses the write — so forwarding its result would make x0
  read non-zero for exactly one instruction. The `rd != 0` term is what
  prevents that, and it also implies `rs != 0`, so no separate consumer-side
  test is needed. `asm/hazard/x0_hazard.s` writes x0 and immediately reads it.

The EX/MEM path deliberately does **not** handle loads. `EX/MEM.res` is the ALU
output, which for a load is the effective address rather than the loaded data.
The interlock below guarantees a consumer never reaches EX while its producing
load has only got as far as MEM, so select `2'b10` is never taken for a load; by
the time the consumer does reach EX the load is in WB and `2'b01` carries real
data.

```
  EX/MEM forward (distance 1)            MEM/WB forward (distance 2)

          c1  c2  c3  c4  c5                     c1  c2  c3  c4  c5  c6
 addi x5  IF  ID  EX  MEM WB           addi x5   IF  ID  EX  MEM WB
 add ,x5      IF  ID  EX  MEM          nop           IF  ID  EX  MEM WB
                  ^^^                  add ,x5           IF  ID  EX  MEM
                  producer is in MEM                         ^^^
                  -> fwd = 2'b10                             producer is in WB
                                                             -> fwd = 2'b01
```

### 6.2 The load-use interlock

A load's data does not exist until the end of MEM, so no bypass can serve a
consumer one slot behind it. That consumer has to wait one cycle:

```
stall = ID/EX.valid && ID/EX.mem_re && ID/EX.rd != 0 &&
        ( (ID reads rs1 && ID.rs1 == ID/EX.rd) ||
          (ID reads rs2 && ID.rs2 == ID/EX.rd) )
```

`rd != 0` matters because `lw x0, 0(rs1)` writes nothing. The "ID reads rsN"
qualifiers come from the decoder, not from the raw instruction bits: without
them `lui`, `auipc`, `jal`, the `csrr*i` forms and `ecall` would appear to read
whatever their immediate happens to place in the rs1/rs2 field and could raise a
stall no real dependency justifies. That would cost cycles rather than
correctness, but the counters exist to measure CPI, so they should not count
hazards that are not there.

One cycle is always enough — after it the load has reached WB and the MEM/WB
bypass supplies the data:

```
                 c1   c2   c3   c4   c5   c6   c7
 lw   x7,0(x5)   IF   ID   EX   MEM  WB
 add  x8,x7,x0        IF   ID   ID   EX   MEM  WB
                           ^^   ^^   ^^
                           |    |    +- lw is in WB: MEM/WB forward (2'b01)
                           |    +------ add re-decodes; ID/EX got a bubble
                           +----------- hazard seen: stall raised
 sub  ...                  IF   IF   ID   EX   MEM
                                ^^ PC and IF/ID held, imem en = 0
```

The stall acts on three places at once: `pc.v`'s enable goes low, `imem.v`'s
enable goes low (the instruction word lives in imem's output register, so
holding the PC alone would not hold the instruction), the IF/ID register holds,
and the ID/EX register is loaded with a bubble. That last part is what turns a
stall into a bubble travelling down the back half of the pipe.

`asm/hazard/load_use.s` covers every shape of it: the loaded value used as rs1,
as rs2, as both operands at once, as a store's base address, as a store's data,
and as a branch operand.

### 6.3 Control hazards and the flush rules

| Redirect | Resolved in | Flushes | Cost |
|---|---|---|---|
| `jal` | ID (target = PC + J-immediate, no register needed) | IF/ID | 1 bubble |
| taken conditional branch | EX | IF/ID + ID/EX | 2 bubbles |
| `jalr` | EX (needs rs1) | IF/ID + ID/EX | 2 bubbles |
| `ecall` trap entry | EX | IF/ID + ID/EX, and EX/MEM (the `ecall` itself is squashed, not retired) | 2 bubbles |
| `mret` | EX | IF/ID + ID/EX (`mret` itself retires) | 2 bubbles |
| `ebreak` shadow | EX, held through MEM and WB | IF/ID + ID/EX, continuously | — |

Flushing means writing the bubble encoding — every field zero, `valid = 0` —
into the register, so the killed instruction has no architectural effect and is
neither retired nor traced.

`jal` flushes only IF/ID: the `jal` is itself in ID and must go on into EX to
compute and write its link value, so ID/EX must *not* be cleared. Everything
resolved in EX flushes both, because both younger slots are on the wrong path.

```
  Taken branch: 2 bubbles                    jal: 1 bubble

           c1   c2   c3   c4   c5   c6                c1   c2   c3   c4   c5
 beq(T)    IF   ID   EX   MEM  WB          jal        IF   ID   EX   MEM  WB
 B+4            IF   ID   x                J+4             IF   x
 B+8                 IF   x                target               IF   ID   EX
 target                   IF   ID   EX                          ^
                     ^                                          PC redirected
                     PC redirected at the end of c3             at the end of c2
                     x = flushed to a bubble
```

An `ebreak` does not redirect the PC — it is not a trap — but nothing behind it
may commit. It therefore holds IF/ID and ID/EX empty from the moment it reaches
EX until it retires and the sticky `done` flag freezes the machine. The shadow
is tracked across EX, MEM and WB rather than only in EX, so a fresh fetch cannot
slip in behind it during the two cycles it takes to drain.

**A redirect overrides a stall.** The instruction in ID that raised the stall is
being killed anyway, so waiting for it would deadlock the redirect. This is
expressed in three places, deliberately redundantly: `stall` is suppressed while
a flush is happening, `flush` beats `stall` inside every pipeline register
(`if (rst || flush) … else if (!stall) …`), and the fetch enable is
`~halt & (redirect | ~stall)` so the PC and instruction memory advance to the
redirect target even during a stall cycle.

One consequence is easy to get wrong: **a `jal` must never be stalled.** A
stall holds IF/ID and bubbles ID/EX, which is right for an instruction that is
waiting — but a `jal` in ID has already committed the machine to its target by
the time the stall takes effect, so holding it would redirect the PC and then
delete the `jal` itself, silently losing its link-register write. A `jal` reads
no registers, so the interlock condition cannot fire on one; the hazard unit
nevertheless suppresses `stall` whenever `redirect_id` is asserted, so the
invariant is enforced structurally rather than left to depend on the decoder.
Removing that term and simultaneously over-approximating the interlock (taking
rs1/rs2 straight from the instruction bits instead of asking the decoder
whether they are really read) makes `asm/prog/bloop` lose exactly one retired
instruction per loop iteration — which is how the term earned its place.

`asm/hazard/branch_flush.s` puts poison instructions (`addi x10, x0, 999`) in
every shadow slot; if any of them survives, the register compare and the commit
trace both fail.

### 6.4 CSR hazards

There are none to interlock. `csr.v` sits in EX and does its read-modify-write
in a single cycle: the value presented on `csr_rdata` is the pre-write
architectural value and the modified value is committed on the same clock edge.
An instruction one slot behind therefore reaches EX a cycle later and reads the
already-updated register. `csrw mepc, t0` immediately followed by `mret` works
for the same reason — `mepc` is written at the end of the cycle in which the
`csrw` is in EX, and `mret` reads it in its own EX the next cycle.

What *does* need forwarding is the register side of a CSR instruction: the
write source is rs1, so it goes through `fwd_a` like any other operand, and the
destination register receives the old CSR value through the ordinary write-back
path — which is why the ALU/`PC+4`/CSR result mux lives in EX (section 5.2), so
that a consumer of `csrrw`'s `rd` forwards the CSR value and not the unused ALU
output. `asm/hazard/csr_hazard.s` exercises all three cases.

### 6.5 `FORWARDING = 0` — the stall-only build

`FORWARDING` is a compile-time parameter on `cpu_top`, threaded to both hazard
modules. Setting it to 0 forces every forwarding select to `2'b00`, so an
operand can only ever come from the register file. Correctness is then restored
by stalling instead: the instruction in ID waits while *any* pending write to
one of its source registers is still in EX or in MEM.

```
stall = ID reads a register that a valid instruction in EX or in MEM will
        write, with rd != 0
```

A producer in EX costs two stall cycles, a producer in MEM costs one, and a
producer already in WB costs none because the register file's WB→ID bypass
covers it — hence a maximum of two. Loads need no special case: the general
rule already holds the consumer until the load reaches WB, where its data is
valid.

```
  FORWARDING = 0, distance-1 dependency

              c1   c2   c3   c4   c5   c6   c7
 addi x5,..   IF   ID   EX   MEM  WB
 add x6,x5,x5      IF   ID   ID   ID   EX   MEM
                        ^^   ^^   ^^
                        |    |    +- producer in WB: regfile WB->ID bypass,
                        |    |       no stall, reads the correct value
                        |    +------ producer in MEM: still stalled
                        +----------- producer in EX: stalled
```

The two builds are functionally identical — every test in `asm/insn`,
`asm/hazard`, `asm/prog` and `tb/bringup` passes under both — and differ only in
cycle count. That difference, measured by the performance counters, is the
"show the performance of your CPU" experiment of section 11.

### 6.6 What the performance counters count

| Counter | Increment condition |
|---|---|
| `cycles` | every cycle after reset |
| `insns` | a valid, non-illegal instruction leaves WB (`ebreak` included, a squashed `ecall` excluded) |
| `lu_stalls` | every interlock cycle: load-use cycles when `FORWARDING = 1`, every RAW stall cycle when `FORWARDING = 0` |
| `flushes` | one per control-flow redirect event — taken branch, `jalr`, `jal`, `ecall` trap or `mret` — not one per killed slot; the `ebreak` shadow is not counted, it is not a mispredicted control transfer |
| `bht_preds`, `bht_misses` | branch-prediction bonus, section 9 |

The `retire`, `lu_stall` and `flush` pulses are all gated off the moment `done`
goes high, and the testbench stops the simulation on the next edge, so a
measurement ends exactly at the `ebreak` and nothing in the drain shadow is
counted. CPI is `cycles / insns`; the testbench prints it as `CPI_x1000` to
stay in integer arithmetic.

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

### 10.1 Strategy: three tiers

**Tier 1 — the xsim batch flow.** Every simulation, unit or program, runs
through the same three-command Vivado 2026.1 pipeline (`xvlog` → `xelab` →
`xsim`), invoked in batch mode with no GUI, no waveform viewer and no other
simulator. Every testbench is self-checking: it prints exactly one line
starting with `PASS` or `FAIL` and nothing else in the log may start a line
that way, and the run's exit code is 0 iff a `PASS` line is present and no
`FAIL` line is. There is no tier where a human reads a waveform to decide
correctness — the checking is always in the testbench, never in the report.

**Tier 2 — unit testbenches and per-instruction programs.** Every RTL module
that is not pure wiring has a standalone testbench (section 10.3) driven by
machine-generated vectors, and every one of the 46 instructions has a small
assembly program with a hardcoded golden register file (section 10.5). This is
the bulk of the check count and the midterm-report evidence: it demonstrates
each piece of the decode/execute/hazard logic in isolation before anything is
asked to work in combination.

**Tier 3 — differential testing against the golden ISS.** `tools/iss.py` is a
second, independent implementation of the same instruction set, written in
Python without reference to the Verilog. Every program-level test — not just
the three named benchmarks — is checked two ways: its final architectural
register file against the ISS's, and its cycle-by-cycle commit trace against
the ISS's instruction-by-instruction trace, line for line. A trace mismatch
localizes a bug to a specific retiring instruction instead of only reporting
"final state wrong," which for a five-stage pipeline is the difference between
an afternoon of debugging and a week of it.

The project does not use Mars (MIPS-only — a different ISA family entirely,
not a candidate) or Spike (the standard RISC-V reference simulator) as the
oracle. Spike is a compiled C++ binary distributed as a Linux/build-from-source
tool; it is not available for this Windows machine without installing a
toolchain the project's environment rules forbid ("no Icarus, no GTKWave, no
Spike — do not install anything"). Writing the reference model instead of
importing one has a second benefit: building `iss.py` forces the same
instruction-set questions the RTL has to answer (sign extension, shift-amount
truncation, trap semantics) to be resolved once, explicitly, in a form that is
easy to read and to test — which is also why it doubles as the assembler's
own cross-validation oracle (10.2) rather than being written after the fact
purely to check the RTL.

### 10.2 Toolchain: assembler and golden ISS

**`tools/asm.py`** is a two-pass RV32I assembler. Pass 1 collects labels and
`.equ` constants and sizes every instruction (needed because `li` expands to
one instruction when its constant fits 12 signed bits and to two — `lui` +
`addi` — otherwise, and `la` always expands to two); pass 2 emits the encoded
words. It understands all six instruction formats (R/I/S/B/U/J), the assembler
directives needed by the test programs (`.text`, `.data`, `.equ`, `.space`,
`.align n` to an n-byte boundary, n a power of two), and the pseudo-ops used
throughout `asm/` (`li`, `la`, `nop`, `mv`, branch-with-zero forms, and the
like). Output is exactly 1024 lowercase 8-hex-digit lines — a full
`$readmemh`-loadable image of the 4 KB instruction memory — plus a matching
`<name>.data.hex` when the source has a non-empty `.data` section.

**`tools/iss.py`** is the golden reference. It models Harvard instruction/data
memories, the full register file with `x0` hardwired, the CSR subset of
section 8, and trap/`mret`/interrupt semantics identical to the RTL's (traps
taken at the point a real instruction would be in EX, `mepc`/`mcause`/`MIE`/
`MPIE` updated the same way, direct-mode `mtvec`). It exposes `Cpu(text,
data).step()` / `.run()` and returns exit codes that the rest of the toolchain
treats as a contract: **0** = halted on `ebreak`, **2** = `--max-insns`
exceeded, **3** = illegal instruction.

Every retiring instruction emits one commit-trace line:

```
<pc (8 hex)> <insn (8 hex)> [x<rd>=<value (8 hex)>] [mem[<addr (8 hex)>]=<value (8 hex)>]
```

both bracketed fields are omitted when they do not apply (a branch, or an
instruction with `rd = x0`), and the whole line is lowercase. Three examples:

```
00000000 00a00293 x5=0000000a          # addi x5, x0, 10   (ALU op, rd write)
00000008 00628023 mem[00000003]=000000ff   # sb x6, 0(x5)  (store, masked to a byte)
00000018 00100073                          # ebreak — pc and insn only, no rd, no mem
```

`tools/test_tools.py` cross-validates the assembler against the ISS: 54
hand-verified 32-bit encodings, computed field-by-field from the RV32I format
tables *before* the assembler existed (so a shared misreading of the spec by
both tools cannot hide behind agreement), plus encode → decode round trips at
every immediate-format boundary value (`-2048`/`+2047`, `±4096`, `±1 MiB`,
zero, all-ones), semantic checks (sign extension, partial stores, shifts,
comparisons, branches, jumps, CSR read-modify-write, traps, interrupts, `x0`),
pseudo-instruction expansion, assembler error cases, and a byte-exact check of
the commit-trace format above through the CLI. The suite runs 4323 checks and
exits 0 only if every one of them passes.

### 10.3 Unit-level testbenches

Every vector file for these testbenches is generated by the already
cross-validated tools (`asm.encode`, `iss.decode`, or the `CONTROL` dictionary
that also produces section 3's table) — never by a second, independent
re-implementation of the same bit shuffle the RTL is being checked against.
That rule is stated explicitly in `tools/gen_imm_vectors.py` and
`tools/gen_control_table.py`: a hand-rewritten immediate extractor or decode
table would only duplicate whatever the RTL author misunderstood about the
spec, not catch it.

| Testbench | DUT | What it checks | Checks |
|---|---|---|---|
| `tb_imm_gen` | `imm_gen.v` | all six immediate formats; 1846 vectors derived from the ISS's own `Decoded.imm`/`Decoded.zimm` fields, plus 19 hand-computed goldens for the classic extraction traps: B-format `imm[11] ← inst[7]`, J-format `imm[11] ← inst[20]`, I-format `0x800` (most-negative 12-bit value), `srai rd,rs1,31` (shamt 31 with `inst[30]` set) | 1865 |
| `tb_alu` | `alu.v` | all 11 ALU operations across signed/unsigned extremes and every shift amount | 5072 |
| `tb_regfile` | `regfile.v` | the WB→ID internal bypass, and that `x0` reads zero and ignores writes | 76 |
| `tb_control` | `control.v` + `alu_ctrl.v` | the full truth table of section 3 for all 46 encodings, including the `addi`-with-`inst[30]`-set trap; 519 legal vectors + 120 illegal vectors (bad `funct7`, unsupported `funct3`, `wfi`, unknown opcodes) + 28 hand-computed goldens | 667 |
| `tb_branch_unit` | `branch_unit.v` | all six branch conditions across signed/unsigned comparison extremes | 16072 |
| `tb_dmem` | `dmem.v` | byte lanes for `sb`/`sh`/`sw`, sign/zero extension for `lb`/`lh`/`lbu`/`lhu`/`lw` | 32 |
| `tb_imem` | `imem.v` | synchronous read timing and enable behavior | 10 |
| `tb_pc` | `pc.v` | reset, hold-on-stall, load-on-redirect | 12 |
| `tb_perf_counters` | `perf_counters.v` | the five counters of section 6.6 | 19 |

### 10.4 Mutation checks

A unit testbench is not trusted until it is shown to fail. Before being
accepted, every testbench in section 10.3 was run once against a deliberately
broken copy of its DUT and confirmed to report `FAIL`; only then was the
correct RTL restored. This catches the case where a testbench passes not
because the DUT is right but because the testbench itself has a bug (an
inverted comparison, a vector file that never got regenerated, a check that
silently short-circuits). The injected bugs and the check that caught each:

| Injected bug | Where | Caught by |
|---|---|---|
| `SRA` implemented as a logical shift (no sign extension) | `alu.v` | `tb_alu` (negative-operand shift vectors) |
| WB→ID internal bypass removed | `regfile.v` | `tb_regfile` |
| B-format immediate bit flipped (wrong source bit for `imm[11]`) | `imm_gen.v` | `tb_imm_gen` |
| `alu_ctrl` consults `inst[30]` for `addi` (I-type `funct3 = 000`) | `alu_ctrl.v` | `tb_control` (the addi/sub trap goldens) |
| Forwarding priority swapped — MEM/WB checked before EX/MEM | `forward_unit.v` | `asm/hazard/fwd_ex_ex.s` |
| `rd != 0` guard removed from the forwarding comparison (forwards from `x0`) | `forward_unit.v` | `asm/hazard/x0_hazard.s` |
| Load-use interlock disabled | `hazard_unit.v` | `asm/hazard/load_use.s` |
| `lb` sign extension removed (treated as `lbu`) | `dmem.v` | `tb_dmem`, and `asm/insn/lb.s` |

The last four are datapath-level bugs with no meaningful unit-level DUT of
their own (forwarding and the load-use stall only manifest across the pipeline
boundary they cross), so they are caught by the hazard programs of section
10.6 and the per-instruction programs of 10.5 rather than by an isolated
module testbench — consistent with the fact that `forward_unit.v` and
`hazard_unit.v` are combinational functions of pipeline-register fields, not
of anything a standalone testbench could drive meaningfully on its own.

### 10.5 Per-instruction programs (`asm/insn/`, 46 programs)

One program per encoding, each with at least four semantic cases (e.g. `add`
covers positive+positive, positive+negative, and signed overflow wraparound;
loads cover sign-extended, zero-extended, and unaligned-within-word cases).
Results land in `x5`–`x31`, and every program ends in `ebreak`. The expected
32-register file (`<name>.regs`) and the expected commit trace (`<name>.trace`)
are both generated by the ISS, not hand-typed, via `tools/gen_fixtures.py`.
`tb/tb_program.v` is the single generic testbench for all of them: given
`+PROG=asm/insn/<name>`, it loads `<name>.hex`, runs the DUT to `done`,
compares all 32 architectural registers against `<name>.regs`, and diffs the
commit trace line-by-line against `<name>.trace`.

Programs written before the hazard logic existed (build step 4) are
NOP-padded — three `nop`s between a write and the next read of the same
register, since with no forwarding the value is not available until it
retires into the register file. Once the per-instruction programs run under
full hazard logic (`+NOTRACE` no longer needed — see 10.7), the NOP padding
stops being a correctness requirement but is left in place; one exception was
found to already exercise forwarding regardless of padding intent: `li`
expands to `lui` + `addi`, a distance-1 (immediately-adjacent) RAW dependency
on the very register `li` is defining, so every per-instruction program that
uses `li` for an operand outside the ±2048 range incidentally forwards through
that pair before it does anything else.

### 10.6 Hazard programs (`asm/hazard/`, 9 programs)

Each program is not NOP-padded — that is the point — and each targets one
hazard class. The register named is the one the program's own comments
identify as the value that comes out wrong if the corresponding logic is
broken:

| Program | Hazard class | Wrong-if-broken value |
|---|---|---|
| `fwd_ex_ex.s` | EX/MEM-forwarding-wins-over-MEM/WB priority; back-to-back dependent ALU chain | `x11` (must forward EX/MEM's 101, not MEM/WB's stale 100) |
| `fwd_mem_ex.s` | distance-2 dependency (producer two instructions back, MEM/WB forward) | producer-in-MEM value seen where the WB value is required |
| `fwd_wb_id.s` | distance-3 dependency (producer three instructions back, regfile WB→ID bypass) | stale pre-write register value |
| `load_use.s` | load-use interlock, all operand positions (rs1, rs2, both, store address, store data, branch operand) | loaded value used one cycle too early (garbage instead of `0x1234`) |
| `store_data_fwd.s` | store-data (rs2) forwarding into `dmem.wdata` | wrong word stored to memory |
| `branch_flush.s` | control-hazard flush completeness (both EX-resolved shadow slots) | a poison instruction (`addi x10, x0, 999`) survives and corrupts `x10` |
| `x0_hazard.s` | never-forward-from-`x0` guard | `x0` observed non-zero for one cycle |
| `csr_hazard.s` | CSR read-after-write same-cycle visibility, and rs1→CSR-write-source forwarding | stale CSR value read one instruction too early |
| `mixed.s` | combinations of the above in one instruction stream | any of the above, in combination |

### 10.7 Program-level diff tests (`asm/prog/`)

| Program | What it does | Instructions retired | Pass criterion |
|---|---|---|---|
| `fib.s` | iterative Fibonacci into a DMEM array, checksum + copy pass | 658 | fib(30) = 832040 in the destination register; zero differing trace lines; identical register file |
| `bsort.s` | bubble sort of 16 words including negative values | 1366 | sorted array in DMEM; zero differing trace lines; identical register file |
| `bloop.s` | branch-heavy loop exercising every branch condition repeatedly | 2878 | zero differing trace lines; identical register file |
| `irq_demo.s` | interrupt bonus demonstration, two external interrupts | 633 | correct `mepc`/`mcause`/ISR side effects (section 8.2); zero differing trace lines; identical register file |

A "differing trace line" is any line where the RTL's WB-stage commit trace and
the ISS's trace disagree once both are diffed line-by-line by `tb_program.v`;
the pass criterion is that this diff is empty and the two final 32-register
files are bit-identical.

### 10.8 Bring-up programs (`tb/bringup/`, 7 programs)

`bu_alu`, `bu_branch_nt`, `bu_branch_t`, `bu_csr`, `bu_data`, `bu_mem`,
`bu_trap` — strictly hazard-free by construction (every dependency is
NOP-padded to distance ≥ 4, so no forwarding or stalling is ever required to
get the right answer) and used to validate the five-stage datapath of section
5 *before* the hazard logic of section 6 existed. At build step 4 (no
forwarding, no flush) they are run with `+NOTRACE`, so only the final register
file is checked — 5 of the 7 (excluding the branch-taken and trap programs,
whose wrong-path shadow instructions the unflushed pipeline still retires) are
trace-exact even at that stage. Once flushing exists, all 7 are checked both
ways, matching the per-instruction programs' full trace-exact criterion.

### 10.9 Regression command set

```
# one unit testbench
bash sim/run.sh tb_alu
bash sim/run.sh tb_control

# batch driver: every program in a directory, PASS/FAIL summary + PERF line
python tools/run_tests.py --dir asm/insn
python tools/run_tests.py --dir asm/insn --dir asm/hazard
python tools/run_tests.py --dir asm/prog

# CPI comparison: force the FORWARDING compile-time parameter
python tools/run_tests.py --dir asm/prog --fwd 1
python tools/run_tests.py --dir asm/prog --fwd 0

# regenerate fixtures / control table after an ISA or control change
python tools/gen_fixtures.py
python tools/gen_control_table.py
python tools/gen_control_table.py --check   # fail if stale

# toolchain cross-validation (no RTL involved)
python tools/test_tools.py
```

`sim/run.sh` reuses one xsim work directory per testbench, so program-level
runs are sequential rather than parallel; each xsim launch costs roughly
5–10 seconds, which is why `tools/run_tests.py` exists as a batch driver
rather than invoking `run.sh` once per program by hand.

### 10.10 Results summary

*Measured on commit `28768aa` (step 5). Rows marked TBD are re-measured in the
final regression after the bonus features.*

| Suite | Programs / vectors | PASS at `FORWARDING=1` | PASS at `FORWARDING=0` |
|---|---|---|---|
| `tb_imm_gen` | 1865 vectors | PASS | — |
| `tb_alu` | 5072 vectors | PASS | — |
| `tb_regfile` | 76 vectors | PASS | — |
| `tb_control` | 667 vectors | PASS | — |
| `tb_branch_unit` | 16072 vectors | PASS | — |
| `tb_dmem` | 32 vectors | PASS | — |
| `tb_imem` | 10 vectors | PASS | — |
| `tb_pc` | 12 vectors | PASS | — |
| `tb_perf_counters` | 19 vectors | PASS | — |
| `asm/insn/*` | 46 programs | 46/46 | TBD (final regression) |
| `asm/hazard/*` | 9 programs | 9/9 | 9/9 |
| `asm/prog/*` | 4 programs | 3/3 core (irq_demo after §9) | 3/3 core |
| `tb/bringup/*` | 7 programs | 7/7 | TBD (final regression) |
| `tools/test_tools.py` | 4323 checks | PASS (tool-level, not RTL) | — |

---

## 11. Performance

<!-- TODO(step 8): cycle counts and CPI for the three benchmark programs with
forwarding on and off, load-use stall / flush / mispredict counter readings,
BHT accuracy, and the Vivado synthesis results (fmax, LUT/FF/BRAM utilisation
for the chosen 7-series part). -->
