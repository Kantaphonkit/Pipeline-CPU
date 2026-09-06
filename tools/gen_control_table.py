#!/usr/bin/env python3
"""gen_control_table.py -- the single source of truth for RV32I decode.

This script holds the per-instruction control settings of rtl/control.v +
rtl/alu_ctrl.v as a Python dict (CONTROL, below).  That dict *is* the truth
table; everything else is generated from it:

    docs/DESIGN.md  section 3   markdown truth table, rewritten in place between
                                <!-- CONTROL-TABLE-BEGIN --> / <!-- CONTROL-TABLE-END -->
    tb/vectors/control_vectors.hex   $readmemh stimulus/expected image for tb/tb_control.v
    tb/vectors/control_vectors.txt   human-readable companion (debugging only)

Nothing is hand-typed twice: the report table and the RTL test compare against
the same dict, so they cannot drift apart.

Usage
-----
    python tools/gen_control_table.py            # regenerate all three outputs
    python tools/gen_control_table.py --check    # verify outputs are up to date

Independence policy
-------------------
The dict supplies control *values*; it deliberately does NOT re-implement
instruction *classification*.  Every stimulus word is produced by the
cross-validated assembler (`asm.encode`) from ordinary source operands, and the
mnemonic each word is expected to decode to is confirmed by the cross-validated
ISS decoder (`iss.decode`) before the vector is emitted.  Illegal vectors are
likewise confirmed illegal by `iss.decode` raising IllegalInstruction.  So a
typo in a stimulus word cannot silently produce a wrong expectation.

One documented divergence between iss.decode and rtl/control.v
--------------------------------------------------------------
`iss.decode` recognises ecall/ebreak/mret only as the exact words 0x00000073 /
0x00100073 / 0x30200073.  `control.v` has no rd input (INTERFACES.md section 9
fixes its port list), so it decodes them from opcode + funct3 + inst[31:20]
alone and ignores the rd/rs1 fields.  Words such as 0x00000173 (ecall with
rd=x2) are therefore illegal to the ISS but decode as ecall in the RTL.  The
assembler never emits them, and they are excluded from the illegal vector pool
(see _system_alias).

Vector file layout (one 8-hex-digit lowercase word per line)
------------------------------------------------------------
    line 0        : vector count N
    lines 1..2N   : N pairs  <instruction word> <expected packed control word>

Packed control word (bit 0 = LSB; bits 31:26 are 0):

    bit    0     reg_we
    bit    1     alu_src_a
    bit    2     alu_src_b
    bits   5:3   imm_sel     (0 I, 1 S, 2 B, 3 U, 4 J, 5 Z)
    bits   7:6   alu_class   (0 ADD, 1 R-type, 2 I-type, 3 LUI/PASSB)
    bit    8     mem_re
    bit    9     mem_we
    bits  11:10  wb_sel      (0 ALU, 1 MEM, 2 PC+4, 3 CSR)
    bit   12     branch
    bit   13     jal
    bit   14     jalr
    bit   15     csr_en
    bit   16     csr_we
    bit   17     csr_imm
    bit   18     mret
    bit   19     ecall
    bit   20     ebreak
    bit   21     illegal
    bits  25:22  alu_op      (output of alu_ctrl, INTERFACES.md section 8.2)

tb/tb_control.v mirrors this layout; keep the two in sync.
"""

import argparse
import os
import random
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from asm import encode                                          # noqa: E402
from iss import decode, IllegalInstruction                      # noqa: E402

SEED = 20260907
INSTANCES_PER_INSN = 12          # >= 8 required, per varying-field instruction
MEM_WORDS = 8192                 # must match VEC_MEM_WORDS in tb/tb_control.v

VEC_HEX = os.path.join(_ROOT, 'tb', 'vectors', 'control_vectors.hex')
VEC_TXT = os.path.join(_ROOT, 'tb', 'vectors', 'control_vectors.txt')
DESIGN  = os.path.join(_ROOT, 'docs', 'DESIGN.md')

BEGIN_MARK = '<!-- CONTROL-TABLE-BEGIN -->'
END_MARK   = '<!-- CONTROL-TABLE-END -->'

# ---------------------------------------------------------------------------
# encodings of the symbolic control fields (INTERFACES.md sections 8.1, 8.2, 9)
# ---------------------------------------------------------------------------

IMM_I, IMM_S, IMM_B, IMM_U, IMM_J, IMM_Z = 0, 1, 2, 3, 4, 5
IMM_NAME = {0: 'I', 1: 'S', 2: 'B', 3: 'U', 4: 'J', 5: 'Z'}

CLASS_ADD, CLASS_R, CLASS_I, CLASS_LUI = 0, 1, 2, 3

WB_ALU, WB_MEM, WB_PC4, WB_CSR = 0, 1, 2, 3
WB_NAME = {0: 'ALU', 1: 'MEM', 2: 'PC+4', 3: 'CSR'}

(ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR,
 ALU_SRL, ALU_SRA, ALU_OR, ALU_AND, ALU_PASSB) = range(11)
ALU_NAME = {ALU_ADD: 'ADD', ALU_SUB: 'SUB', ALU_SLL: 'SLL', ALU_SLT: 'SLT',
            ALU_SLTU: 'SLTU', ALU_XOR: 'XOR', ALU_SRL: 'SRL', ALU_SRA: 'SRA',
            ALU_OR: 'OR', ALU_AND: 'AND', ALU_PASSB: 'PASSB'}

#: packed word layout -- (field name, lsb position, width)
LAYOUT = [
    ('reg_we',    0, 1),
    ('alu_src_a', 1, 1),
    ('alu_src_b', 2, 1),
    ('imm_sel',   3, 3),
    ('alu_class', 6, 2),
    ('mem_re',    8, 1),
    ('mem_we',    9, 1),
    ('wb_sel',   10, 2),
    ('branch',   12, 1),
    ('jal',      13, 1),
    ('jalr',     14, 1),
    ('csr_en',   15, 1),
    ('csr_we',   16, 1),
    ('csr_imm',  17, 1),
    ('mret',     18, 1),
    ('ecall',    19, 1),
    ('ebreak',   20, 1),
    ('illegal',  21, 1),
    ('alu_op',   22, 4),
]


# ---------------------------------------------------------------------------
# THE TRUTH TABLE
# ---------------------------------------------------------------------------
# One entry per mnemonic.  Only the non-zero fields are listed; every unlisted
# field is 0 (which is also the value control.v drives for it).  `alu_op` is
# never listed -- it is derived from alu_class + funct3 + inst[30] by
# alu_ctrl_model() below, exactly as rtl/alu_ctrl.v derives it in hardware.
#
# `csr_we` may be the string 'rs1!=0': the write side of csrrs/csrrc/csrrsi/
# csrrci happens only when the rs1 field (== zimm for the *i forms) is non-zero.
#
# `con` is the funct7 / imm[11:0] legality constraint, for the report table.

def _row(con, **kw):
    row = dict.fromkeys((n for n, _, _ in LAYOUT if n != 'alu_op'), 0)
    row.update(kw)
    row['con'] = con
    return row


def _r(f7con):
    return _row(f7con, reg_we=1, alu_src_b=0, imm_sel=IMM_I,
                alu_class=CLASS_R, wb_sel=WB_ALU)


def _iarith(con='--'):
    return _row(con, reg_we=1, alu_src_b=1, imm_sel=IMM_I,
                alu_class=CLASS_I, wb_sel=WB_ALU)


def _load():
    return _row('--', reg_we=1, alu_src_b=1, imm_sel=IMM_I,
                alu_class=CLASS_ADD, mem_re=1, wb_sel=WB_MEM)


def _store():
    return _row('--', reg_we=0, alu_src_b=1, imm_sel=IMM_S,
                alu_class=CLASS_ADD, mem_we=1, wb_sel=WB_ALU)


def _branch():
    return _row('--', reg_we=0, alu_src_b=0, imm_sel=IMM_B,
                alu_class=CLASS_ADD, wb_sel=WB_ALU, branch=1)


def _csr(imm_form, always_write):
    return _row('--', reg_we=1, alu_src_b=1,
                imm_sel=IMM_Z if imm_form else IMM_I,
                alu_class=CLASS_ADD, wb_sel=WB_CSR, csr_en=1,
                csr_we=1 if always_write else 'rs1!=0',
                csr_imm=1 if imm_form else 0)


def _sys(con, **kw):
    # ecall/ebreak/mret: no register or memory side effect in the datapath;
    # alu_src_b follows the uniform "1 unless R-type or branch" equation.
    return _row(con, alu_src_b=1, imm_sel=IMM_I, alu_class=CLASS_ADD,
                wb_sel=WB_ALU, **kw)


CONTROL = {
    # ---- R-type (10) ------------------------------------------------------
    'add':  _r('funct7=0x00'),
    'sub':  _r('funct7=0x20'),
    'sll':  _r('funct7=0x00'),
    'slt':  _r('funct7=0x00'),
    'sltu': _r('funct7=0x00'),
    'xor':  _r('funct7=0x00'),
    'srl':  _r('funct7=0x00'),
    'sra':  _r('funct7=0x20'),
    'or':   _r('funct7=0x00'),
    'and':  _r('funct7=0x00'),

    # ---- I-arith (9) ------------------------------------------------------
    'addi':  _iarith(),
    'slti':  _iarith(),
    'sltiu': _iarith(),
    'xori':  _iarith(),
    'ori':   _iarith(),
    'andi':  _iarith(),
    'slli':  _iarith('inst[31:25]=0x00'),
    'srli':  _iarith('inst[31:25]=0x00'),
    'srai':  _iarith('inst[31:25]=0x20'),

    # ---- loads (5) --------------------------------------------------------
    'lb':  _load(), 'lh':  _load(), 'lw':  _load(),
    'lbu': _load(), 'lhu': _load(),

    # ---- stores (3) -------------------------------------------------------
    'sb': _store(), 'sh': _store(), 'sw': _store(),

    # ---- branches (6) -----------------------------------------------------
    'beq':  _branch(), 'bne':  _branch(), 'blt': _branch(),
    'bge':  _branch(), 'bltu': _branch(), 'bgeu': _branch(),

    # ---- U-type (2) -------------------------------------------------------
    'lui':   _row('--', reg_we=1, alu_src_a=0, alu_src_b=1, imm_sel=IMM_U,
                  alu_class=CLASS_LUI, wb_sel=WB_ALU),
    'auipc': _row('--', reg_we=1, alu_src_a=1, alu_src_b=1, imm_sel=IMM_U,
                  alu_class=CLASS_ADD, wb_sel=WB_ALU),

    # ---- jumps (2) --------------------------------------------------------
    'jal':  _row('--', reg_we=1, alu_src_b=1, imm_sel=IMM_J,
                 alu_class=CLASS_ADD, wb_sel=WB_PC4, jal=1),
    'jalr': _row('--', reg_we=1, alu_src_b=1, imm_sel=IMM_I,
                 alu_class=CLASS_ADD, wb_sel=WB_PC4, jalr=1),

    # ---- system (9) -------------------------------------------------------
    'ecall':  _sys('inst[31:20]=0x000', ecall=1),
    'ebreak': _sys('inst[31:20]=0x001', ebreak=1),
    'mret':   _sys('inst[31:20]=0x302', mret=1),
    'csrrw':  _csr(imm_form=0, always_write=1),
    'csrrs':  _csr(imm_form=0, always_write=0),
    'csrrc':  _csr(imm_form=0, always_write=0),
    'csrrwi': _csr(imm_form=1, always_write=1),
    'csrrsi': _csr(imm_form=1, always_write=0),
    'csrrci': _csr(imm_form=1, always_write=0),
}

#: report/vector ordering (groups of INTERFACES.md section 1)
ORDER = (
    ['add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and'] +
    ['addi', 'slti', 'sltiu', 'xori', 'ori', 'andi', 'slli', 'srli', 'srai'] +
    ['lb', 'lh', 'lw', 'lbu', 'lhu'] +
    ['sb', 'sh', 'sw'] +
    ['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'] +
    ['lui', 'auipc'] +
    ['jal', 'jalr'] +
    ['ecall', 'ebreak', 'csrrw', 'csrrs', 'csrrc', 'csrrwi', 'csrrsi',
     'csrrci', 'mret']
)
assert sorted(ORDER) == sorted(CONTROL), 'ORDER and CONTROL disagree'
assert len(ORDER) == 46, 'expected 46 encodings, got %d' % len(ORDER)


# ---------------------------------------------------------------------------
# alu_ctrl model -- mirrors rtl/alu_ctrl.v
# ---------------------------------------------------------------------------

_ALU_TABLE = {0: ALU_ADD, 1: ALU_SLL, 2: ALU_SLT, 3: ALU_SLTU,
              4: ALU_XOR, 5: ALU_SRL, 6: ALU_OR, 7: ALU_AND}


def alu_ctrl_model(alu_class, funct3, b30):
    """alu_class + funct3 + inst[30] -> 4-bit ALU opcode."""
    if alu_class == CLASS_LUI:
        return ALU_PASSB
    if alu_class == CLASS_R:
        if funct3 == 0:
            return ALU_SUB if b30 else ALU_ADD
        if funct3 == 5:
            return ALU_SRA if b30 else ALU_SRL
        return _ALU_TABLE[funct3]
    if alu_class == CLASS_I:
        # inst[30] is consulted ONLY for funct3 = 101 (srli/srai).  funct3 = 000
        # is ADD even when inst[30] = 1 (addi with a negative immediate).
        if funct3 == 5:
            return ALU_SRA if b30 else ALU_SRL
        return _ALU_TABLE[funct3]
    return ALU_ADD                                     # CLASS_ADD


# ---------------------------------------------------------------------------
# packing
# ---------------------------------------------------------------------------

def pack(fields):
    """Field dict (all 18 control outputs + alu_op) -> 32-bit expected word."""
    word = 0
    for name, lsb, width in LAYOUT:
        val = int(fields[name])
        if not 0 <= val < (1 << width):
            raise ValueError('%s = %r does not fit in %d bits' %
                             (name, val, width))
        word |= val << lsb
    return word


ILLEGAL_FIELDS = dict.fromkeys((n for n, _, _ in LAYOUT), 0)
ILLEGAL_FIELDS['illegal'] = 1          # everything else 0 -> alu_op = ADD = 0
ILLEGAL_PACKED = pack(ILLEGAL_FIELDS)


def expected_fields(word, mnem):
    """Expected control outputs for instruction `word` decoding as `mnem`."""
    row = CONTROL[mnem]
    funct3 = (word >> 12) & 0x7
    b30 = (word >> 30) & 1
    rs1 = (word >> 15) & 0x1F
    out = {n: row[n] for n, _, _ in LAYOUT if n != 'alu_op'}
    if out['csr_we'] == 'rs1!=0':
        out['csr_we'] = 1 if rs1 != 0 else 0
    out['alu_op'] = alu_ctrl_model(out['alu_class'], funct3, b30)
    return out


# ---------------------------------------------------------------------------
# stimulus generation
# ---------------------------------------------------------------------------

R_MNEMS = ORDER[0:10]
IARITH_MNEMS = ['addi', 'slti', 'sltiu', 'xori', 'ori', 'andi']
SHIFT_MNEMS = ['slli', 'srli', 'srai']
LOAD_MNEMS = ['lb', 'lh', 'lw', 'lbu', 'lhu']
STORE_MNEMS = ['sb', 'sh', 'sw']
BRANCH_MNEMS = ['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu']
CSR_REG_MNEMS = ['csrrw', 'csrrs', 'csrrc']
CSR_IMM_MNEMS = ['csrrwi', 'csrrsi', 'csrrci']
FIXED_MNEMS = ['ecall', 'ebreak', 'mret']
#: formats with no funct3 field at all (U and J) plus the fixed system words
NO_FUNCT3 = FIXED_MNEMS + ['lui', 'auipc', 'jal']

CSR_ADDRS = ['0x300', '0x304', '0x305', '0x341', '0x342', '0x000', '0xfff',
             '0x123']

#: canonical instance per mnemonic -- used for the report table's
#: opcode/funct3/funct7 columns and for its alu_op column.
CANON = {}
for _m in R_MNEMS:
    CANON[_m] = (_m, 'x1', 'x2', 'x3')
for _m in IARITH_MNEMS:
    CANON[_m] = (_m, 'x1', 'x2', '5')
for _m in SHIFT_MNEMS:
    CANON[_m] = (_m, 'x1', 'x2', '3')
for _m in LOAD_MNEMS:
    CANON[_m] = (_m, 'x1', '8(x2)')
for _m in STORE_MNEMS:
    CANON[_m] = (_m, 'x3', '8(x2)')
for _m in BRANCH_MNEMS:
    CANON[_m] = (_m, 'x1', 'x2', '8')
CANON['lui'] = ('lui', 'x1', '0x12345')
CANON['auipc'] = ('auipc', 'x1', '0x12345')
CANON['jal'] = ('jal', 'x1', '16')
CANON['jalr'] = ('jalr', 'x1', 'x2', '4')
CANON['ecall'] = ('ecall',)
CANON['ebreak'] = ('ebreak',)
CANON['mret'] = ('mret',)
for _m in CSR_REG_MNEMS:
    CANON[_m] = (_m, 'x1', '0x300', 'x2')
for _m in CSR_IMM_MNEMS:
    CANON[_m] = (_m, 'x1', '0x300', '7')


def _reg(rng):
    return 'x%d' % rng.randrange(32)


def instances(mnem, rng):
    """A list of (operand tuple) instances for `mnem`, >= 8 unless the encoding
    is fixed (ecall/ebreak/mret have exactly one legal word each)."""
    n = INSTANCES_PER_INSN
    out = []
    if mnem in FIXED_MNEMS:
        return [(mnem,)]

    if mnem in R_MNEMS:
        out = [(mnem, 'x0', 'x0', 'x0'), (mnem, 'x31', 'x31', 'x31')]
        out += [(mnem, _reg(rng), _reg(rng), _reg(rng)) for _ in range(n - 2)]

    elif mnem in IARITH_MNEMS:
        # negative immediates put inst[30] = 1 -- the classic addi/sub trap
        specials = ['-1', '-2048', '-1365', '2047', '0', '1']
        out = [(mnem, _reg(rng), _reg(rng), s) for s in specials]
        out += [(mnem, _reg(rng), _reg(rng), str(rng.randint(-2048, 2047)))
                for _ in range(n - len(specials))]

    elif mnem in SHIFT_MNEMS:
        specials = ['0', '1', '31', '16']
        out = [(mnem, _reg(rng), _reg(rng), s) for s in specials]
        out += [(mnem, _reg(rng), _reg(rng), str(rng.randrange(32)))
                for _ in range(n - len(specials))]

    elif mnem in LOAD_MNEMS:
        specials = ['-1', '-2048', '2047', '0']
        out = [(mnem, _reg(rng), '%s(%s)' % (s, _reg(rng))) for s in specials]
        out += [(mnem, _reg(rng), '%d(%s)' % (rng.randint(-2048, 2047),
                                              _reg(rng)))
                for _ in range(n - len(specials))]

    elif mnem in STORE_MNEMS:
        specials = ['-1', '-2048', '2047', '0']
        out = [(mnem, _reg(rng), '%s(%s)' % (s, _reg(rng))) for s in specials]
        out += [(mnem, _reg(rng), '%d(%s)' % (rng.randint(-2048, 2047),
                                              _reg(rng)))
                for _ in range(n - len(specials))]

    elif mnem in BRANCH_MNEMS:
        specials = ['-4096', '-2', '0', '4094']
        out = [(mnem, _reg(rng), _reg(rng), s) for s in specials]
        out += [(mnem, _reg(rng), _reg(rng),
                 str(2 * rng.randint(-2048, 2047)))
                for _ in range(n - len(specials))]

    elif mnem in ('lui', 'auipc'):
        specials = ['0', '1', '0xfffff', '0x80000']
        out = [(mnem, _reg(rng), s) for s in specials]
        out += [(mnem, _reg(rng), hex(rng.randrange(1 << 20)))
                for _ in range(n - len(specials))]

    elif mnem == 'jal':
        specials = ['-1048576', '-2', '0', '1048574']
        out = [(mnem, _reg(rng), s) for s in specials]
        out += [(mnem, _reg(rng), str(2 * rng.randint(-524288, 524287)))
                for _ in range(n - len(specials))]

    elif mnem == 'jalr':
        specials = ['-2048', '-1', '0', '2047']
        out = [(mnem, _reg(rng), _reg(rng), s) for s in specials]
        out += [(mnem, _reg(rng), _reg(rng), str(rng.randint(-2048, 2047)))
                for _ in range(n - len(specials))]

    elif mnem in CSR_REG_MNEMS:
        # rs1 = x0 vs rs1 != x0 decides csr_we for csrrs/csrrc
        out = [(mnem, 'x0', '0x300', 'x0'),      # rs1 = x0  -> no CSR write
               (mnem, 'x5', '0x300', 'x0'),      # rs1 = x0, rd != 0
               (mnem, 'x0', '0x341', 'x7'),      # rs1 != 0 -> CSR write, rd = x0
               (mnem, 'x5', '0x342', 'x31')]
        out += [(mnem, _reg(rng), rng.choice(CSR_ADDRS), _reg(rng))
                for _ in range(n - len(out))]

    elif mnem in CSR_IMM_MNEMS:
        # zimm = 0 vs zimm != 0 decides csr_we for csrrsi/csrrci
        out = [(mnem, 'x0', '0x300', '0'),
               (mnem, 'x5', '0x300', '0'),
               (mnem, 'x0', '0x341', '1'),
               (mnem, 'x5', '0x342', '31')]
        out += [(mnem, _reg(rng), rng.choice(CSR_ADDRS),
                 str(rng.randrange(32)))
                for _ in range(n - len(out))]

    else:
        raise KeyError(mnem)

    return out


def _system_alias(word):
    """True if control.v decodes `word` as ecall/ebreak/mret from its
    opcode/funct3/inst[31:20] view while iss.decode calls it illegal (rd or rs1
    field non-zero).  Such words must not enter the illegal pool -- see the
    module docstring."""
    return ((word & 0x7F) == 0x73 and ((word >> 12) & 0x7) == 0 and
            ((word >> 20) & 0xFFF) in (0x000, 0x001, 0x302))


def _r_word(funct7, rs2, rs1, funct3, rd, opcode):
    return ((funct7 & 0x7F) << 25 | (rs2 & 0x1F) << 20 | (rs1 & 0x1F) << 15 |
            (funct3 & 0x7) << 12 | (rd & 0x1F) << 7 | (opcode & 0x7F))


def illegal_words(rng):
    """Hand-picked plus randomly-swept illegal encodings."""
    w = []

    # bad funct7 on R-type ops (funct7 = 0x01 / 0x40 / 0x7f are all invalid)
    for f3 in range(8):
        w.append(_r_word(0x01, 3, 2, f3, 1, 0x33))
    for f3 in (0, 5):
        w.append(_r_word(0x40, 3, 2, f3, 1, 0x33))
    # funct7 = 0x20 is legal ONLY with funct3 000 (sub) and 101 (sra)
    for f3 in (1, 2, 3, 4, 6, 7):
        w.append(_r_word(0x20, 3, 2, f3, 1, 0x33))

    # shift-immediates with a bad inst[31:25]
    w.append(_r_word(0x20, 5, 2, 1, 1, 0x13))        # slli with 0x20
    w.append(_r_word(0x01, 5, 2, 1, 1, 0x13))        # slli with 0x01
    w.append(_r_word(0x10, 5, 2, 5, 1, 0x13))        # sr?i with 0x10
    w.append(_r_word(0x40, 5, 2, 5, 1, 0x13))        # sr?i with 0x40
    w.append(_r_word(0x7F, 5, 2, 1, 1, 0x13))

    # loads / stores / branches / jalr with unsupported funct3
    for f3 in (3, 6, 7):
        w.append(_r_word(0x00, 4, 2, f3, 1, 0x03))   # no ld / lwu in RV32I
    for f3 in (3, 4, 5, 6, 7):
        w.append(_r_word(0x00, 4, 2, f3, 1, 0x23))
    for f3 in (2, 3):
        w.append(_r_word(0x00, 4, 2, f3, 1, 0x63))
    for f3 in range(1, 8):
        w.append(_r_word(0x00, 4, 2, f3, 1, 0x67))   # jalr must be funct3=000

    # SYSTEM funct3 = 000 with a csr field that is not ecall/ebreak/mret
    for csr in (0x002, 0x105, 0x102, 0x7B2, 0x301, 0x303, 0x30F, 0xFFF):
        w.append((csr << 20) | 0x73)                 # wfi, sret, dret, ...
    # SYSTEM funct3 = 100 has no encoding
    w.append(_r_word(0x30, 0, 2, 4, 1, 0x73))

    # unknown opcodes (fence, RV64/atomic/FP space, and the 16-bit space)
    for op in (0x00, 0x0F, 0x1F, 0x2F, 0x3B, 0x43, 0x53, 0x5B, 0x6B, 0x77,
               0x7B, 0x7F, 0x01, 0x02, 0x11, 0x22):
        w.append(_r_word(0x00, 3, 2, 0, 1, op))

    # random sweep, filtered by the ISS
    tries = 0
    while len(w) < 120 and tries < 200000:
        tries += 1
        cand = rng.randrange(1 << 32)
        if _system_alias(cand):
            continue
        try:
            decode(cand)
        except IllegalInstruction:
            w.append(cand)

    # verify every one of them: illegal to the ISS, and not a SYSTEM alias
    out = []
    for word in w:
        assert not _system_alias(word), 'illegal pool contains %08x' % word
        try:
            decode(word)
        except IllegalInstruction:
            out.append(word)
            continue
        raise AssertionError('%08x is not illegal to iss.decode' % word)
    return out


def build_vectors():
    """-> (vectors, n_legal, n_illegal); vector = (word, packed, note)."""
    rng = random.Random(SEED)
    vectors = []

    for mnem in ORDER:
        for ops in instances(mnem, rng):
            word = encode(*ops)
            got = decode(word)                       # cross-check the stimulus
            assert got.mnem == mnem, (
                '%s %s encoded as %08x, ISS decodes it as %s' %
                (ops[0], ops[1:], word, got.mnem))
            packed = pack(expected_fields(word, mnem))
            vectors.append((word, packed,
                            '%s %s' % (ops[0], ', '.join(ops[1:]))))
    n_legal = len(vectors)

    for word in illegal_words(rng):
        vectors.append((word, ILLEGAL_PACKED, 'illegal'))
    n_illegal = len(vectors) - n_legal

    return vectors, n_legal, n_illegal


# ---------------------------------------------------------------------------
# output writers
# ---------------------------------------------------------------------------

def hex_image(vectors):
    words = [len(vectors)]
    for word, packed, _ in vectors:
        words += [word, packed]
    if len(words) > MEM_WORDS:
        raise SystemExit('vector image is %d words, tb array holds %d'
                         % (len(words), MEM_WORDS))
    return ''.join('%08x\n' % (x & 0xFFFFFFFF) for x in words)


def txt_image(vectors, n_legal, n_illegal):
    lines = ['# control_vectors -- generated by tools/gen_control_table.py',
             '# %d vectors (%d legal, %d illegal)'
             % (len(vectors), n_legal, n_illegal),
             '# columns: inst packed  [decoded fields]  source']
    for word, packed, note in vectors:
        f = {}
        for name, lsb, width in LAYOUT:
            f[name] = (packed >> lsb) & ((1 << width) - 1)
        flags = ' '.join('%s=%d' % (n, f[n]) for n, _, _ in LAYOUT)
        lines.append('%08x %08x  %s  # %s' % (word, packed, flags, note))
    return '\n'.join(lines) + '\n'


def markdown_table():
    """The section 3 truth table: one row per encoding + the illegal row."""
    head = ['Instr', 'opcode', 'f3', 'funct7 / imm[11:0]', 'reg_we', 'src_a',
            'src_b', 'imm_sel', 'class', 'alu_op', 'mem_re', 'mem_we',
            'wb_sel', 'branch', 'jal', 'jalr', 'csr_en', 'csr_we', 'csr_imm',
            'mret', 'ecall', 'ebreak']
    rows = []
    for mnem in ORDER:
        word = encode(*CANON[mnem])
        opcode = word & 0x7F
        funct3 = (word >> 12) & 0x7
        b30 = (word >> 30) & 1
        row = CONTROL[mnem]
        alu_op = alu_ctrl_model(row['alu_class'], funct3, b30)
        f3col = '--' if mnem in NO_FUNCT3 else format(funct3, '03b')
        csr_we = row['csr_we']
        csr_we = 'rs1!=0' if csr_we == 'rs1!=0' else str(csr_we)
        rows.append([
            '`%s`' % mnem,
            '0x%02X' % opcode,
            f3col,
            row['con'],
            str(row['reg_we']),
            str(row['alu_src_a']),
            str(row['alu_src_b']),
            '%s(%d)' % (IMM_NAME[row['imm_sel']], row['imm_sel']),
            str(row['alu_class']),
            '%s(%d)' % (ALU_NAME[alu_op], alu_op),
            str(row['mem_re']),
            str(row['mem_we']),
            '%s(%d)' % (WB_NAME[row['wb_sel']], row['wb_sel']),
            str(row['branch']),
            str(row['jal']),
            str(row['jalr']),
            str(row['csr_en']),
            csr_we,
            str(row['csr_imm']),
            str(row['mret']),
            str(row['ecall']),
            str(row['ebreak']),
        ])
    rows.append(['*illegal*', 'other', '--', 'see text'] +
                ['0'] * 3 + ['I(0)', '0', 'ADD(0)', '0', '0', 'ALU(0)'] +
                ['0'] * 9)

    out = ['| ' + ' | '.join(head) + ' |',
           '|' + '|'.join(['---'] * len(head)) + '|']
    for r in rows:
        out.append('| ' + ' | '.join(r) + ' |')
    return '\n'.join(out)


def splice_design(text, table):
    if BEGIN_MARK not in text or END_MARK not in text:
        raise SystemExit('docs/DESIGN.md is missing the CONTROL-TABLE markers')
    head, rest = text.split(BEGIN_MARK, 1)
    _, tail = rest.split(END_MARK, 1)
    return '%s%s\n\n%s\n\n%s%s' % (head, BEGIN_MARK, table, END_MARK, tail)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--check', action='store_true',
                    help='verify the generated files are up to date')
    args = ap.parse_args()

    vectors, n_legal, n_illegal = build_vectors()
    hexs = hex_image(vectors)
    txts = txt_image(vectors, n_legal, n_illegal)
    table = markdown_table()

    with open(DESIGN, 'r', encoding='utf-8') as fp:
        design_new = splice_design(fp.read(), table)

    outputs = [(VEC_HEX, hexs), (VEC_TXT, txts), (DESIGN, design_new)]

    if args.check:
        stale = []
        for path, want in outputs:
            try:
                with open(path, 'r', encoding='utf-8', newline='') as fp:
                    have = fp.read().replace('\r\n', '\n')
            except OSError:
                stale.append(path)
                continue
            if have != want:
                stale.append(path)
        if stale:
            print('STALE: ' + ', '.join(os.path.relpath(p, _ROOT)
                                        for p in stale))
            return 1
        print('up to date: %d vectors (%d legal, %d illegal)'
              % (len(vectors), n_legal, n_illegal))
        return 0

    os.makedirs(os.path.dirname(VEC_HEX), exist_ok=True)
    for path, data in outputs:
        with open(path, 'w', encoding='utf-8', newline='\n') as fp:
            fp.write(data)
    print('wrote %s (%d vectors: %d legal, %d illegal)'
          % (os.path.relpath(VEC_HEX, _ROOT), len(vectors), n_legal,
             n_illegal))
    print('wrote %s' % os.path.relpath(VEC_TXT, _ROOT))
    print('wrote %s section 3 truth table (%d rows)'
          % (os.path.relpath(DESIGN, _ROOT), len(ORDER) + 1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
