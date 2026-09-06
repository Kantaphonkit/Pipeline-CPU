#!/usr/bin/env python3
"""Cross-validation of tools/asm.py against tools/iss.py.

    python tools/test_tools.py

Exit code 0 on success, 1 on any failure.  Prints the number of checks run.

Coverage:
  * a table of hand-verified 32-bit encodings (derived from the RISC-V spec
    field layouts by hand, NOT from asm.py output)
  * encode -> decode round trip on all 46 encodings including every
    immediate-format boundary value
  * ISS semantics (sign extension, partial stores, comparisons, shifts,
    jumps, branches, traps, interrupts, CSR read-modify-write, x0)
  * pseudo-instruction expansion
  * assembler error cases
  * byte-exact commit-trace output through the CLI
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import asm                                                   # noqa: E402
import iss                                                   # noqa: E402

CHECKS = 0
FAILURES = []


def check(cond, msg):
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILURES.append(msg)
    return bool(cond)


def eq(got, want, msg):
    return check(got == want, "%s: got %r, want %r" % (msg, got, want))


def eqx(got, want, msg):
    return check(got == want,
                 "%s: got 0x%08x, want 0x%08x" % (msg, got & 0xFFFFFFFF,
                                                  want & 0xFFFFFFFF))


def enc(text, pc=0, symbols=None):
    """Assemble one source line into a single word."""
    parts = text.strip().split(None, 1)
    mnem = parts[0]
    ops = [o.strip() for o in parts[1].split(',')] if len(parts) > 1 else []
    return asm.encode(mnem, *ops, pc=pc, symbols=symbols)


def enc_all(text, pc=0, symbols=None):
    parts = text.strip().split(None, 1)
    mnem = parts[0]
    ops = [o.strip() for o in parts[1].split(',')] if len(parts) > 1 else []
    return asm.encode_all(mnem, *ops, pc=pc, symbols=symbols)


def run_src(src, irq_after=(), max_insns=20000):
    text, data, syms = asm.assemble(src)
    cpu = iss.Cpu(text, data, irq_after=irq_after, max_insns=max_insns)
    code = cpu.run(collect=True)
    return cpu, code, syms


def expect_error(src, what):
    try:
        asm.assemble(src)
    except asm.AsmError:
        return check(True, what)
    return check(False, "%s: expected AsmError, none raised" % what)


# ==========================================================================
# 1. Hand-verified encodings
# ==========================================================================

KNOWN_ENCODINGS = [
    # --- the ones named in the task ---
    ("addi x1, x0, -1",         0xfff00093),
    ("lui x5, 0xfffff",         0xfffff2b7),
    ("jal x1, 8",               0x008000ef),   # at PC 0
    ("beq x1, x2, -4",          0xfe208ee3),
    ("sw x2, -4(x8)",           0xfe242e23),
    ("srai x1, x2, 5",          0x40515093),
    ("csrrwi x0, mstatus, 8",   0x30045073),
    ("mret",                    0x30200073),
    ("ebreak",                  0x00100073),
    ("ecall",                   0x00000073),
    # --- R-type (funct7<<25 | rs2<<20 | rs1<<15 | funct3<<12 | rd<<7 | 0x33) ---
    ("add x1, x2, x3",          0x003100b3),
    ("sub x5, x6, x7",          0x407302b3),
    ("sll x1, x2, x3",          0x003110b3),
    ("slt x10, x11, x12",       0x00c5a533),
    ("sltu x1, x2, x3",         0x003130b3),
    ("xor x1, x2, x3",          0x003140b3),
    ("srl x1, x2, x3",          0x003150b3),
    ("sra x1, x2, x3",          0x403150b3),
    ("or x1, x2, x3",           0x003160b3),
    ("and x1, x2, x3",          0x003170b3),
    # --- I-arith ---
    ("addi x0, x0, 0",          0x00000013),   # canonical NOP
    ("slti x1, x2, -2048",      0x80012093),
    ("sltiu x3, x4, 2047",      0x7ff23193),
    ("xori x1, x1, -1",         0xfff0c093),
    ("ori x2, x3, 0x7f",        0x07f1e113),
    ("andi x5, x6, 255",        0x0ff37293),
    ("slli x1, x2, 31",         0x01f11093),
    ("srli x1, x2, 0",          0x00015093),
    # --- loads ---
    ("lw x3, 0(x2)",            0x00012183),
    ("lb x1, -1(x0)",           0xfff00083),
    ("lbu x2, 2047(x1)",        0x7ff0c103),
    ("lh x1, 4(x2)",            0x00411083),
    ("lhu x1, 4(x2)",           0x00415083),
    # --- stores ---
    ("sb x1, 0(x2)",            0x00110023),
    ("sh x3, 6(x4)",            0x00321323),
    ("sw x5, 2047(x6)",         0x7e532fa3),
    # --- branches (PC 0, numeric byte offsets) ---
    ("bne x1, x2, 8",           0x00209463),
    ("blt x1, x2, 4094",        0x7e20cfe3),
    ("bge x3, x4, -4096",       0x8041d063),
    ("bltu x1, x0, 0",          0x0000e063),
    ("bgeu x2, x1, -2",         0xfe117fe3),
    # --- U-type ---
    ("lui x1, 0",               0x000000b7),
    ("auipc x2, 1",             0x00001117),
    ("auipc x31, 0xfffff",      0xffffff97),
    # --- jumps ---
    ("jal x0, -4",              0xffdff06f),
    ("jalr x1, 0(x5)",          0x000280e7),
    ("jalr x0, 0(x1)",          0x00008067),   # canonical RET
    ("jalr x1, -2048(x2)",      0x800100e7),
    # --- CSR ---
    ("csrrw x1, mtvec, x2",     0x305110f3),
    ("csrrs x0, mstatus, x0",   0x30002073),
    ("csrrc x3, mie, x4",       0x304231f3),
    ("csrrsi x0, mie, 31",      0x304fe073),
    ("csrrci x2, 0xfff, 0",     0xfff07173),
    ("csrrwi x0, mepc, 8",      0x34145073),
]


def test_known_encodings():
    for src, want in KNOWN_ENCODINGS:
        try:
            got = enc(src)
        except asm.AsmError as e:
            check(False, "encode %r raised %s" % (src, e))
            continue
        eqx(got, want, "encoding of %r" % src)
    # the same table must decode back to the right mnemonic
    for src, want in KNOWN_ENCODINGS:
        mnem = src.split()[0]
        d = iss.decode(want)
        eq(d.mnem, mnem, "decode 0x%08x mnemonic" % want)


# ==========================================================================
# 2. Encode/decode round trip over all 46 encodings
# ==========================================================================

REGSETS = [(0, 0, 0), (1, 2, 3), (31, 31, 31), (5, 0, 31), (15, 31, 0),
           (31, 15, 1)]
I_IMMS = [-2048, -1000, -1, 0, 1, 7, 2047]
S_IMMS = [-2048, -33, -1, 0, 1, 32, 2047]
B_OFFS = [-4096, -2050, -2, 0, 2, 2048, 4094]
J_OFFS = [-1048576, -4098, -2, 0, 2, 4096, 1048574]
U_IMMS = [0, 1, 0x7FFFF, 0x80000, 0xFFFFF]
SHAMTS = [0, 1, 5, 30, 31]
CSRS = [0x000, 0x300, 0x304, 0x305, 0x341, 0x342, 0x7FF, 0xFFF]
ZIMMS = [0, 1, 16, 31]


def test_roundtrip():
    seen = set()

    def rt(src, mnem, **fields):
        w = enc(src)
        d = iss.decode(w)
        seen.add(d.mnem)
        eq(d.mnem, mnem, "round trip mnemonic for %r" % src)
        for k, v in fields.items():
            eq(getattr(d, k), v, "round trip %s for %r" % (k, src))

    # R-type
    for m in sorted(asm.R_INSNS):
        for rd, rs1, rs2 in REGSETS:
            rt("%s x%d, x%d, x%d" % (m, rd, rs1, rs2), m,
               rd=rd, rs1=rs1, rs2=rs2)
    # I-arith
    for m in sorted(asm.I_ARITH):
        for rd, rs1, _ in REGSETS[:3]:
            for imm in I_IMMS:
                rt("%s x%d, x%d, %d" % (m, rd, rs1, imm), m,
                   rd=rd, rs1=rs1, imm=imm)
    # shifts
    for m in sorted(asm.I_SHIFT):
        for rd, rs1, _ in REGSETS[:3]:
            for sh in SHAMTS:
                rt("%s x%d, x%d, %d" % (m, rd, rs1, sh), m,
                   rd=rd, rs1=rs1, imm=sh)
    # loads
    for m in sorted(asm.LOADS):
        for rd, rs1, _ in REGSETS[:3]:
            for imm in I_IMMS:
                rt("%s x%d, %d(x%d)" % (m, rd, imm, rs1), m,
                   rd=rd, rs1=rs1, imm=imm)
    # stores
    for m in sorted(asm.STORES):
        for _, rs1, rs2 in REGSETS[:3]:
            for imm in S_IMMS:
                rt("%s x%d, %d(x%d)" % (m, rs2, imm, rs1), m,
                   rs1=rs1, rs2=rs2, imm=imm)
    # branches
    for m in sorted(asm.BRANCHES):
        for _, rs1, rs2 in REGSETS[:3]:
            for off in B_OFFS:
                rt("%s x%d, x%d, %d" % (m, rs1, rs2, off), m,
                   rs1=rs1, rs2=rs2, imm=off)
    # U-type
    for m in ('lui', 'auipc'):
        for rd, _, _ in REGSETS[:3]:
            for u in U_IMMS:
                rt("%s x%d, %d" % (m, rd, u), m, rd=rd, imm=u)
    # jal
    for rd, _, _ in REGSETS[:3]:
        for off in J_OFFS:
            rt("jal x%d, %d" % (rd, off), 'jal', rd=rd, imm=off)
    # jalr
    for rd, rs1, _ in REGSETS[:3]:
        for imm in I_IMMS:
            rt("jalr x%d, %d(x%d)" % (rd, imm, rs1), 'jalr',
               rd=rd, rs1=rs1, imm=imm)
    # CSR register forms
    for m in sorted(asm.CSR_REG):
        for rd, rs1, _ in REGSETS[:3]:
            for csr in CSRS:
                rt("%s x%d, %d, x%d" % (m, rd, csr, rs1), m,
                   rd=rd, rs1=rs1, csr=csr)
    # CSR immediate forms
    for m in sorted(asm.CSR_IMM):
        for rd, _, _ in REGSETS[:3]:
            for csr in CSRS:
                for z in ZIMMS:
                    rt("%s x%d, %d, %d" % (m, rd, csr, z), m,
                       rd=rd, csr=csr, zimm=z)
    # fixed system instructions
    for m in ('ecall', 'ebreak', 'mret'):
        rt(m, m)

    eq(sorted(seen), sorted(asm.ALL_MNEMONICS),
       "round trip covered all 46 encodings")
    eq(len(asm.ALL_MNEMONICS), 46, "ALL_MNEMONICS holds 46 encodings")


def test_boundary_immediates():
    """Both extremes of every immediate format, checked bit-for-bit."""
    # I-type
    eqx(enc("addi x1, x0, -2048") >> 20, 0x800, "I-type -2048 field")
    eqx(enc("addi x1, x0, 2047") >> 20, 0x7FF, "I-type +2047 field")
    eq(iss.decode(enc("addi x1, x0, -2048")).imm, -2048, "I-type -2048 decode")
    eq(iss.decode(enc("addi x1, x0, 2047")).imm, 2047, "I-type +2047 decode")
    eq(iss.decode(enc("addi x1, x0, -1")).imm, -1, "I-type -1 decode")
    eq(iss.decode(enc("addi x1, x0, 0")).imm, 0, "I-type 0 decode")
    # S-type
    for v in (-2048, -1, 0, 2047):
        eq(iss.decode(enc("sw x1, %d(x2)" % v)).imm, v, "S-type %d" % v)
    # B-type
    for v in (-4096, -2, 0, 2, 4094):
        eq(iss.decode(enc("beq x1, x2, %d" % v)).imm, v, "B-type %d" % v)
    # U-type
    eqx(enc("lui x1, 0"), 0x000000b7, "U-type 0")
    eqx(enc("lui x1, 0xfffff") >> 12, 0xFFFFF, "U-type 0xfffff field")
    eq(iss.decode(enc("auipc x1, 0xfffff")).imm, 0xFFFFF, "U-type max decode")
    # J-type
    for v in (-1048576, -2, 0, 2, 1048574):
        eq(iss.decode(enc("jal x1, %d" % v)).imm, v, "J-type %d" % v)
    # shift amounts
    for v in (0, 1, 31):
        for m in ('slli', 'srli', 'srai'):
            eq(iss.decode(enc("%s x1, x2, %d" % (m, v))).imm, v,
               "%s shamt %d" % (m, v))
    # CSR zimm and addresses
    for z in (0, 31):
        eq(iss.decode(enc("csrrwi x1, 0x300, %d" % z)).zimm, z,
           "csr zimm %d" % z)
    for a in (0x300, 0x341, 0xFFF):
        eq(iss.decode(enc("csrrw x1, %d, x2" % a)).csr, a, "csr addr 0x%x" % a)
    # sign extension actually happens in the ISS, not just the decoder
    cpu, code, _ = run_src("li a0, 0\n addi a0, a0, -2048\n"
                           "addi a1, x0, 2047\n ebreak\n")
    eq(code, 0, "boundary program halts")
    eqx(cpu.regs[10], 0xFFFFF800, "addi -2048 result")
    eqx(cpu.regs[11], 0x000007FF, "addi +2047 result")


# ==========================================================================
# 3. ISS semantics
# ==========================================================================

def test_load_sign_extension():
    src = """
        .text
        li   t0, 0
        li   t1, -1
        sw   t1, 0(t0)
        lb   a0, 0(t0)
        lbu  a1, 0(t0)
        lh   a2, 0(t0)
        lhu  a3, 0(t0)
        lw   a4, 0(t0)
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "sign-extension program halts")
    eqx(cpu.regs[10], 0xFFFFFFFF, "lb sign extends")
    eqx(cpu.regs[11], 0x000000FF, "lbu zero extends")
    eqx(cpu.regs[12], 0xFFFFFFFF, "lh sign extends")
    eqx(cpu.regs[13], 0x0000FFFF, "lhu zero extends")
    eqx(cpu.regs[14], 0xFFFFFFFF, "lw")

    src2 = """
        li   t0, 0
        li   t1, 0x7f80
        sw   t1, 0(t0)
        lb   a0, 0(t0)          # byte 0 = 0x80 -> -128
        lbu  a1, 0(t0)
        lb   a2, 1(t0)          # byte 1 = 0x7f -> +127
        lh   a3, 0(t0)          # half   0x7f80 -> +32640
        li   t2, -32768
        sh   t2, 0(t0)
        lh   a4, 0(t0)
        lhu  a5, 0(t0)
        ebreak
    """
    cpu, code, _ = run_src(src2)
    eq(code, 0, "sign-extension program 2 halts")
    eqx(cpu.regs[10], 0xFFFFFF80, "lb of 0x80")
    eqx(cpu.regs[11], 0x00000080, "lbu of 0x80")
    eqx(cpu.regs[12], 0x0000007F, "lb of 0x7f")
    eqx(cpu.regs[13], 0x00007F80, "lh of 0x7f80")
    eqx(cpu.regs[14], 0xFFFF8000, "lh of 0x8000")
    eqx(cpu.regs[15], 0x00008000, "lhu of 0x8000")


def test_partial_stores():
    src = """
        li   t0, 0
        li   t1, 0x12345678
        sw   t1, 0(t0)
        li   t2, 0xab
        sb   t2, 1(t0)
        lw   a0, 0(t0)          # 0x1234ab78
        li   t3, 0xbeef
        sh   t3, 2(t0)
        lw   a1, 0(t0)          # 0xbeefab78
        sb   t2, 3(t0)
        lw   a2, 0(t0)          # 0xabefab78
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "partial-store program halts")
    eqx(cpu.regs[10], 0x1234AB78, "sb into byte 1")
    eqx(cpu.regs[11], 0xBEEFAB78, "sh into upper half")
    eqx(cpu.regs[12], 0xABEFAB78, "sb into byte 3")
    eqx(cpu.dmem[0], 0xABEFAB78, "dmem word 0")


def test_comparisons():
    src = """
        li   a0, -1
        li   a1, 1
        slt   t0, a0, a1        # 1 (signed  -1 < 1)
        sltu  t1, a0, a1        # 0 (unsigned 0xffffffff > 1)
        slti  t2, a0, 0         # 1
        sltiu t3, a0, 0         # 0
        sltiu t4, a1, -1        # 1 (1 < 0xffffffff unsigned)
        slti  t5, a1, -1        # 0
        slt   t6, a1, a0        # 0
        sltu  s0, a1, a0        # 1
        sltiu s1, x0, 1         # 1  (seqz idiom)
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "comparison program halts")
    eq(cpu.regs[5], 1, "slt -1 < 1")
    eq(cpu.regs[6], 0, "sltu 0xffffffff < 1")
    eq(cpu.regs[7], 1, "slti -1 < 0")
    eq(cpu.regs[28], 0, "sltiu 0xffffffff < 0")
    eq(cpu.regs[29], 1, "sltiu 1 < 0xffffffff")
    eq(cpu.regs[30], 0, "slti 1 < -1")
    eq(cpu.regs[31], 0, "slt 1 < -1")
    eq(cpu.regs[8], 1, "sltu 1 < 0xffffffff")
    eq(cpu.regs[9], 1, "sltiu 0 < 1")


def test_shifts():
    src = """
        li   a0, -16            # 0xfffffff0
        srli t0, a0, 4          # 0x0fffffff
        srai t1, a0, 4          # 0xffffffff
        slli t2, a0, 4          # 0xffffff00
        li   a1, 4
        srl  t3, a0, a1         # 0x0fffffff
        sra  t4, a0, a1         # 0xffffffff
        sll  t5, a0, a1         # 0xffffff00
        li   a2, 36             # shamt masked to 4
        srl  t6, a0, a2         # 0x0fffffff
        sra  s0, a0, a2         # 0xffffffff
        sll  s1, a0, a2         # 0xffffff00
        li   a3, -1             # shamt masked to 31
        sll  s2, a1, a3         # 4 << 31 = 0
        srl  s3, a0, a3         # 1
        sra  s4, a0, a3         # 0xffffffff
        srai s5, a0, 31         # 0xffffffff
        srli s6, a0, 31         # 1
        slli s7, a1, 0          # 4
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "shift program halts")
    eqx(cpu.regs[5], 0x0FFFFFFF, "srli")
    eqx(cpu.regs[6], 0xFFFFFFFF, "srai")
    eqx(cpu.regs[7], 0xFFFFFF00, "slli")
    eqx(cpu.regs[28], 0x0FFFFFFF, "srl")
    eqx(cpu.regs[29], 0xFFFFFFFF, "sra")
    eqx(cpu.regs[30], 0xFFFFFF00, "sll")
    eqx(cpu.regs[31], 0x0FFFFFFF, "srl shamt masked (36 -> 4)")
    eqx(cpu.regs[8], 0xFFFFFFFF, "sra shamt masked (36 -> 4)")
    eqx(cpu.regs[9], 0xFFFFFF00, "sll shamt masked (36 -> 4)")
    eqx(cpu.regs[18], 0x00000000, "sll shamt masked (-1 -> 31)")
    eqx(cpu.regs[19], 0x00000001, "srl shamt masked (-1 -> 31)")
    eqx(cpu.regs[20], 0xFFFFFFFF, "sra shamt masked (-1 -> 31)")
    eqx(cpu.regs[21], 0xFFFFFFFF, "srai 31")
    eqx(cpu.regs[22], 0x00000001, "srli 31")
    eqx(cpu.regs[23], 0x00000004, "slli 0")


def test_jumps_and_auipc():
    src = """
        .text
        jal  ra, target         # 0   ra = 4
        ebreak                  # 4
target:                         # 8
        auipc a0, 0             # a0 = 8
        auipc a1, 1             # a1 = 12 + 0x1000
        la   t0, sub2           # 16 lui, 20 addi
        addi t0, t0, 1          # 24  set LSB
        jalr a2, 0(t0)          # 28  a2 = 32, jumps to sub2 (LSB cleared)
        ebreak                  # 32  halt
sub2:                           # 36
        addi a3, x0, 7
        jalr x0, 0(a2)          # return to 32
    """
    cpu, code, syms = run_src(src)
    eq(code, 0, "jump program halts")
    eqx(cpu.regs[1], 4, "jal link value")
    eqx(cpu.regs[10], 8, "auipc 0")
    eqx(cpu.regs[11], 12 + 0x1000, "auipc 1")
    eqx(cpu.regs[12], 32, "jalr link value")
    eqx(cpu.regs[13], 7, "jalr reached sub2 with LSB cleared")
    eq(syms['sub2'], 36, "label address of sub2")
    eq(syms['target'], 8, "label address of target")


def test_branches():
    """Every branch, taken and not taken."""
    cases = [
        ('beq',  5,  5, True), ('beq',  5,  6, False),
        ('bne',  5,  6, True), ('bne',  5,  5, False),
        ('blt', -1,  1, True), ('blt',  1, -1, False),
        ('bge',  1, -1, True), ('bge', -1,  1, False),
        ('bltu', 1, -1, True), ('bltu', -1, 1, False),
        ('bgeu', -1, 1, True), ('bgeu', 1, -1, False),
    ]
    for mnem, a, b, taken in cases:
        src = """
            li   t0, %d
            li   t1, %d
            li   a0, 0
            %s   t0, t1, taken
            li   a0, 100
            ebreak
        taken:
            li   a0, 200
            ebreak
        """ % (a, b, mnem)
        cpu, code, _ = run_src(src)
        eq(code, 0, "%s program halts" % mnem)
        eq(cpu.regs[10], 200 if taken else 100,
           "%s %d,%d taken=%s" % (mnem, a, b, taken))


def test_li_la_and_data():
    src = """
        .text
        li   a0, 0x12345678
        li   a1, -1
        li   a2, 2047
        li   a3, -2048
        li   a4, 0x800
        li   a5, 0xfffff800
        la   t0, table
        lw   a6, 0(t0)
        lw   a7, 4(t0)
        lbu  s0, 8(t0)
        lhu  s1, 10(t0)
        la   t1, blob
        lbu  s2, 0(t1)
        ebreak

        .data
table:  .word 0xdeadbeef, 0x00c0ffee
        .byte 0x5a
        .align 2
        .half 0xbeef
        .space 4
blob:   .byte 1, 2, 3, 4
    """
    cpu, code, syms = run_src(src)
    eq(code, 0, "li/la/data program halts")
    eqx(cpu.regs[10], 0x12345678, "li 0x12345678")
    eqx(cpu.regs[11], 0xFFFFFFFF, "li -1")
    eqx(cpu.regs[12], 2047, "li 2047 (single addi)")
    eqx(cpu.regs[13], 0xFFFFF800, "li -2048 (single addi)")
    eqx(cpu.regs[14], 0x800, "li 0x800 (lui+addi)")
    eqx(cpu.regs[15], 0xFFFFF800, "li 0xfffff800")
    eqx(cpu.regs[16], 0xDEADBEEF, ".word 0")
    eqx(cpu.regs[17], 0x00C0FFEE, ".word 1")
    eqx(cpu.regs[8], 0x5A, ".byte")
    eqx(cpu.regs[9], 0xBEEF, ".half after .align 2")
    eqx(cpu.regs[18], 1, ".byte blob[0]")
    eq(syms['table'], 0, "data label table")
    eq(syms['blob'], 16, "data label blob (align + half + space)")
    # li encodings
    eq(len(enc_all("li x1, 2047")), 1, "li 2047 is one instruction")
    eq(len(enc_all("li x1, 2048")), 2, "li 2048 is two instructions")
    eq(len(enc_all("li x1, -2048")), 1, "li -2048 is one instruction")
    eq(len(enc_all("li x1, -2049")), 2, "li -2049 is two instructions")


def test_hi_lo_pairs():
    """lui %hi + addi %lo must reconstruct the symbol for every low half."""
    for value in (0x00000000, 0x000007FF, 0x00000800, 0x00000FFF,
                  0x12345678, 0xFFFFFFFF, 0x00001000, 0xFFFFF7FF,
                  0x7FFFF800, 0x80000000):
        src = ("        .equ target, 0x%08x\n"
               "        lui  a0, %%hi(target)\n"
               "        addi a0, a0, %%lo(target)\n"
               "        ebreak\n" % value)
        cpu, code, _ = run_src(src)
        eq(code, 0, "%%hi/%%lo program halts for 0x%08x" % value)
        eqx(cpu.regs[10], value, "%%hi/%%lo reconstruction of 0x%08x" % value)


def test_x0_is_hardwired():
    src = """
        li   t0, 42
        add  x0, t0, t0
        addi x0, t0, 1
        lui  x0, 0xfffff
        li   a0, 0
        add  a0, x0, x0
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "x0 program halts")
    eq(cpu.regs[0], 0, "x0 stays zero")
    eq(cpu.regs[10], 0, "reads of x0 give zero")
    # and no trace line ever names x0
    for line in cpu.trace_lines:
        check(' x0=' not in line, "trace never prints x0: %r" % line)


def test_csr_read_modify_write():
    src = """
        li   t0, 0x888          # bits 3, 7, 11
        csrrw a0, mstatus, t0   # a0 = old (0)         mstatus <- MIE|MPIE
        csrrs a1, mstatus, x0   # a1 = 0x88 (read only, no write)
        li   t1, 0x08
        csrrc a2, mstatus, t1   # a2 = 0x88, clears MIE -> 0x80
        csrrs a3, mstatus, x0   # a3 = 0x80
        csrrs a4, mstatus, t1   # a4 = 0x80, sets MIE  -> 0x88
        csrrs a5, mstatus, x0   # a5 = 0x88
        csrrci a6, mstatus, 8   # a6 = 0x88, clears MIE -> 0x80
        csrrsi a7, mstatus, 0   # a7 = 0x80, no write
        csrrwi s0, mstatus, 8   # s0 = 0x80, mstatus <- 8
        csrrs s1, mstatus, x0   # s1 = 0x08
        csrrs s2, 0x7c0, x0     # unimplemented CSR reads 0
        li   t2, -1
        csrrw s3, 0x7c0, t2     # writes ignored
        csrrs s4, 0x7c0, x0     # still 0
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "CSR program halts")
    eqx(cpu.regs[10], 0x00000000, "csrrw returns old mstatus")
    eqx(cpu.regs[11], 0x00000088, "mstatus after csrrw 0x888 (MIE|MPIE only)")
    eqx(cpu.regs[12], 0x00000088, "csrrc returns pre-write value")
    eqx(cpu.regs[13], 0x00000080, "csrrc cleared MIE")
    eqx(cpu.regs[14], 0x00000080, "csrrs returns pre-write value")
    eqx(cpu.regs[15], 0x00000088, "csrrs set MIE")
    eqx(cpu.regs[16], 0x00000088, "csrrci returns pre-write value")
    eqx(cpu.regs[17], 0x00000080, "csrrsi zimm=0 does not write")
    eqx(cpu.regs[8], 0x00000080, "csrrwi returns pre-write value")
    eqx(cpu.regs[9], 0x00000008, "csrrwi wrote mstatus")
    eqx(cpu.regs[18], 0, "unimplemented CSR reads 0")
    eqx(cpu.regs[19], 0, "unimplemented CSR write returns 0")
    eqx(cpu.regs[20], 0, "unimplemented CSR stays 0")
    eq(cpu.mstatus_mie, 1, "mstatus.MIE bit")
    eq(cpu.mstatus_mpie, 0, "mstatus.MPIE bit")

    # rd = x0 still performs the write side
    src2 = """
        li   t0, 0x800
        csrrw x0, mie, t0
        csrrs a0, mie, x0
        ebreak
    """
    cpu2, code2, _ = run_src(src2)
    eq(code2, 0, "CSR rd=x0 program halts")
    eqx(cpu2.regs[10], 0x800, "csrrw with rd=x0 still wrote mie")
    eq(cpu2.mie_meie, 1, "mie.MEIE set")

    # mtvec / mepc force the low two bits to zero
    src3 = """
        li   t0, -1
        csrrw x0, mtvec, t0
        csrrs a0, mtvec, x0
        csrrw x0, mepc, t0
        csrrs a1, mepc, x0
        csrrw x0, mcause, t0
        csrrs a2, mcause, x0
        ebreak
    """
    cpu3, code3, _ = run_src(src3)
    eq(code3, 0, "mtvec/mepc program halts")
    eqx(cpu3.regs[10], 0xFFFFFFFC, "mtvec low bits are 00")
    eqx(cpu3.regs[11], 0xFFFFFFFC, "mepc low bits are 00")
    eqx(cpu3.regs[12], 0xFFFFFFFF, "mcause is fully writable")


ECALL_SRC = """
        .text
        la    t0, handler       # 0, 4
        csrrw x0, mtvec, t0     # 8
        csrrwi x0, mstatus, 8   # 12  MIE = 1
        addi  a0, x0, 1         # 16
        ecall                   # 20  trap: mepc = 20, mcause = 11
        addi  a0, a0, 1         # 24  resumed here
        ebreak                  # 28
handler:                        # 32
        csrrs a2, mstatus, x0   # MIE cleared, MPIE = 1  -> 0x80
        csrrs t1, mepc, x0
        addi  t1, t1, 4
        csrrw x0, mepc, t1
        addi  a1, x0, 0x55
        mret
"""


def test_ecall_trap():
    cpu, code, syms = run_src(ECALL_SRC)
    eq(code, 0, "ecall program halts")
    eqx(cpu.regs[10], 2, "execution resumed after ecall")
    eqx(cpu.regs[11], 0x55, "handler ran")
    eqx(cpu.regs[12], 0x80, "in handler MIE=0, MPIE=1")
    eqx(cpu.mepc, 24, "mepc advanced by the handler")
    eqx(cpu.mcause, 11, "mcause = 11 for ecall")
    eq(cpu.mstatus_mie, 1, "mret restored MIE from MPIE")
    eq(cpu.mstatus_mpie, 1, "mret set MPIE = 1")
    # the ecall itself must not appear in the trace
    ecall_pc = "%08x" % 20
    for line in cpu.trace_lines:
        check(not line.startswith(ecall_pc + " 00000073"),
              "ecall is not retired: %r" % line)
    # the handler's first instruction is traced normally
    handler_pc = "%08x " % syms['handler']
    check(any(l.startswith(handler_pc) for l in cpu.trace_lines),
          "first ISR instruction appears in the trace")
    # mret prints pc + insn only
    mret_lines = [l for l in cpu.trace_lines if l.endswith(" 30200073")]
    eq(len(mret_lines), 1, "exactly one mret trace line")
    eq(len(mret_lines[0].split()), 2, "mret trace line has no rd field")
    # ebreak is the final line
    check(cpu.trace_lines[-1].endswith(" 00100073"),
          "ebreak is the last trace line")


IRQ_SRC = """
        .text
        la    t0, isr           # 0(retire 0), 4(1)
        csrrw x0, mtvec, t0     # 8   (2)
        li    t1, 0x800         # 12 (3), 16 (4)   MEIE
        csrrw x0, mie, t1       # 20  (5)
        csrrwi x0, mstatus, 8   # 24  (6)  MIE = 1
        addi  a0, x0, 1         # 28  (7)
        addi  a0, a0, 1         # 32  (8 or interrupted)
        addi  a0, a0, 1         # 36
        ebreak                  # 40
isr:                            # 44
        addi  a1, x0, 0x55
        csrrs a2, mstatus, x0
        mret
"""


def test_external_interrupt():
    cpu, code, syms = run_src(IRQ_SRC, irq_after=(8,))
    eq(code, 0, "irq program halts")
    eq(syms['isr'], 44, "isr label address")
    eqx(cpu.mepc, 32, "mepc = PC of the interrupted (not executed) instruction")
    eqx(cpu.mcause, 0x8000000B, "mcause = 0x8000000b for external interrupt")
    eqx(cpu.regs[11], 0x55, "ISR ran")
    eqx(cpu.regs[12], 0x80, "inside ISR: MIE=0, MPIE=1")
    eqx(cpu.regs[10], 3, "interrupted instruction re-executed after mret")
    eq(cpu.mstatus_mie, 1, "MIE restored by mret")
    eq(cpu.mstatus_mpie, 1, "MPIE = 1 after mret")
    # the interrupted instruction is not retired at the interrupt point
    idx = [i for i, l in enumerate(cpu.trace_lines) if l.startswith("00000020")]
    eq(len(idx), 1, "PC 0x20 retires exactly once")
    isr_first = "%08x " % syms['isr']
    first_isr = [i for i, l in enumerate(cpu.trace_lines)
                 if l.startswith(isr_first)]
    eq(len(first_isr), 1, "ISR entered exactly once")
    check(first_isr[0] == 8, "ISR entry is retirement index 8")

    # same program, interrupt requested while MIE = 0 -> dropped
    cpu2, code2, _ = run_src(IRQ_SRC, irq_after=(0,))
    eq(code2, 0, "dropped-irq program halts")
    eqx(cpu2.mcause, 0, "irq dropped when MIE=0/MEIE=0")
    eqx(cpu2.regs[10], 3, "program unaffected by dropped irq")
    eqx(cpu2.regs[11], 0, "ISR did not run")

    # two interrupts
    cpu3, code3, _ = run_src(IRQ_SRC, irq_after=(7, 12))
    eq(code3, 0, "two-irq program halts")
    isr_hits = [l for l in cpu3.trace_lines if l.startswith(isr_first)]
    eq(len(isr_hits), 2, "ISR entered twice for two irq pulses")


def test_trace_format():
    src = """
        li   t0, 3
        li   t1, 0x1ff
        sb   t1, 0(t0)          # mem[00000003] = 000000ff
        li   t2, 2
        li   t3, 0x1ffff
        sh   t3, 0(t2)          # mem[00000002] = 0000ffff
        li   t4, 8
        li   t5, -1
        sw   t5, 0(t4)          # mem[00000008] = ffffffff
        lw   a0, 0(t4)
        beq  x0, x0, done
        ebreak
done:
        ebreak
    """
    cpu, code, _ = run_src(src)
    eq(code, 0, "trace program halts")
    lines = cpu.trace_lines
    joined = "\n".join(lines)
    check(any(l.endswith("mem[00000003]=000000ff") for l in lines),
          "sb trace reports the masked byte at the byte address:\n" + joined)
    check(any(l.endswith("mem[00000002]=0000ffff") for l in lines),
          "sh trace reports the masked half:\n" + joined)
    check(any(l.endswith("mem[00000008]=ffffffff") for l in lines),
          "sw trace reports the word:\n" + joined)
    # branch lines carry pc + insn only
    br = [l for l in lines if iss.decode(int(l.split()[1], 16)).fmt == 'B']
    eq(len(br), 1, "exactly one branch retired")
    eq(len(br[0].split()), 2, "branch trace line has two fields")
    # rd lines
    rd_lines = [l for l in lines if ' x' in l]
    for l in rd_lines:
        f = l.split()
        eq(len(f[0]), 8, "pc field is 8 hex digits")
        eq(len(f[1]), 8, "insn field is 8 hex digits")
        reg, _, val = f[2].partition('=')
        check(reg.startswith('x') and reg[1:].isdigit(),
              "rd field looks like x<n>: %r" % f[2])
        eq(len(val), 8, "rd value is 8 hex digits")
        check(val == val.lower(), "trace is lowercase")


# ==========================================================================
# 4. Pseudo-instruction expansion
# ==========================================================================

def test_pseudo_expansion():
    cases = [
        ("nop",             ["addi x0, x0, 0"]),
        ("mv x1, x2",       ["addi x1, x2, 0"]),
        ("not x1, x2",      ["xori x1, x2, -1"]),
        ("neg x1, x2",      ["sub x1, x0, x2"]),
        ("seqz x1, x2",     ["sltiu x1, x2, 1"]),
        ("snez x1, x2",     ["sltu x1, x0, x2"]),
        ("sltz x1, x2",     ["slt x1, x2, x0"]),
        ("sgtz x1, x2",     ["slt x1, x0, x2"]),
        ("j 8",             ["jal x0, 8"]),
        ("jr x5",           ["jalr x0, x5, 0"]),
        ("ret",             ["jalr x0, x1, 0"]),
        ("call 12",         ["jal x1, 12"]),
        ("beqz x3, 8",      ["beq x3, x0, 8"]),
        ("bnez x3, 8",      ["bne x3, x0, 8"]),
        ("blez x3, 8",      ["bge x0, x3, 8"]),
        ("bgez x3, 8",      ["bge x3, x0, 8"]),
        ("bltz x3, 8",      ["blt x3, x0, 8"]),
        ("bgtz x3, 8",      ["blt x0, x3, 8"]),
        ("bgt x3, x4, 8",   ["blt x4, x3, 8"]),
        ("ble x3, x4, 8",   ["bge x4, x3, 8"]),
        ("bgtu x3, x4, 8",  ["bltu x4, x3, 8"]),
        ("bleu x3, x4, 8",  ["bgeu x4, x3, 8"]),
        ("li x1, 5",        ["addi x1, x0, 5"]),
        ("li x1, -2048",    ["addi x1, x0, -2048"]),
        ("li x1, 0x12345678", ["lui x1, 0x12345", "addi x1, x1, 0x678"]),
        ("li x1, 0x800",    ["lui x1, 1", "addi x1, x1, -2048"]),
        ("csrr x1, mstatus",     ["csrrs x1, mstatus, x0"]),
        ("csrw mstatus, x1",     ["csrrw x0, mstatus, x1"]),
        ("csrs mie, x1",         ["csrrs x0, mie, x1"]),
        ("csrc mie, x1",         ["csrrc x0, mie, x1"]),
        ("csrwi mtvec, 3",       ["csrrwi x0, mtvec, 3"]),
        ("csrsi mtvec, 3",       ["csrrsi x0, mtvec, 3"]),
        ("csrci mtvec, 3",       ["csrrci x0, mtvec, 3"]),
    ]
    for pseudo, expected in cases:
        got = enc_all(pseudo)
        want = [enc(e, pc=4 * i) for i, e in enumerate(expected)]
        eq([("%08x" % w) for w in got], [("%08x" % w) for w in want],
           "expansion of %r" % pseudo)

    # la is always lui + addi with the sign-adjusted %hi/%lo pair
    syms = {'sym': 0x2800}
    got = asm.encode_all('la', 'x5', 'sym', pc=0, symbols=syms)
    eq(len(got), 2, "la expands to two instructions")
    eqx(got[0], enc("lui x5, 0x3", symbols=syms), "la lui half")
    eqx(got[1], enc("addi x5, x5, -2048", symbols=syms), "la addi half")

    # jal/jalr short forms
    eqx(enc("jal 8"), enc("jal x1, 8"), "jal label form defaults to ra")
    eqx(enc("jalr x5"), enc("jalr x1, x5, 0"), "jalr rs form defaults to ra")
    eqx(enc("jalr x1, x2, 4"), enc("jalr x1, 4(x2)"),
        "jalr three-operand form")

    # ABI register names
    eqx(enc("addi sp, sp, -16"), enc("addi x2, x2, -16"), "sp == x2")
    eqx(enc("add fp, s0, ra"), enc("add x8, x8, x1"), "fp == s0 == x8")
    for name, num in sorted(asm.ABI_REGS.items()):
        eqx(enc("addi %s, x0, 0" % name), enc("addi x%d, x0, 0" % num),
            "ABI name %s == x%d" % (name, num))


# ==========================================================================
# 5. Assembler error cases
# ==========================================================================

def test_errors():
    expect_error("addi x1, x0, 2048\n", "I-type immediate 2048 out of range")
    expect_error("addi x1, x0, -2049\n", "I-type immediate -2049 out of range")
    expect_error("sw x1, 2048(x2)\n", "S-type immediate out of range")
    expect_error("slli x1, x2, 32\n", "shift amount 32 out of range")
    expect_error("slli x1, x2, -1\n", "shift amount -1 out of range")
    expect_error("csrrwi x1, mstatus, 32\n", "csr zimm 32 out of range")
    expect_error("lui x1, 0x100000\n", "U-type immediate out of range")
    expect_error("beq x1, x2, 4096\n", "branch offset 4096 out of range")
    expect_error("beq x1, x2, -4098\n", "branch offset -4098 out of range")
    expect_error("jal x1, 1048576\n", "jal offset out of range")
    expect_error("beq x1, x2, 3\n", "misaligned branch target")
    expect_error("jal x1, 3\n", "misaligned jal target")
    expect_error("frobnicate x1, x2\n", "unknown mnemonic")
    expect_error("fence\n", "fence is rejected")
    expect_error("fence.i\n", "fence.i is rejected")
    expect_error("wfi\n", "wfi is rejected")
    expect_error("beq x1, x2, nowhere\n", "undefined label")
    expect_error("addi x1, x0, undefined_thing\n", "undefined symbol")
    expect_error("li x1, some_label\nsome_label:\n", "li needs a constant")
    expect_error("addi x1, x33, 0\n", "invalid register x33")
    expect_error("addi x1, notareg, 0\n", "invalid register name")
    expect_error("add x1, x2\n", "wrong operand count for add")
    expect_error("lw x1, x2\n", "load without imm(rs1) form")
    expect_error("a:\na:\n nop\n", "duplicate label")
    expect_error(".align 3\n", ".align must be a power of two")
    expect_error(".frobnicate\n", "unknown directive")
    expect_error(".org 1\n nop\n", "instruction must be word aligned")
    expect_error("ecall x1\n", "ecall takes no operands")
    # error messages name the source line
    try:
        asm.assemble("nop\naddi x1, x0, 99999\n", "prog.s")
    except asm.AsmError as e:
        msg = str(e)
        check("prog.s:2" in msg, "error names file and line: %r" % msg)
        check("addi x1, x0, 99999" in msg,
              "error quotes the source line: %r" % msg)
    else:
        check(False, "expected AsmError for out-of-range immediate")

    # the ISS rejects illegal encodings
    for bad in (0xFFFFFFFF,          # opcode 0x7f
                0x00000000,          # opcode 0x00
                0x0000000B,          # opcode 0x0b
                0x02310033,          # R-type with funct7 = 0x01
                0x02315033,          # R-type sr? with funct7 = 0x01
                0x40011093,          # slli with funct7 = 0x20
                0x00003003,          # load with funct3 = 3
                0x00003023,          # store with funct3 = 3
                0x00002063,          # branch with funct3 = 2
                0x00001067,          # jalr with funct3 = 1
                0x00200073):         # system funct3=0, not ecall/ebreak/mret
        try:
            iss.decode(bad)
            check(False, "iss.decode should reject 0x%08x" % bad)
        except iss.IllegalInstruction:
            check(True, "iss.decode rejects 0x%08x" % bad)
    # ...and reports exit code 3
    cpu = iss.Cpu([0xFFFFFFFF])
    eq(cpu.run(), 3, "illegal instruction gives exit code 3")
    # ...and exit code 2 on runaway
    cpu = iss.Cpu(asm.assemble("loop: j loop\n")[0], max_insns=50)
    eq(cpu.run(), 2, "instruction limit gives exit code 2")


# ==========================================================================
# 6. Hex file format and the CLI
# ==========================================================================

WORK = os.path.join(ROOT, 'sim', 'work')


def sh(args):
    return subprocess.run([sys.executable] + args, cwd=ROOT,
                          capture_output=True, text=True)


def test_hex_and_cli():
    os.makedirs(WORK, exist_ok=True)
    src_path = os.path.join(WORK, 'clitest.s')
    with open(src_path, 'w', newline='\n') as fp:
        fp.write("        .text\n"
                 "        li   t0, 8\n"
                 "        la   t1, val\n"
                 "        lw   a0, 0(t1)\n"
                 "        sw   a0, 0(t0)\n"
                 "        ebreak\n"
                 "        .data\n"
                 "val:    .word 0xcafebabe\n")
    hex_path = os.path.join(WORK, 'clitest.hex')
    r = sh(['tools/asm.py', src_path, '-o', hex_path, '--list'])
    eq(r.returncode, 0, "asm.py CLI succeeds: %s" % r.stderr)

    with open(hex_path, 'rb') as fp:
        raw = fp.read()
    lines = raw.split(b'\n')
    eq(lines[-1], b'', "hex file ends with a newline")
    eq(len(lines) - 1, 1024, "hex file has exactly 1024 lines")
    check(b'\r' not in raw, "hex file uses LF line endings")
    for i, l in enumerate(lines[:-1]):
        if len(l) != 8 or l.lower() != l:
            check(False, "hex line %d is not 8 lowercase digits: %r" % (i, l))
            break
    else:
        check(True, "every hex line is 8 lowercase hex digits")

    data_hex = asm.data_hex_path(hex_path)
    check(os.path.exists(data_hex), ".data.hex written when .data is present")
    with open(data_hex, 'rb') as fp:
        draw = fp.read()
    eq(len(draw.split(b'\n')) - 1, 1024, ".data.hex has exactly 1024 lines")
    eq(draw.split(b'\n')[0], b'cafebabe', ".data.hex word 0")
    check(os.path.exists(hex_path[:-4] + '.lst'), "--list writes a .lst file")

    # no .data section -> no .data.hex
    src2 = os.path.join(WORK, 'clitest2.s')
    with open(src2, 'w', newline='\n') as fp:
        fp.write("        nop\n        ebreak\n")
    hex2 = os.path.join(WORK, 'clitest2.hex')
    d2 = asm.data_hex_path(hex2)
    if os.path.exists(d2):
        os.remove(d2)
    r = sh(['tools/asm.py', src2, '-o', hex2])
    eq(r.returncode, 0, "asm.py CLI (no data) succeeds")
    check(not os.path.exists(d2), "no .data.hex when .data is empty")

    # --bin-json
    r = sh(['tools/asm.py', src2, '--bin-json'])
    eq(r.returncode, 0, "--bin-json succeeds")
    import json
    obj = json.loads(r.stdout)
    eq(obj['text'], [0x00000013, 0x00100073], "--bin-json text words")
    eq(obj['data'], [], "--bin-json data words")

    # bad source -> exit 1, message on stderr
    bad = os.path.join(WORK, 'bad.s')
    with open(bad, 'w', newline='\n') as fp:
        fp.write("addi x1, x0, 99999\n")
    r = sh(['tools/asm.py', bad, '-o', os.path.join(WORK, 'bad.hex')])
    eq(r.returncode, 1, "asm.py exits 1 on error")
    check('out of range' in r.stderr, "asm.py explains the error")

    # ISS CLI: trace file is byte exact
    trace = os.path.join(WORK, 'clitest.trace')
    r = sh(['tools/iss.py', hex_path, '--trace', trace, '--dump-regs',
            '--dump-mem', '0', '8'])
    eq(r.returncode, 0, "iss.py CLI exits 0: %s" % r.stderr)
    with open(trace, 'rb') as fp:
        tb = fp.read()
    with open(src_path) as fp:
        words = asm.assemble(fp.read())[0]
    #  li t0,8 / lui t1,%hi(val) / addi t1,t1,%lo(val) / lw a0,0(t1)
    #  sw a0,0(t0) / ebreak
    expected = (
        b"00000000 %08x x5=00000008\n" % words[0] +
        b"00000004 %08x x6=00000000\n" % words[1] +
        b"00000008 %08x x6=00000000\n" % words[2] +
        b"0000000c %08x x10=cafebabe\n" % words[3] +
        b"00000010 %08x mem[00000008]=cafebabe\n" % words[4] +
        b"00000014 %08x\n" % words[5]
    )
    eq(tb, expected, "commit trace is byte exact")
    check(b'\r' not in tb, "trace uses LF line endings")
    check(tb.endswith(b'\n') and not tb.endswith(b'\n\n'),
          "trace ends with exactly one newline")

    # --dump-regs / --dump-mem output
    out = r.stdout.splitlines()
    eq(out[0], "x0=00000000", "--dump-regs first line")
    eq(len(out[:32]), 32, "--dump-regs prints 32 registers")
    eq(out[5], "x5=00000008", "--dump-regs x5")
    check("mem[00000008]=cafebabe" in r.stdout, "--dump-mem prints DMEM")

    # exit codes through the CLI
    runaway = os.path.join(WORK, 'runaway.s')
    with open(runaway, 'w', newline='\n') as fp:
        fp.write("loop: j loop\n")
    rh = os.path.join(WORK, 'runaway.hex')
    sh(['tools/asm.py', runaway, '-o', rh])
    r = sh(['tools/iss.py', rh, '--max-insns', '100'])
    eq(r.returncode, 2, "iss.py exits 2 when --max-insns is exceeded")

    illegal = os.path.join(WORK, 'illegal.hex')
    with open(illegal, 'w', newline='\n') as fp:
        fp.write(asm.hex_text([0xFFFFFFFF]))
    r = sh(['tools/iss.py', illegal])
    eq(r.returncode, 3, "iss.py exits 3 on an illegal instruction")
    check('illegal instruction' in r.stderr, "iss.py explains the error")


# ==========================================================================
# 7. asm/smoke.s -- full instruction coverage end to end
# ==========================================================================

def test_smoke_program():
    path = os.path.join(ROOT, 'asm', 'smoke.s')
    if not check(os.path.exists(path), "asm/smoke.s exists"):
        return
    with open(path) as fp:
        src = fp.read()
    a = asm.assemble_full(src, path)
    words = a.words('text')
    n = (a.used['text'] + 3) // 4
    mnems = set()
    for w in words[:n]:
        mnems.add(iss.decode(w).mnem)
    missing = sorted(set(asm.ALL_MNEMONICS) - mnems)
    eq(missing, [], "smoke.s uses every one of the 46 encodings")

    cpu = iss.Cpu(words, a.words('data'), max_insns=10000)
    code = cpu.run(collect=True)
    eq(code, 0, "smoke.s runs to ebreak (exit 0, no illegal instruction)")
    check(cpu.trace_lines[-1].endswith(" 00100073"),
          "smoke.s trace ends with ebreak")
    eqx(cpu.regs[13], 1, "smoke.s subroutine ran (a3 = 1)")
    eqx(cpu.mcause, 11, "smoke.s took the ecall trap")
    ecall_pc = 4 * words[:n].index(0x00000073)
    eqx(cpu.mepc, ecall_pc + 4, "smoke.s handler advanced mepc past the ecall")
    check(cpu.mstatus_mpie == 1, "smoke.s mret set MPIE")

    # the acceptance-criteria command line, run for real
    os.makedirs(WORK, exist_ok=True)
    r = sh(['tools/asm.py', 'asm/smoke.s', '-o', 'sim/work/smoke.hex'])
    eq(r.returncode, 0, "asm.py assembles asm/smoke.s: %s" % r.stderr)
    r = sh(['tools/iss.py', 'sim/work/smoke.hex',
            '--trace', 'sim/work/smoke.trace', '--dump-regs'])
    eq(r.returncode, 0, "iss.py runs smoke.hex: %s" % r.stderr)
    check(os.path.exists(os.path.join(WORK, 'smoke.trace')),
          "smoke.trace written")
    with open(os.path.join(WORK, 'smoke.trace'), 'rb') as fp:
        tb = fp.read()
    check(tb.endswith(b" 00100073\n"), "smoke.trace ends with ebreak")
    for ln in tb.split(b'\n')[:-1]:
        f = ln.split(b' ')
        if len(f[0]) != 8 or len(f[1]) != 8:
            check(False, "smoke.trace line malformed: %r" % ln)
            break
    else:
        check(True, "every smoke.trace line is well formed")


# ==========================================================================

def main():
    tests = [
        test_known_encodings,
        test_roundtrip,
        test_boundary_immediates,
        test_load_sign_extension,
        test_partial_stores,
        test_comparisons,
        test_shifts,
        test_jumps_and_auipc,
        test_branches,
        test_li_la_and_data,
        test_hi_lo_pairs,
        test_x0_is_hardwired,
        test_csr_read_modify_write,
        test_ecall_trap,
        test_external_interrupt,
        test_trace_format,
        test_pseudo_expansion,
        test_errors,
        test_hex_and_cli,
        test_smoke_program,
    ]
    for t in tests:
        before = len(FAILURES)
        try:
            t()
        except Exception as e:                      # noqa: BLE001
            import traceback
            FAILURES.append("%s raised %s\n%s"
                            % (t.__name__, e, traceback.format_exc()))
        status = "ok" if len(FAILURES) == before else "FAIL"
        print("  %-30s %s" % (t.__name__, status))

    print()
    if FAILURES:
        print("FAILURES (%d):" % len(FAILURES))
        for f in FAILURES:
            print("  - %s" % f)
        print("\n%d checks run, %d FAILED" % (CHECKS, len(FAILURES)))
        return 1
    print("%d checks run, all passed" % CHECKS)
    return 0


if __name__ == '__main__':
    sys.exit(main())
