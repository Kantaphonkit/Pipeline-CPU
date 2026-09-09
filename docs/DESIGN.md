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

One consequence is easy to get wrong: **a `jal` (or a branch the BHT predicts
taken) must never redirect on a cycle its own instruction is being stalled.**
A stall holds IF/ID and bubbles ID/EX, which is right for an instruction that
is waiting on a register — but a `jal` in ID has already committed the machine
to its target the moment it decodes, and a predicted-taken branch commits to
the BHT's target the same way. If either redirected while the stall was also
in effect, the fetch enable would reload IF/ID with the target on the very
cycle the stalled instruction itself was being bubbled out of ID/EX, silently
losing its link-register write (`jal`) or simply vanishing (a predicted
branch). Neither instruction reads a register that could raise the load-use
interlock on its own account, but a stall raised by an unrelated, older
instruction can still be active on the same cycle.

An earlier version of this design guarded against exactly that from the stall
side, adding a `!redirect_id` term to `stall` so an ID-stage redirect always
suppressed its own instruction's stall. That stopped working once the branch
predictor gave `redirect_id` a second source: `redirect_id = jal_taken |
bht_taken`, and `bht_taken` is driven by `id_pred_taken`, which does not
depend on `stall`. A `stall` expression that reads `redirect_id` would then
depend on a signal that would itself need to read `stall` — `stall →
redirect_id → stall`, a combinational loop with two stable states.

The fix moves the gating to the redirect side instead. In `rtl/cpu_top.v`,
both `jal_taken` and `bht_taken` are qualified with `~stall & ~ebreak_pending`:

```
assign jal_taken   = if_id_valid & id_jal & ~stall & ~ebreak_pending;
assign bht_taken   = id_pred_taken        & ~stall & ~ebreak_pending;
assign redirect_id = jal_taken | bht_taken;
```

so `redirect_id` is structurally zero on any cycle `stall` is asserted, without
either signal needing to reference the other. `hazard_unit.v`'s `stall` output
no longer mentions `redirect_id` at all — it is purely a function of the
load-use (or RAW, at `FORWARDING = 0`) condition. The rule is now: **an
ID-stage redirect (`jal`, or a predicted-taken branch) only fires in the cycle
the ID instruction actually advances.** The consequence the old term protected
is unchanged: a stalled `jal` or a stalled predicted-taken branch never loses
its link write or its redirect, it just redirects one cycle later, once the
stall clears. The cost is still at most one extra cycle.

This also retires a latent bug the old mechanism had. Section 10.4 records a
mutation that over-approximates the load-use interlock — treating every
instruction as reading whatever sits in its raw `rs1`/`rs2` fields, instead of
asking the decoder whether it really does — which spuriously stalls a `jal`.
Under the old `!redirect_id`-in-`stall` rule, that mutation broke
`asm/prog/bloop`, losing exactly one retired instruction per loop iteration:
`redirect_id` suppressed the stall, so the `jal` redirected on the same cycle
the (spurious) stall bubbled it out of ID/EX, and its link write never
happened. Under the current rule the same mutation only costs cycles (section
10.4), because a `jal` structurally cannot redirect while stalled — it simply
waits, then redirects.

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

### 8.3 Interrupt entry timing

The trap point is EX, so the entry costs the same two bubbles as a mispredicted
branch. Writing `I(n)` for the instruction that happens to be in EX when the
level is sampled:

```
                  c1    c2    c3    c4    c5    c6    c7
  I(n-2)          EX    MEM   WB                             retires normally
  I(n-1)          ID    EX    MEM   WB                       retires normally
  I(n)            IF    ID    EX    --                        SQUASHED
  I(n+1)                IF    ID    --                        killed (flush_id)
  I(n+2)                      IF    --                        killed (flush_if)
  ISR[0] (mtvec)                    IF    ID    EX    MEM
                                ^
                                c3: irq sampled with a valid instruction in EX
                                    mepc   <- PC of I(n)
                                    mcause <- 0x8000000B
                                    MPIE   <- MIE ; MIE <- 0
                                    PC     <- mtvec
                                    EX/MEM flushed -> I(n) never retires
```

Three properties fall out of that picture and each is checked directly by
`tb/tb_irq.v`:

- `I(n)` is **cancelled, not delayed**. It is squashed at the EX/MEM boundary,
  so it never reaches memory or the register file, and it does not appear in
  the commit trace. It runs for the first time after `mret` returns to `mepc`.
- `I(n-1)` and `I(n-2)` **do retire**. They are older than the interrupted
  instruction and are already past EX, so up to two more instructions commit
  after the trap fires and before the handler's first instruction does. This is
  the whole reason the reference-model alignment of section 9.2 is needed.
- The interrupt **outranks an `ecall`** occupying the same EX slot. `mepc` then
  points at the `ecall`, which re-executes after the handler returns. The
  reference simulator samples `irq` at the instruction boundary before decoding,
  so it makes the same choice, and this is the standard RISC-V ordering.

The `irq` input is a **level**. It is qualified inside `csr.v` by `mstatus.MIE`
and `mie.MEIE`, so a program that never enables interrupts is completely
unaffected by it: no trap, no `mcause` write, not one extra cycle. A level
raised while the CPU is inside its handler (where `MIE = 0`) is not lost — it is
taken as soon as `mret` restores `MIE`, three cycles later.

---

## 9. Bonus features

Two of the three bonus items in the task statement are implemented and measured:
branch prediction and interrupts. The third, an instruction cache, is designed
on paper and deliberately not built; section 9.3 says why.

### 9.1 Branch prediction: a 64-entry 2-bit BHT

#### What it predicts, and what it does not

`rtl/bht.v` is a **direction** predictor only. It answers "will this
conditional branch be taken?" and nothing else. There is no branch target
buffer, because the target of a conditional branch is `PC + B-immediate` and the
decode stage already computes that from information it has anyway. Dropping the
BTB removes a tagged CAM from the design and costs one cycle on a correctly
predicted taken branch, which the cost table below accounts for honestly.

The table holds 64 two-bit saturating counters indexed by `pc[7:2]` — bits 2..7
of the byte address, covering a 256-byte window of instruction space. The table
is **untagged**: addresses 256 bytes apart share a counter. That aliasing is the
intended cost of a cheap table; it degrades accuracy and never correctness.

#### The counter FSM

```
                 taken            taken            taken
              ----------->     ----------->     ----------->
      +-----------+     +-----------+     +-----------+     +-----------+
      |    00     |     |    01     |     |    10     |     |    11     |
      |  strongly |     |   weakly  |     |   weakly  |     |  strongly |
      | not taken |     | not taken |     |   taken   |     |   taken   |
      +-----------+     +-----------+     +-----------+     +-----------+
              <-----------     <-----------     <-----------
                not taken        not taken        not taken

      +--+ not taken                                   taken +--+
      |  | (saturates, stays 00)      (saturates, stays 11)  |  |
      +->+                                                   +<-+

      prediction = state[1]     00, 01 -> not taken
                                10, 11 -> taken
      reset state = 01 (weakly not taken)
```

Resetting to `01` rather than `00` or `10` is deliberate: an unvisited branch
then behaves exactly like the static not-taken machine, so turning the predictor
on can never make a *first* encounter worse, and a loop's backward branch
reaches "taken" after a single observation.

#### Where each step happens in the pipeline

| Step | Stage | Detail |
|---|---|---|
| Lookup | IF | indexed by the PC the instruction memory is reading, in parallel with the fetch — off the critical path |
| Carry | IF/ID | the 2-bit counter state travels with the instruction, so ID needs no second table read |
| Act | ID | if the instruction is a conditional branch and the carried state predicts taken, redirect the PC to `PC + B-imm` — the same 1-bubble path `jal` uses |
| Resolve | EX | `mispredict = predicted_taken != actual_taken`; on a mispredict redirect to the correct target and flush 2 |
| Update | EX | indexed by the EX-stage PC, with the resolved outcome, saturating |

Only the direction is carried into EX (one flip-flop). The predicted target is
**not** carried: it is `ex_pc + ex_imm`, and both of those are already in the
ID/EX register, so recomputing it in EX costs an adder that already exists and
saves 32 flip-flops.

A lookup and an update of the same index in the same cycle is allowed, and the
lookup returns the old value. That costs at most one extra mispredict on a
branch that recurs faster than the pipeline depth, and it removes a bypass.

#### Cost table

| Prediction | Outcome | Bubbles | Why |
|---|---|---|---|
| not taken | not taken | **0** | nothing is redirected; the fall-through was already being fetched |
| taken | taken | **1** | the ID-stage redirect kills the one instruction in flight behind the branch |
| not taken | taken | **2** | the EX-stage redirect kills the two instructions in ID and IF |
| taken | not taken | **2** | the ID redirect kills one instruction, then the EX redirect kills the wrongly fetched target and refetches the fall-through |

```
  Correctly predicted TAKEN -- 1 bubble        Mispredicted (NT -> T) -- 2 bubbles

            c1   c2   c3   c4   c5                      c1   c2   c3   c4   c5   c6
  br (T)    IF   ID   EX   MEM  WB             br (T)   IF   ID   EX   MEM  WB
  br+4           IF   x                        br+4          IF   ID   x
  target              IF   ID   EX             br+8               IF   x
                 ^                             target                  IF   ID   EX
                 ID redirect (flush_if)                          ^
                                                                 EX redirect
                                                                 (flush_if + flush_id)

  Mispredicted (T -> NT) -- 2 bubbles

            c1   c2   c3   c4   c5   c6
  br (NT)   IF   ID   EX   MEM  WB
  br+4           IF   x                    killed at c2 by the ID redirect
  target              IF   x               killed at c3 by the EX redirect
  br+4 (refetched)         IF   ID   EX
```

The asymmetry is worth stating plainly in the presentation: this predictor can
only *win* on branches that are actually taken, because a correctly predicted
not-taken branch already cost nothing. On a workload whose conditional branches
are mostly loop **exits** — not taken almost every time — the BHT has nothing to
gain and a mispredict to lose.

#### Measured results

Every figure below is from `python tools/run_tests.py --dir asm/prog` with
forwarding on, `--bht 1` against `--bht 0`. Accuracy is
`(branches − mispredicts) / branches`, from the `bht_pred` and `bht_miss`
counters, which count at both settings.

| Program | BHT off, cycles | BHT on, cycles | Change | Branches | Mispredicts | Accuracy | Static-not-taken accuracy |
|---|---|---|---|---|---|---|---|
| `fib` | 900 | **821** | −8.8 % | 91 | 6 | **93.4 %** | 3.3 % |
| `bsort` | 1880 | 1890 | +0.5 % | 288 | 71 | 75.3 % | 70.1 % |
| `bloop` | 4019 | 4419 | +10.0 % | 891 | 446 | 49.9 % | 72.4 % |
| `irq_demo` | 849 | 849 | 0.0 % | 201 | 1 | 99.5 % | 99.5 % |
| `asm/smoke` | 80 | 80 | 0.0 % | 6 | 6 | 0.0 % | 0.0 % |
| `asm/insn` (46) | 1209 | 1216 | +0.6 % | 39 | 25 | 35.9 % | 35.9 % |

`fib` is the clean win: its inner loop is a taken backward branch, so 93.4 %
accuracy converts directly into 79 saved cycles.

`bloop` gets *worse*, and understanding why is more instructive than the win.
Its own header comment says it was written to defeat a 2-bit predictor: the
inner `beq` tests `k & 1` and therefore alternates taken/not-taken on every
single iteration, which is precisely the pattern a saturating counter cannot
learn — it oscillates between `01` and `10` and mispredicts 100 % of the time.
That branch runs 400 times. Its other 491 conditional branches are all loop
*exits* (`bge`), not taken on all but the last pass of each run, so the
predictor correctly predicts them not-taken and saves nothing, because static
not-taken was already free. The arithmetic closes exactly:

- static not-taken: 246 taken branches × 2 bubbles = 492 penalty cycles;
- with the BHT: 446 mispredicts × 2 + 0 correctly-predicted-taken × 1 = 892;
- difference = 400 = the number of alternating-branch iterations, and the
  measured difference is 4419 − 4019 = 400 cycles.

`bloop` also uses `j` (a `jal`) for all three loop back-edges, so none of its
back-edges is a conditional branch the predictor could win on. It is an
adversarial benchmark, and reporting it is more useful than hiding it: a 2-bit
BHT is a cheap heuristic, not a guarantee, and the honest summary is "helps
loop-dominated code, neutral on exit-dominated code, hurts on alternating
branches".

The `asm/insn` row shows the aliasing cost in miniature: 39 one-shot branches
spread over a small address range, where the untagged index means one branch's
training pollutes another's. Seven taken branches were predicted correctly
(saving 7 cycles) but seven not-taken branches were mispredicted as taken
(costing 14), for a net +7.

#### The predictor cannot break the machine

A mutation check makes that concrete: training the counters with the
**inverted** outcome (`update_taken = ~branch_cond`) collapses accuracy —
`fib` 93.4 % → 3.3 %, `bsort` 75.3 % → 25.3 %, `bloop` 49.9 % → 27.9 %,
`irq_demo` 99.5 % → 1.0 % — and costs cycles (`bloop` 4419 → 4857), yet **all
four programs still pass their byte-exact commit-trace diff**. The prediction is
a hint that only ever changes *when* instructions are fetched; correctness rests
entirely on the EX-stage resolution and flush.

`BHT_ENABLE = 0` forces every lookup to "not taken" and writes no counter, and
reproduces the static machine's cycle counts exactly — 4019 / 1880 / 900 on
`bloop` / `bsort` / `fib`, identical to the pre-predictor build. With the
outputs constant, synthesis prunes the array entirely.

`tb/tb_bht.v` unit-tests the module standalone with 2600 checks: the reset
state, saturation at both ends, the `state[1]` prediction boundary, index
aliasing (`pc` versus `pc + 256` versus `pc + 4`), the same-cycle read/write
ordering, `ENABLE = 0` inertness, and 600 randomised update/lookup steps against
a behavioural model.

### 9.2 Interrupt demonstration

`asm/prog/irq_demo.s` installs a handler in `mtvec`, enables `mie.MEIE` and
`mstatus.MIE`, and then runs a 200-iteration counting loop. The ISR pushes two
scratch registers, increments a visit counter, pops them and returns with
`mret`. It is written so that the architectural result does **not** depend on
when the interrupts land: the loop counter reaches 200 and the visit counter
equals the number of interrupts taken, whatever the timing.

The testbench drives `irq` as a level (`+IRQ_AT1/2/3=<cycle>`), holding it until
it observes the trap and then dropping it. Two runs are reported:

```
irq at cycles 200 and 500 (both outside the handler)

  IRQ_TRAP    cycle=201  squashed_pc=0000003c  mtvec=0000004c  mie=1  mpie=0
  IRQ_ENTERED mepc=0000003c  mcause=8000000b   mie=0  mpie=1
  IRQ_TAKEN   retire_index=153
  MRET        cycle=211  pc=00000068 -> mepc=0000003c  mie=0  mpie=1
  MRET_DONE   mie=1  mpie=1
  IRQ_TRAP    cycle=502  squashed_pc=0000003c  mtvec=0000004c  mie=1  mpie=1
  IRQ_ENTERED mepc=0000003c  mcause=8000000b   mie=0  mpie=1
  IRQ_TAKEN   retire_index=377
  MRET        cycle=512  ...                    mie=1  mpie=1
  IRQ_SUMMARY taken=2  mepc=0000003c  mcause=8000000b  mtvec=0000004c
```

```
irq at cycles 200 and 205 (the second lands INSIDE the handler, MIE = 0)

  IRQ_TRAP  cycle=201 ...        first interrupt taken normally
  MRET      cycle=211 ...        MIE restored to 1
  IRQ_TRAP  cycle=214 ...        held level taken 3 cycles after mret
```

That second run is the level-versus-pulse difference made visible: the interrupt
is not lost while the handler has interrupts disabled, it simply waits.

An `irq` held high for an entire run of `fib`, `bsort` or `bloop` — none of
which ever sets `MIE` — produces `taken=0`, leaves `mcause` at zero, and gives
cycle counts identical to the runs without it.

#### Aligning the RTL against the reference model

Diff-testing an interrupted program against the golden simulator needs one extra
step, and it is worth spelling out because it is a genuine methodological
problem rather than a detail.

The simulator's interrupt is scheduled by *retirement index*: `--irq-after N`
traps at the instruction boundary once N instructions have retired. The RTL has
no such notion — its interrupt is a level sampled in EX, and how many
instructions have retired at that moment depends on what happened to be in MEM
and WB, which in turn depends on the cycle chosen, the forwarding setting and
the branch predictor. Comparing the RTL against a trace generated with a fixed
`--irq-after` would compare two different executions.

So the index is **measured from the RTL rather than assumed**. When the trap
fires, `tb_program` records `mtvec`; when the first instruction at `mtvec`
subsequently retires, the number of trace lines already written is exactly the
reference model's N — every instruction older than the squashed one, and nothing
younger, has committed by then. The testbench prints it as
`IRQ_TAKEN retire_index=<N>`, and `tools/run_tests.py --irq-at` feeds those
measured values back into `iss.py --irq-after` and diffs the two traces byte for
byte (normalising line endings, since xsim writes CRLF on Windows and the
simulator writes LF).

With that alignment, `irq_demo` matches the reference model **exactly, all 633
lines**, at every combination of `FORWARDING` and `BHT_ENABLE`. The register
check still uses the committed `.regs` fixture, which is timing-independent by
construction.

#### Directed check

`tb/tb_irq.v` verifies the round trip structurally rather than by diffing,
with 21 assertions over the whole trap: that the trap only fires with a valid
instruction in EX; that `mepc` equals the squashed instruction's PC and
`mcause` is `0x8000000B`; that `MPIE` captures the old `MIE` and `MIE` is
cleared on entry and restored by `mret`; that at most two instructions retire
between the trap and the handler's first instruction; that the squashed
instruction does **not** retire inside the handler; that the first instruction
to retire after `mret` is the one at `mepc`; and that the program still finishes
with the loop counter at 200, the ISR visit counter at 1 and every callee-saved
value restored. It passes at both forwarding settings, both predictor settings
and four different interrupt cycles.

### 9.3 Instruction cache — designed, not implemented

The third bonus item is written up but not built. The design that was on the
table:

| Parameter | Value |
|---|---|
| Organisation | direct-mapped |
| Lines | 128 |
| Line size | 16 B (4 instructions) |
| Capacity | 2 KB |
| Index | `pc[10:4]` |
| Tag | `pc[31:11]` |
| Write policy | none needed — instruction fetch is read-only |
| Miss handling | stall IF, fetch four words from main memory, fill, replay |

It was cut for two reasons, and both are worth stating rather than glossing:

1. **There is nothing to measure.** The cache would sit in front of a memory
   that already answers in one cycle. A hit and a miss would cost the same,
   so the hit-rate counter would be the only observable output and the CPI
   would not move at all. Making it meaningful requires a multi-cycle main
   memory model — a second memory subsystem, a stall path through IF, and a
   refill state machine — which is a larger change than the cache itself.
2. **The measurement would be trivial anyway.** Instruction memory is 4 KB and
   the largest test program is well under 2 KB, so after the first pass the
   entire working set is resident and the hit rate would be ~99 % on every
   program. A number that is 99 % regardless of the program says nothing about
   the design.

The engineering judgement was that a working, measured branch predictor and a
working, verified interrupt are worth more than a third bonus whose headline
figure would be an artefact of the test setup. The pipeline is structured so the
cache could be added later without touching the datapath: `imem.v` already
presents a synchronous-read interface with an enable, and IF already has a stall
path.

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
| BHT trained with the inverted outcome (`update_taken = ~branch_cond`) | `bht.v` | *nothing* — see below |
| Load-use interlock qualifiers (`id_uses_rs1`/`id_uses_rs2`) removed | `hazard_unit.v` | *nothing* — see below |

The last four are datapath-level bugs with no meaningful unit-level DUT of
their own (forwarding and the load-use stall only manifest across the pipeline
boundary they cross), so they are caught by the hazard programs of section
10.6 and the per-instruction programs of 10.5 rather than by an isolated
module testbench — consistent with the fact that `forward_unit.v` and
`hazard_unit.v` are combinational functions of pipeline-register fields, not
of anything a standalone testbench could drive meaningfully on its own.

The last two rows are a different kind of mutation, included deliberately even
though nothing flags them as `FAIL`: they probe what the trace diff can and
cannot detect, rather than catching a bug.

Training the BHT with the inverted outcome collapses prediction accuracy —
`fib` 93.4 % → 3.3 %, `bsort` 75.3 % → 25.3 %, `bloop` 49.9 % → 27.9 %,
`irq_demo` 99.5 % → 1.0 % — and costs cycles (`bloop` 4419 → 4857 cycles), yet
**every program still passes the byte-exact commit-trace diff**. That is not a
hole in the test suite; it is the correct outcome. The predictor only changes
*when* instructions are fetched, never what they compute — correctness rests
entirely on the EX-stage resolution and flush (section 6.3), and the trace
diff is exactly the check that should be blind to a misprediction rate.

Removing the load-use interlock's `id_uses_rs1`/`id_uses_rs2` qualifiers — so
the hazard unit stalls on whatever sits in an instruction's raw `rs1`/`rs2`
fields, over-approximating the interlock to instructions that do not actually
read them (`lui`, `auipc`, `jal`, the `csrr*i` forms, `ecall`) — is likewise
still correct in every suite; it only costs cycles (`bloop` at
`FORWARDING = 0`: 5313 → 5515). This is the same mutation that, before the
ID-redirect rule of section 6.3 was adopted, used to break `asm/prog/bloop`
outright: a spuriously stalled `jal` was bubbled out of ID/EX right after it
had already redirected, silently losing its link write — which is why that
rule exists. Under the current rule (an ID-stage redirect only fires once its
own instruction is no longer stalled) the same mutation is harmless to
correctness and costs only cycles.

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
| `bpred.s` | branch-prediction demonstration: nested counted loops, bit-count, linear search, triangular sum; every back-edge a conditional branch, 1675 dynamic conditional branches, 86 % taken | 5877 | zero differing trace lines; identical register file (x28–x31 checksums) |
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
runs are sequential rather than parallel, which is why `tools/run_tests.py`
exists as a batch driver rather than invoking `run.sh` once per program by
hand. It also hoists compilation out of the per-program loop: every program in
one invocation uses the same design and the same generics — only the `+PROG`
plusarg differs — so the programs are grouped by their (`FORWARDING`,
`BHT_ENABLE`) pair, one `xvlog` + `xelab` builds a snapshot for the group
(`run.sh --elab-only --tag <group>`), and each program is then a bare `xsim`
launch against it (`run.sh --sim-only --tag <group>`). Because it is literally
the same snapshot and the same plusargs, the verdicts and cycle counts are
unchanged; the 46-program per-instruction suite went from 347 s to 144 s.
`--no-batch` restores the recompile-per-program path.

### 10.10 Results summary

*Measured by the orchestrator on the final RTL (BHT + interrupt), every suite
re-run independently of the implementing engineer. Program suites were run at
all four `FORWARDING` × `BHT_ENABLE` combinations unless noted.*

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
| `tb_bht` | 2600 checks | PASS | — |
| `tb_irq` | 21 assertions | PASS | PASS |
| `asm/insn/*` | 46 programs | 46/46 (BHT on and off) | 46/46 |
| `asm/hazard/*` | 9 programs | 9/9 (BHT on and off) | 9/9 (BHT on and off) |
| `asm/prog/*` | 5 programs (irq at cycles 200, 500) | 5/5 (BHT on and off) | 5/5 (BHT on and off) |
| `tb/bringup/*` | 7 programs | 7/7 (BHT on and off) | 7/7 |
| `asm/smoke.s` | 1 program, all 46 encodings | PASS | PASS |
| `tools/test_tools.py` | 4323 checks | PASS (tool-level, not RTL) | — |

---

## 11. Performance

All numbers below are measured in xsim with a 10 ns clock; cycles are counted
from reset release to `done`, and CPI = cycles / retired instructions.
`irq_demo` is run with the interrupt asserted at cycles 200 and 500.

### 11.1 Cycle costs per event

| Event | Cost |
|---|---|
| Load-use stall | 1 cycle |
| `jal` | 1 bubble |
| Taken conditional branch, prediction off (static not-taken) | 2 bubbles |
| `jalr` | 2 bubbles |
| `ecall` / external interrupt / `mret` | 2 bubbles |
| BHT: predicted-taken, correct | 1 bubble |
| BHT: predicted-not-taken, correct | 0 bubbles |
| BHT: mispredict, either direction | 2 bubbles |
| `FORWARDING = 0`: RAW against an EX producer | 2 stall cycles |
| `FORWARDING = 0`: RAW against a MEM producer | 1 stall cycle |
| `FORWARDING = 0`: RAW against a WB producer | 0 — served by the register-file WB→ID bypass |

### 11.2 Forwarding on vs. off

BHT off (the base machine) throughout this table — the course's "show the
performance of your CPU" comparison:

| Program | Insns | Cycles, fwd=1 | CPI | `lu_stalls` | Cycles, fwd=0 | CPI | Stalls | Speedup |
|---|---|---|---|---|---|---|---|---|
| `fib` | 658 | 900 | 1.368 | 62 | 1489 | 2.263 | 651 | 1.65× |
| `bsort` | 1366 | 1880 | 1.376 | 136 | 2601 | 1.904 | 857 | 1.38× |
| `bloop` | 2878 | 4019 | 1.396 | 0 | 4913 | 1.707 | 894 | 1.22× |
| **total (3)** | 4902 | 6799 | 1.387 | 198 | 9003 | 1.837 | 2402 | 1.32× |

The same comparison over the full suites: the hazard suite (9 programs) is
CPI 1.429 (fwd=1) vs. 2.044 (fwd=0); the per-instruction suite (46 programs)
is 1.269 vs. 1.369. Ideal CPI is 1.0 in both cases; the residual at `fwd=1` is
entirely control-flow flushes (2 bubbles per taken branch/`jalr`, 1 per `jal`)
plus load-use stalls — there is no other source of a stall or a bubble in this
design.

`fib` benefits the most from forwarding (1.65×) because its inner loop is a
tight dependent chain — each iteration's addition consumes the previous
iteration's result almost immediately, so every one of those RAW hazards is a
stall at `fwd=0` and free at `fwd=1`. `bloop` benefits the least (1.22×)
despite having the most instructions, for two reasons that compound: its
`lu_stalls` count is **zero even at `fwd=1`** — its loop bodies compute
independent quantities, so it was never paying the one hazard forwarding
actually removes — and its `fwd=0` penalty (894 stall cycles) is therefore
pure ordinary-RAW stall, the cost forwarding pays for on every other program
for free. `bloop` shows what forwarding is *for* in the negative: a program
with no producer-consumer adjacency has nothing for the bypass network to
save.

### 11.3 Branch prediction (`FORWARDING = 1`)

| Program | Cond. branches | Static-NT acc. | Cycles, BHT off | BHT misses | BHT acc. | Cycles, BHT on | Δ cycles |
|---|---|---|---|---|---|---|---|
| `fib` | 91 | 3.3 % | 900 | 6 | 93.4 % | 821 | −79 (−8.8 %) |
| `bsort` | 288 | 70.1 % | 1880 | 71 | 75.3 % | 1890 | +10 (+0.5 %) |
| `bloop` | 891 | 72.4 % | 4019 | 446 | 49.9 % | 4419 | +400 (+10.0 %) |
| `bpred` | 1675 | 14.5 % | 8921 | 76 | 95.5 % | 7625 | −1296 (−14.5 %) |
| `irq_demo` | 201 | 99.5 % | 849 | 1 | 99.5 % | 849 | 0 |

`bpred` (5877 instructions, all loop back-edges conditional, 86 % of dynamic
branches taken) is the program the predictor is *for*: 14.5 % static-not-taken
accuracy means almost every one of those back-edges would cost 2 bubbles under
the base machine, and the BHT converts nearly all of them into 1-bubble
correctly-predicted-taken redirects.

`bloop` is the counter-example, and it is adversarial by construction: its
inner `beq` tests `k & 1` and therefore alternates taken/not-taken on every
iteration — the one pattern a 2-bit saturating counter cannot learn, so it
mispredicts that branch 100 % of the time — and its three loop back-edges are
all `j` (`jal`), giving the predictor nothing to win on at all. The
arithmetic closes exactly: 446 misses × 2 bubbles = 892 penalty cycles under
the BHT, versus 246 taken branches × 2 bubbles = 492 penalty cycles under
static not-taken, a difference of 400 cycles — matching the measured
4419 − 4019 = 400 exactly.

BHT off reproduces the base machine bit-for-bit: the cycle counts in this
table's "BHT off" column are identical to the `fwd=1` column of section 11.2,
because `BHT_ENABLE = 0` forces every prediction to not-taken and updates no
counter.

### 11.4 Interrupt demonstration

From the simulation log (`irq_demo`, interrupts asserted at cycles 200 and 500):

```
IRQ_TRAP    cycle=201  squashed_pc=0000003c  mtvec=0000004c  mie_before=1  mpie_before=0
IRQ_ENTERED mepc=0000003c mcause=8000000b    mie_after=0     mpie_after=1
IRQ_TAKEN   retire_index=153 mepc=0000003c mcause=8000000b mtvec=0000004c
MRET        cycle=211  pc=00000068 -> mepc=0000003c  mie_before=0 mpie_before=1
MRET_DONE   mie_after=1 mpie_after=1
IRQ_TRAP    cycle=502  squashed_pc=0000003c ... mie_before=1 mpie_before=1
IRQ_TAKEN   retire_index=377
IRQ_SUMMARY taken=2 mepc=0000003c mcause=8000000b mtvec=0000004c mie=1 mpie=1
```

Re-running the golden ISS with `--irq-after 153 --irq-after 377` (the retire
indices measured from the RTL log itself, per the alignment procedure of
section 9.2) produces **0 differing trace lines over 633**.

An interrupt raised while `MIE = 0` — i.e. while the ISR from the first
interrupt is still running — is held rather than dropped: it is taken 3 cycles
after the pending `mret` restores `MIE`. An interrupt raised while `MIE` was
never set at all (running `fib`, `bsort` or `bloop`, none of which touch the
CSRs) has no effect whatsoever — `taken = 0`, `mcause` stays at its reset
value, and the cycle count is identical to the same program run with no
interrupt asserted. Final architectural state: `x10 = 200` (the main loop's
counter) and `x11 = 2` (the ISR's visit counter).

### 11.5 Synthesis (Vivado 2026.1, xc7a35tcpg236-1, out-of-context, post place-and-route)

*Re-measured 2026-09-07. Every number in this section is read out of
`vivado/reports/` — see the note on the superseded measurement at the end.*

| Design | Constraint | LUT | of which memory | FF | BRAM | WNS | TNS | Failing endpoints | fmax = 1/(T − WNS) |
|---|---|---|---|---|---|---|---|---|---|
| Base machine (`BHT_ENABLE = 0`) | 10.0 ns | 1245 | 44 | 689 | 2 | −2.483 ns | −771.0 ns | 423 / 2694 | 80.1 MHz |
| Full (BHT + interrupt) | 10.0 ns | 1461 | 44 | 819 | 2 | −3.235 ns | −1341.7 ns | 555 / 2956 | 75.6 MHz |
| Full (BHT + interrupt) | 12.5 ns | 1455 | 44 | 819 | 2 | −0.755 ns | −67.6 ns | 306 / 2956 | 75.4 MHz |
| **Full (BHT + interrupt)** | **13.5 ns** | **1424** | **44** | **819** | **2** | **+0.052 ns** | **0.000 ns** | **0 / 2956** | **74.4 MHz (met)** |

Reproduce with `vivado/synth.sh --impl [--period NS] [--generic BHT_ENABLE=0 --tag base]`.

**Operating point.** The full design **closes setup timing at 13.5 ns —
74 MHz** (`timing_13.5ns.txt`, WNS +0.052 ns, TNS 0, zero failing endpoints).
100 MHz is not met (WNS −3.235 ns) and neither is 80 MHz (−0.755 ns). The
three constraint points agree with each other to within 1.2 %: 1/(T − WNS)
lands at 75.6, 75.4 and 74.4 MHz, which is the useful cross-check — the number
is a property of the design, not of the constraint it was asked to meet.
74 MHz is quoted as the operating point rather than 75.6 MHz because it is the
one a run actually demonstrated by closing.

**Out-of-context.** `cpu_top`'s ports include 361 commit-trace and
performance-counter bits, far more than the 106 I/O pins the `cpg236` package
offers, so synthesis runs `-mode out_of_context`: no I/O buffers, and the clock
is not assigned to a BUFG. That is also the methodologically correct way to
characterise a core that is not pinned out to a board — the numbers describe
the core's logic, not a particular top-level pinout. The caveat it carries is
in the hold discussion below.

**Port constraints.** The trace and performance-counter outputs are
observation-only: they exist so the self-checking testbenches can watch the
pipeline (section 10) and on a real board would not be bonded out. Giving them
a real output delay would invent a timing requirement that does not exist and
would distort the reported critical path, so `constraints.xdc` declares them
false paths — with a 0 ns output delay alongside, purely because Vivado's
`check_timing` counts a port as constrained only if it carries an actual delay
object and would otherwise keep listing all 361 as unconstrained. `rst`, `irq`
and `done` are real I/O and are constrained (0 ns external delay:
out-of-context synthesis has no board model to reference). `check_timing` is
consequently clean — 0 unconstrained inputs, 0 unconstrained outputs, 0
unconstrained internal endpoints — where the earlier runs reported 2 and 361.

**Memory inference.** All three arrays map where they should, and this is
checked rather than assumed: `vivado/reports/memory*.txt` is a
`get_cells -hierarchical` dump of every memory primitive with its hierarchical
path.

| Array | Size | Maps to | Evidence |
|---|---|---|---|
| `u_imem/mem` | 1024 × 32 ROM | 1 × `RAMB36E1` (`u_imem/inst_reg`) | `memory.txt`; the read is registered, so the attribute is satisfiable |
| `u_dmem/mem` | 1024 × 32 RAM | 1 × `RAMB36E1` (`u_dmem/mem_reg`) | Final Mapping Report: `1 K x 32(READ_FIRST)` / `1 K x 32(WRITE_FIRST)`, byte-write lanes |
| `u_regfile/regs` | 32 × 32, 2 async read ports | 12 × `RAM32M` = 44 LUTs | Final Mapping Report: `Inference = User Attribute` |

This required `(* ram_style *)` attributes on all three (`rtl/imem.v`,
`rtl/dmem.v`, `rtl/regfile.v`). Left to itself Vivado made the opposite choice
on every one of them: it constant-folded the sparsely-initialised instruction
ROM into LUT logic and dropped it from the netlist entirely, put the data
memory in 512 `RAMS64E` distributed-RAM cells, and packed the register file —
the one array that genuinely wants LUT RAM, because two asynchronous read ports
are exactly what distributed RAM provides and block RAM does not — into the
design's only block RAM. Vivado also warns (`Synth 8-7052`) that neither block
RAM could absorb an optional output register, which is accurate: both reads
feed combinational logic in the same stage, and that shows up directly in the
critical path below.

**Critical path (full design, 10 ns constraint): 12.982 ns, 15 logic levels,
65 % routing.** From `u_dmem/mem_reg/CLKBWRCLK` to `u_pc/pc_q_reg[31]/CE` —
the load-to-branch path:

1. DMEM block-RAM clock-to-output, `CLKBWRCLK → DOBDO`: **2.454 ns**, 19 % of
   the path in one hop and the single largest term;
2. the byte-lane select and sign/zero extension of the load result (2 × LUT6).
   `dmem.v` registers the memory word on the MEM clock edge and the extension is
   combinational on that registered value, so this logic belongs to WB;
3. the MEM/WB → EX forwarding mux, delivering that load result to a dependent
   branch. The EX/MEM path cannot serve a load — it carries the ALU result,
   which for a load is the effective address (section 6.1);
4. the branch comparator's carry chain (3 × CARRY4) producing `branch_cond`;
5. the redirect / flush / stall reduction;
6. into the PC register's clock enable.

That is the deepest combinational chain in the machine: a load result reaching
the branch comparator through forwarding within one cycle, and then deciding
the next PC. At 13.5 ns the same source drives `u_imem/inst_reg/ENARDEN`
instead — the other consumer of the same stall term — for 12.921 ns over 17
levels. Note that step 1 did not exist in the earlier measurement: with DMEM in
distributed RAM the read was roughly 1 ns, and the block RAM's 2.454 ns is most
of the difference between the old headline number and this one. Mapping the
memories correctly costs fmax; it also makes the number mean something.

**Hold.** Never examined before this measurement, and now reported explicitly
because a post-route hold violation would be a real bug rather than a missed
target. `WHS = −0.120 ns` across 483 failing endpoints at every constraint
point — hold is period-independent, which is the first clue about what it is.
`hold.txt` lists the twenty worst hold paths and **every one of them starts at
the `rst` input port** (fanout 485, matching the 483 failing endpoints).
`hold_reg2reg.txt` — the same analysis restricted to register-to-register paths
— is **MET at +0.071 ns** (full @ 10 ns), +0.112 ns (full @ 13.5 ns) and
+0.119 ns (base machine). **There are no internal hold violations.**

The `rst` violation is an artifact of the out-of-context flow, and Vivado says
so itself in the same run: `[Timing 38-242] The property HD.CLK_SRC of clock
port "clk" is not set. In out-of-context mode, this prevents timing estimation
for clock delay/skew`, and `[Route 35-198] Port "rst" does not have an
associated HD.PARTPIN_LOCS ... timing analysis to/from this port will not be
accurate`. Concretely: with no BUFG the destination registers see the clock
after 0.973 ns of general routing, while `rst` is declared to arrive with 0 ns
input delay, so the tool sees data arriving 0.973 ns "early" relative to a
clock edge that a real global buffer would have delayed identically at both
ends. In a top-level design with the clock on a BUFG, or with `HD.CLK_SRC` and
`HD.PARTPIN_LOCS` set, the check disappears. It is not evidence of a design
problem, and it is stated here rather than omitted because the alternative —
quoting WNS and saying nothing about WHS — is exactly what let it go
unexamined.

**The 100 MHz target is not met.** Two standard fixes are named as future work
rather than attempted under the feature freeze; the re-measurement sharpens the
ordering, because the critical path now demonstrably begins at the DMEM block
RAM:

1. **Register the DMEM output lane-extension into WB** — move the byte-lane
   selection and sign/zero extension out of MEM and behind the MEM/WB register.
   This is now clearly the first fix rather than one of two equals: it takes
   steps 2–3 of the path above out of the same cycle as the 2.454 ns block-RAM
   read. It reshapes the load-use interlock, so it is a datapath change, not a
   local one.
2. **Pipeline the forwarding compare** by precomputing the `rs == rd` match
   bits in ID, where the register addresses are available a cycle earlier,
   instead of comparing them combinationally in EX.

A third option is specific to the memories: both `Synth 8-7052` messages say
the block RAMs could absorb an output register if one were provided, which
would turn step 1 into a clock-to-out of roughly 0.4 ns at the cost of one
extra cycle of memory latency — a pipeline-depth change, and therefore out of
scope under the freeze.

Neither is implemented; both are within the datapath's existing structure
(section 5) and would not change any instruction's architectural behaviour.

> **Superseded measurement.** Before 2026-09-07 this section reported 2173 LUT
> / 960 FF / 1 BRAM / WNS −1.39 ns → "fmax ≈ 88 MHz", and claimed IMEM was in
> block RAM, that DMEM had been moved to LUT RAM for timing, and that the
> register file was distributed. All four were wrong, and for one root cause:
> synthesis initialised IMEM with `asm/smoke.hex`, a ~60-instruction bring-up
> program, and with no `ram_style` attribute Vivado optimised the instruction
> memory out of the design altogether. The single block RAM in that netlist was
> the register file. Those numbers characterised the loaded program, not the
> CPU, and are recorded here only so the change is traceable.
