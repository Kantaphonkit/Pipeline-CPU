#!/usr/bin/env python3
"""RV32I assembler for the Pipeline-CPU course project.

Implements exactly the contract in docs/INTERFACES.md sections 1, 2 and 4.
Pure standard library, two-pass (symbol table, then encode).

CLI
    python tools/asm.py prog.s -o prog.hex           # + prog.data.hex if .data non-empty
    python tools/asm.py prog.s -o prog.hex --list    # also writes prog.lst
    python tools/asm.py prog.s --bin-json            # {"text":[...], "data":[...]}

Module
    from asm import assemble, encode, encode_all, AsmError
    text_words, data_words, symbols = assemble(source_text)
    word  = encode("addi", "x1", "x0", "-1")
    words = encode_all("li", "x1", "0x12345")
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

MEM_WORDS = 1024          # 4 KB / 4
MEM_BYTES = MEM_WORDS * 4


class AsmError(Exception):
    """Assembly error; the message always names the source line."""


# --------------------------------------------------------------------------
# Registers / CSRs
# --------------------------------------------------------------------------

ABI_REGS = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7,
    's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13,
    'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
}

CSR_NAMES = {
    'mstatus': 0x300,
    'mie':     0x304,
    'mtvec':   0x305,
    'mepc':    0x341,
    'mcause':  0x342,
}

# --------------------------------------------------------------------------
# Instruction tables (RISC-V Unprivileged/Privileged ISA, RV32I)
# --------------------------------------------------------------------------

OP_R      = 0x33
OP_IARITH = 0x13
OP_LOAD   = 0x03
OP_STORE  = 0x23
OP_BRANCH = 0x63
OP_LUI    = 0x37
OP_AUIPC  = 0x17
OP_JAL    = 0x6F
OP_JALR   = 0x67
OP_SYSTEM = 0x73

R_INSNS = {                       # mnemonic: (funct7, funct3)
    'add':  (0x00, 0x0), 'sub':  (0x20, 0x0), 'sll': (0x00, 0x1),
    'slt':  (0x00, 0x2), 'sltu': (0x00, 0x3), 'xor': (0x00, 0x4),
    'srl':  (0x00, 0x5), 'sra':  (0x20, 0x5), 'or':  (0x00, 0x6),
    'and':  (0x00, 0x7),
}
I_ARITH = {                       # mnemonic: funct3
    'addi': 0x0, 'slti': 0x2, 'sltiu': 0x3,
    'xori': 0x4, 'ori': 0x6, 'andi': 0x7,
}
I_SHIFT = {                       # mnemonic: (funct7, funct3)
    'slli': (0x00, 0x1), 'srli': (0x00, 0x5), 'srai': (0x20, 0x5),
}
LOADS    = {'lb': 0x0, 'lh': 0x1, 'lw': 0x2, 'lbu': 0x4, 'lhu': 0x5}
STORES   = {'sb': 0x0, 'sh': 0x1, 'sw': 0x2}
BRANCHES = {'beq': 0x0, 'bne': 0x1, 'blt': 0x4,
            'bge': 0x5, 'bltu': 0x6, 'bgeu': 0x7}
CSR_REG  = {'csrrw': 0x1, 'csrrs': 0x2, 'csrrc': 0x3}
CSR_IMM  = {'csrrwi': 0x5, 'csrrsi': 0x6, 'csrrci': 0x7}
SYSTEM_FIXED = {
    'ecall':  0x00000073,
    'ebreak': 0x00100073,
    'mret':   0x30200073,
}

#: every real (non-pseudo) mnemonic -- the 46 encodings of INTERFACES.md section 1
ALL_MNEMONICS = (
    sorted(R_INSNS) + sorted(I_ARITH) + sorted(I_SHIFT) + sorted(LOADS) +
    sorted(STORES) + sorted(BRANCHES) + ['lui', 'auipc', 'jal', 'jalr'] +
    sorted(SYSTEM_FIXED) + sorted(CSR_REG) + sorted(CSR_IMM)
)

#: explicitly unsupported (must be a clean assembler error, not "unknown")
UNSUPPORTED = {'fence', 'fence.i', 'wfi', 'sfence.vma', 'sret', 'uret', 'wfi.'}

PSEUDO = {
    'nop', 'li', 'mv', 'not', 'neg', 'seqz', 'snez', 'sltz', 'sgtz',
    'j', 'jr', 'ret', 'call', 'beqz', 'bnez', 'blez', 'bgez', 'bltz',
    'bgtz', 'bgt', 'ble', 'bgtu', 'bleu', 'la',
    'csrr', 'csrw', 'csrs', 'csrc', 'csrwi', 'csrsi', 'csrci',
}


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def u32(x: int) -> int:
    return x & 0xFFFFFFFF


def s32(x: int) -> int:
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def hi20(value: int) -> int:
    """%hi: sign-adjusted upper 20 bits so lui+addi reconstructs `value`."""
    return ((u32(value) + 0x800) >> 12) & 0xFFFFF


def lo12(value: int) -> int:
    """%lo: low 12 bits as a *signed* value in [-2048, 2047]."""
    v = u32(value) & 0xFFF
    return v - 0x1000 if v & 0x800 else v


# --------------------------------------------------------------------------
# Field packers
# --------------------------------------------------------------------------

def enc_r(funct7, rs2, rs1, funct3, rd, opcode):
    return u32((funct7 << 25) | (rs2 << 20) | (rs1 << 15) |
               (funct3 << 12) | (rd << 7) | opcode)


def enc_i(imm, rs1, funct3, rd, opcode):
    return u32(((imm & 0xFFF) << 20) | (rs1 << 15) |
               (funct3 << 12) | (rd << 7) | opcode)


def enc_s(imm, rs2, rs1, funct3, opcode):
    imm &= 0xFFF
    return u32((((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) |
               (funct3 << 12) | ((imm & 0x1F) << 7) | opcode)


def enc_b(imm, rs2, rs1, funct3, opcode):
    imm &= 0x1FFF                                  # 13-bit, bit0 always 0
    return u32((((imm >> 12) & 0x1) << 31) | (((imm >> 5) & 0x3F) << 25) |
               (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
               (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 0x1) << 7) | opcode)


def enc_u(imm20, rd, opcode):
    return u32(((imm20 & 0xFFFFF) << 12) | (rd << 7) | opcode)


def enc_j(imm, rd, opcode):
    imm &= 0x1FFFFF                                # 21-bit, bit0 always 0
    return u32((((imm >> 20) & 0x1) << 31) | (((imm >> 1) & 0x3FF) << 21) |
               (((imm >> 11) & 0x1) << 20) | (((imm >> 12) & 0xFF) << 12) |
               (rd << 7) | opcode)


# --------------------------------------------------------------------------
# Expression evaluation
# --------------------------------------------------------------------------

_TOK_RE = re.compile(r"""
      (?P<hi>%hi\s*\()
    | (?P<lo>%lo\s*\()
    | (?P<lp>\()
    | (?P<rp>\))
    | (?P<num>0[xX][0-9a-fA-F]+|0[bB][01]+|\d+)
    | (?P<sym>[A-Za-z_.$][A-Za-z0-9_.$]*)
    | (?P<op>[+\-])
    | (?P<ws>\s+)
""", re.VERBOSE)


class UndefinedSymbol(Exception):
    def __init__(self, name):
        super().__init__(name)
        self.name = name


def _tokenize(text):
    toks, pos = [], 0
    while pos < len(text):
        m = _TOK_RE.match(text, pos)
        if not m:
            raise ValueError(f"cannot parse expression at {text[pos:]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind != 'ws':
            toks.append((kind, m.group()))
    toks.append(('end', ''))
    return toks


class _ExprParser:
    def __init__(self, toks, symbols):
        self.toks = toks
        self.i = 0
        self.symbols = symbols

    def peek(self):
        return self.toks[self.i]

    def next(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def parse(self):
        v = self.expr()
        if self.peek()[0] != 'end':
            raise ValueError(f"trailing text {self.peek()[1]!r} in expression")
        return v

    def expr(self):
        v = self.unary()
        while self.peek()[0] == 'op':
            op = self.next()[1]
            r = self.unary()
            v = v + r if op == '+' else v - r
        return v

    def unary(self):
        if self.peek()[0] == 'op':
            op = self.next()[1]
            v = self.unary()
            return v if op == '+' else -v
        return self.atom()

    def atom(self):
        kind, text = self.next()
        if kind == 'num':
            t = text.lower()
            if t.startswith('0x'):
                return int(t, 16)
            if t.startswith('0b'):
                return int(t, 2)
            return int(t, 10)
        if kind == 'sym':
            if text not in self.symbols:
                raise UndefinedSymbol(text)
            return self.symbols[text]
        if kind == 'lp':
            v = self.expr()
            if self.next()[0] != 'rp':
                raise ValueError("missing ')'")
            return v
        if kind in ('hi', 'lo'):
            v = self.expr()
            if self.next()[0] != 'rp':
                raise ValueError("missing ')' after %s" % kind)
            return hi20(v) if kind == 'hi' else lo12(v)
        raise ValueError(f"unexpected token {text!r} in expression")


def eval_expr(text, symbols):
    """Evaluate an immediate expression. Raises UndefinedSymbol / ValueError."""
    text = text.strip()
    if not text:
        raise ValueError("empty expression")
    return _ExprParser(_tokenize(text), symbols).parse()


# --------------------------------------------------------------------------
# The assembler
# --------------------------------------------------------------------------

_LABEL_RE = re.compile(r'^([A-Za-z_.$][A-Za-z0-9_.$]*)\s*:')
_MEM_RE   = re.compile(r'^(.*)\(\s*([A-Za-z_][A-Za-z0-9_]*|x\d{1,2})\s*\)$')


class Assembler:
    def __init__(self, path='<string>'):
        self.path = path
        self.symbols = {}
        self.records = []
        self.image = {'text': {}, 'data': {}}
        self.used = {'text': 0, 'data': 0}
        self.lineno = 0
        self.srcline = ''

    # ---- errors -----------------------------------------------------------
    def err(self, msg):
        raise AsmError("%s:%d: %s\n    %s" %
                       (self.path, self.lineno, msg, self.srcline.strip()))

    # ---- operand parsing --------------------------------------------------
    def reg(self, tok):
        t = tok.strip()
        tl = t.lower()
        if tl in ABI_REGS:
            return ABI_REGS[tl]
        m = re.fullmatch(r'x(\d{1,2})', tl)
        if m and 0 <= int(m.group(1)) <= 31:
            return int(m.group(1))
        self.err("invalid register name %r" % t)

    def imm(self, tok, symbols):
        try:
            return eval_expr(tok, symbols)
        except UndefinedSymbol as e:
            self.err("undefined symbol %r" % e.name)
        except ValueError as e:
            self.err("bad immediate %r (%s)" % (tok.strip(), e))

    def csr(self, tok, symbols):
        t = tok.strip().lower()
        if t in CSR_NAMES:
            return CSR_NAMES[t]
        v = self.imm(tok, symbols)
        if not 0 <= v <= 0xFFF:
            self.err("CSR address %d out of range 0..0xfff" % v)
        return v

    def mem_operand(self, tok):
        """Parse `imm(rs1)` -> (imm_text, rs1_text). `(rs1)` means offset 0."""
        m = _MEM_RE.match(tok.strip())
        if not m:
            self.err("expected `imm(reg)` operand, got %r" % tok.strip())
        off = m.group(1).strip() or '0'
        return off, m.group(2)

    def check_range(self, value, lo, hi, what):
        if not lo <= value <= hi:
            self.err("%s %d (0x%x) out of range [%d, %d]" %
                     (what, value, u32(value), lo, hi))
        return value

    # ---- pseudo-instruction expansion ------------------------------------
    def expand(self, mnem, ops, symbols):
        """Return a list of (mnemonic, [operand strings]) real instructions."""
        n = len(ops)

        def need(k):
            if n != k:
                self.err("%s expects %d operand(s), got %d" % (mnem, k, n))

        if mnem == 'nop':
            need(0)
            return [('addi', ['x0', 'x0', '0'])]
        if mnem == 'li':
            need(2)
            try:
                v = eval_expr(ops[1], symbols)
            except UndefinedSymbol as e:
                self.err("li needs a constant; %r is not defined here "
                         "(use `la` for addresses)" % e.name)
            except ValueError as e:
                self.err("bad immediate %r (%s)" % (ops[1], e))
            v = s32(v)
            if -2048 <= v <= 2047:
                return [('addi', [ops[0], 'x0', str(v)])]
            return [('lui',  [ops[0], str(hi20(v))]),
                    ('addi', [ops[0], ops[0], str(lo12(v))])]
        if mnem == 'la':
            need(2)
            return [('lui',  [ops[0], '%%hi(%s)' % ops[1]]),
                    ('addi', [ops[0], ops[0], '%%lo(%s)' % ops[1]])]
        if mnem == 'mv':
            need(2)
            return [('addi', [ops[0], ops[1], '0'])]
        if mnem == 'not':
            need(2)
            return [('xori', [ops[0], ops[1], '-1'])]
        if mnem == 'neg':
            need(2)
            return [('sub', [ops[0], 'x0', ops[1]])]
        if mnem == 'seqz':
            need(2)
            return [('sltiu', [ops[0], ops[1], '1'])]
        if mnem == 'snez':
            need(2)
            return [('sltu', [ops[0], 'x0', ops[1]])]
        if mnem == 'sltz':
            need(2)
            return [('slt', [ops[0], ops[1], 'x0'])]
        if mnem == 'sgtz':
            need(2)
            return [('slt', [ops[0], 'x0', ops[1]])]
        if mnem == 'j':
            need(1)
            return [('jal', ['x0', ops[0]])]
        if mnem == 'jr':
            need(1)
            return [('jalr', ['x0', ops[0], '0'])]
        if mnem == 'ret':
            need(0)
            return [('jalr', ['x0', 'x1', '0'])]
        if mnem == 'call':
            need(1)
            return [('jal', ['x1', ops[0]])]
        if mnem in ('beqz', 'bnez', 'blez', 'bgez', 'bltz', 'bgtz'):
            need(2)
            table = {'beqz': ('beq', True), 'bnez': ('bne', True),
                     'bgez': ('bge', True), 'bltz': ('blt', True),
                     'blez': ('bge', False), 'bgtz': ('blt', False)}
            real, rs_first = table[mnem]
            if rs_first:
                return [(real, [ops[0], 'x0', ops[1]])]
            return [(real, ['x0', ops[0], ops[1]])]
        if mnem in ('bgt', 'ble', 'bgtu', 'bleu'):
            need(3)
            real = {'bgt': 'blt', 'ble': 'bge',
                    'bgtu': 'bltu', 'bleu': 'bgeu'}[mnem]
            return [(real, [ops[1], ops[0], ops[2]])]
        if mnem == 'csrr':
            need(2)
            return [('csrrs', [ops[0], ops[1], 'x0'])]
        if mnem in ('csrw', 'csrs', 'csrc'):
            need(2)
            real = {'csrw': 'csrrw', 'csrs': 'csrrs', 'csrc': 'csrrc'}[mnem]
            return [(real, ['x0', ops[0], ops[1]])]
        if mnem in ('csrwi', 'csrsi', 'csrci'):
            need(2)
            real = {'csrwi': 'csrrwi', 'csrsi': 'csrrsi',
                    'csrci': 'csrrci'}[mnem]
            return [(real, ['x0', ops[0], ops[1]])]
        return [(mnem, ops)]

    # ---- encoding of one real instruction ---------------------------------
    def encode_one(self, mnem, ops, pc, symbols):
        n = len(ops)

        def need(k, form):
            if n != k:
                self.err("%s expects `%s`" % (mnem, form))

        if mnem in R_INSNS:
            need(3, "%s rd, rs1, rs2" % mnem)
            f7, f3 = R_INSNS[mnem]
            return enc_r(f7, self.reg(ops[2]), self.reg(ops[1]), f3,
                         self.reg(ops[0]), OP_R)

        if mnem in I_ARITH:
            need(3, "%s rd, rs1, imm" % mnem)
            imm = self.imm(ops[2], symbols)
            self.check_range(imm, -2048, 2047, "%s immediate" % mnem)
            return enc_i(imm, self.reg(ops[1]), I_ARITH[mnem],
                         self.reg(ops[0]), OP_IARITH)

        if mnem in I_SHIFT:
            need(3, "%s rd, rs1, shamt" % mnem)
            f7, f3 = I_SHIFT[mnem]
            sh = self.imm(ops[2], symbols)
            self.check_range(sh, 0, 31, "%s shift amount" % mnem)
            return enc_i((f7 << 5) | sh, self.reg(ops[1]), f3,
                         self.reg(ops[0]), OP_IARITH)

        if mnem in LOADS:
            need(2, "%s rd, imm(rs1)" % mnem)
            off, rs1 = self.mem_operand(ops[1])
            imm = self.imm(off, symbols)
            self.check_range(imm, -2048, 2047, "%s offset" % mnem)
            return enc_i(imm, self.reg(rs1), LOADS[mnem],
                         self.reg(ops[0]), OP_LOAD)

        if mnem in STORES:
            need(2, "%s rs2, imm(rs1)" % mnem)
            off, rs1 = self.mem_operand(ops[1])
            imm = self.imm(off, symbols)
            self.check_range(imm, -2048, 2047, "%s offset" % mnem)
            return enc_s(imm, self.reg(ops[0]), self.reg(rs1),
                         STORES[mnem], OP_STORE)

        if mnem in BRANCHES:
            need(3, "%s rs1, rs2, label" % mnem)
            target = self.branch_target(ops[2], pc, symbols)
            self.check_range(target, -4096, 4094, "%s offset" % mnem)
            if target & 1:
                self.err("%s target offset %d is misaligned (must be even)"
                         % (mnem, target))
            return enc_b(target, self.reg(ops[1]), self.reg(ops[0]),
                         BRANCHES[mnem], OP_BRANCH)

        if mnem in ('lui', 'auipc'):
            need(2, "%s rd, imm20" % mnem)
            imm = self.imm(ops[1], symbols)
            self.check_range(imm, -0x80000, 0xFFFFF, "%s immediate" % mnem)
            op = OP_LUI if mnem == 'lui' else OP_AUIPC
            return enc_u(imm & 0xFFFFF, self.reg(ops[0]), op)

        if mnem == 'jal':
            if n == 1:                                  # jal label => jal ra
                ops = ['x1', ops[0]]
                n = 2
            need(2, "jal rd, label")
            target = self.branch_target(ops[1], pc, symbols)
            self.check_range(target, -1048576, 1048574, "jal offset")
            if target & 1:
                self.err("jal target offset %d is misaligned (must be even)"
                         % target)
            return enc_j(target, self.reg(ops[0]), OP_JAL)

        if mnem == 'jalr':
            if n == 1:                                  # jalr rs => jalr ra,rs,0
                rd, rs1, imm_txt = 'x1', ops[0], '0'
            elif n == 2:                                # jalr rd, imm(rs1)
                off, rs1 = self.mem_operand(ops[1])
                rd, imm_txt = ops[0], off
            elif n == 3:                                # jalr rd, rs1, imm
                rd, rs1, imm_txt = ops[0], ops[1], ops[2]
            else:
                self.err("jalr expects `jalr rd, imm(rs1)`, "
                         "`jalr rd, rs1, imm` or `jalr rs1`")
            imm = self.imm(imm_txt, symbols)
            self.check_range(imm, -2048, 2047, "jalr offset")
            return enc_i(imm, self.reg(rs1), 0x0, self.reg(rd), OP_JALR)

        if mnem in SYSTEM_FIXED:
            need(0, mnem)
            return SYSTEM_FIXED[mnem]

        if mnem in CSR_REG:
            need(3, "%s rd, csr, rs1" % mnem)
            return enc_i(self.csr(ops[1], symbols), self.reg(ops[2]),
                         CSR_REG[mnem], self.reg(ops[0]), OP_SYSTEM)

        if mnem in CSR_IMM:
            need(3, "%s rd, csr, zimm" % mnem)
            z = self.imm(ops[2], symbols)
            self.check_range(z, 0, 31, "%s zimm" % mnem)
            return enc_i(self.csr(ops[1], symbols), z,
                         CSR_IMM[mnem], self.reg(ops[0]), OP_SYSTEM)

        if mnem in UNSUPPORTED:
            self.err("instruction %r is not supported by this CPU" % mnem)
        self.err("unknown instruction %r" % mnem)

    def branch_target(self, tok, pc, symbols):
        """Label -> PC-relative offset; bare number -> offset as written."""
        t = tok.strip()
        if re.fullmatch(r'[A-Za-z_.$][A-Za-z0-9_.$]*', t):
            if t not in symbols:
                self.err("undefined label %r" % t)
            return symbols[t] - pc
        return self.imm(t, symbols)

    # ---- parsing / pass 1 -------------------------------------------------
    def parse(self, text):
        section = 'text'
        addr = {'text': 0, 'data': 0}
        for lineno, raw in enumerate(text.splitlines(), 1):
            self.lineno, self.srcline = lineno, raw
            line = raw
            cut = len(line)
            for ch in ('#', ';'):
                p = line.find(ch)
                if p >= 0:
                    cut = min(cut, p)
            line = line[:cut].strip()
            # labels (possibly several, possibly followed by code)
            while True:
                m = _LABEL_RE.match(line)
                if not m:
                    break
                name = m.group(1)
                if name in self.symbols:
                    self.err("duplicate label %r" % name)
                self.symbols[name] = addr[section]
                line = line[m.end():].strip()
            if not line:
                continue

            parts = line.split(None, 1)
            head = parts[0]
            rest = parts[1].strip() if len(parts) > 1 else ''
            ops = [o.strip() for o in rest.split(',')] if rest else []

            if head.startswith('.'):
                section, addr = self.directive(head.lower(), ops, rest,
                                               section, addr, raw)
                continue

            mnem = head.lower()
            if mnem not in ALL_MNEMONICS and mnem not in PSEUDO:
                if mnem in UNSUPPORTED:
                    self.err("instruction %r is not supported by this CPU"
                             % mnem)
                self.err("unknown instruction %r" % mnem)
            expanded = self.expand(mnem, ops, self.symbols)
            a = addr[section]
            if a & 3:
                self.err("instruction at address 0x%x is not word aligned" % a)
            self.records.append({
                'kind': 'insn', 'section': section, 'addr': a,
                'insns': expanded, 'lineno': lineno, 'src': raw,
            })
            addr[section] = a + 4 * len(expanded)
            self.used[section] = max(self.used[section], addr[section])
        return addr

    def directive(self, name, ops, rest, section, addr, raw):
        if name == '.text':
            return 'text', addr
        if name == '.data':
            return 'data', addr
        if name == '.globl' or name == '.global':
            return section, addr
        if name == '.equ' or name == '.set':
            if len(ops) != 2:
                self.err(".equ expects `name, value`")
            try:
                self.symbols[ops[0]] = eval_expr(ops[1], self.symbols)
            except UndefinedSymbol as e:
                self.err(".equ value uses undefined symbol %r" % e.name)
            except ValueError as e:
                self.err(".equ bad value %r (%s)" % (ops[1], e))
            return section, addr
        if name in ('.word', '.half', '.byte'):
            size = {'.word': 4, '.half': 2, '.byte': 1}[name]
            if not ops or ops == ['']:
                self.err("%s expects at least one value" % name)
            self.records.append({
                'kind': 'data', 'section': section, 'addr': addr[section],
                'size': size, 'values': ops, 'lineno': self.lineno, 'src': raw,
            })
            addr[section] += size * len(ops)
            self.used[section] = max(self.used[section], addr[section])
            return section, addr
        if name == '.space' or name == '.zero':
            if len(ops) != 1:
                self.err(".space expects one value")
            n = self.imm(ops[0], self.symbols)
            if n < 0:
                self.err(".space size must be >= 0")
            addr[section] += n
            self.used[section] = max(self.used[section], addr[section])
            return section, addr
        if name == '.align':
            if len(ops) != 1:
                self.err(".align expects one value")
            n = self.imm(ops[0], self.symbols)
            if n <= 0 or (n & (n - 1)):
                self.err(".align argument must be a power of two "
                         "(byte boundary), got %d" % n)
            a = addr[section]
            addr[section] = (a + n - 1) & ~(n - 1)
            self.used[section] = max(self.used[section], addr[section])
            return section, addr
        if name == '.org':
            if len(ops) != 1:
                self.err(".org expects one address")
            a = self.imm(ops[0], self.symbols)
            if a < 0:
                self.err(".org address must be >= 0")
            addr[section] = a
            self.used[section] = max(self.used[section], addr[section])
            return section, addr
        self.err("unknown directive %r" % name)

    # ---- pass 2 -----------------------------------------------------------
    def emit(self, section, addr, value, nbytes):
        img = self.image[section]
        for i in range(nbytes):
            a = addr + i
            if not 0 <= a < MEM_BYTES:
                self.err("address 0x%x is outside the 4 KB %s memory"
                         % (a, section))
            img[a] = (value >> (8 * i)) & 0xFF
        self.used[section] = max(self.used[section], addr + nbytes)

    def encode_all_records(self):
        for rec in self.records:
            self.lineno, self.srcline = rec['lineno'], rec['src']
            if rec['kind'] == 'insn':
                pc = rec['addr']
                words = []
                for mnem, ops in rec['insns']:
                    w = self.encode_one(mnem, ops, pc, self.symbols)
                    self.emit(rec['section'], pc, w, 4)
                    words.append(w)
                    pc += 4
                rec['words'] = words
            else:
                a = rec['addr']
                size = rec['size']
                words = []
                for v in rec['values']:
                    val = self.imm(v, self.symbols)
                    lim = {1: 0xFF, 2: 0xFFFF, 4: 0xFFFFFFFF}[size]
                    if not -(lim + 1) // 2 <= val <= lim:
                        self.err("value %d does not fit in %d byte(s)"
                                 % (val, size))
                    self.emit(rec['section'], a, u32(val), size)
                    words.append(u32(val) & lim)
                    a += size
                rec['words'] = words

    def words(self, section):
        out = [0] * MEM_WORDS
        for a, b in self.image[section].items():
            out[a >> 2] |= b << (8 * (a & 3))
        return out

    def data_nonempty(self):
        return self.used['data'] > 0

    def listing(self):
        lines = ["# addr      word      source"]
        for rec in self.records:
            a = rec['addr']
            words = rec.get('words', [])
            src = rec['src'].rstrip()
            if rec['kind'] == 'insn':
                for i, w in enumerate(words):
                    lines.append("%08x  %08x  %s" %
                                 (a + 4 * i, w, src if i == 0 else ''))
            else:
                size = rec['size']
                for i, w in enumerate(words):
                    lines.append("%08x  %0*x%s  %s" %
                                 (a + size * i, size * 2, w,
                                  ' ' * (8 - size * 2),
                                  src if i == 0 else ''))
        return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Public module API
# --------------------------------------------------------------------------

def assemble_full(source_text, path='<string>'):
    """Assemble; return the Assembler (records, symbols, images) for tooling."""
    a = Assembler(path)
    a.parse(source_text)
    a.encode_all_records()
    return a


def assemble(source_text, path='<string>'):
    """Assemble source text.

    Returns (text_words, data_words, symbols); both word lists are exactly
    1024 entries long, matching the .hex files.
    """
    a = assemble_full(source_text, path)
    return a.words('text'), a.words('data'), dict(a.symbols)


def encode_all(mnemonic, *operands, pc=0, symbols=None):
    """Encode one source instruction (pseudo allowed) -> list of words."""
    if len(operands) == 1 and (',' in operands[0] or operands[0] == ''):
        ops = [o.strip() for o in operands[0].split(',')] if operands[0] else []
    else:
        ops = [str(o).strip() for o in operands]
    a = Assembler('<encode>')
    a.symbols = dict(symbols or {})
    a.lineno = 0
    a.srcline = "%s %s" % (mnemonic, ', '.join(ops))
    mnem = mnemonic.lower()
    if mnem not in ALL_MNEMONICS and mnem not in PSEUDO:
        a.err("unknown instruction %r" % mnem)
    out, p = [], pc
    for m, o in a.expand(mnem, ops, a.symbols):
        out.append(a.encode_one(m, o, p, a.symbols))
        p += 4
    return out


def encode(mnemonic, *operands, pc=0, symbols=None):
    """Encode one *real* instruction -> a single 32-bit word."""
    words = encode_all(mnemonic, *operands, pc=pc, symbols=symbols)
    if len(words) != 1:
        raise AsmError("%s expands to %d instructions; use encode_all()"
                       % (mnemonic, len(words)))
    return words[0]


def hex_text(words):
    """1024 lines of lowercase 8-hex-digit words, one trailing newline."""
    if len(words) > MEM_WORDS:
        raise AsmError("image is %d words, memory holds %d"
                       % (len(words), MEM_WORDS))
    padded = list(words) + [0] * (MEM_WORDS - len(words))
    return "".join("%08x\n" % (w & 0xFFFFFFFF) for w in padded)


def write_hex(path, words):
    with open(path, 'w', newline='\n') as fp:
        fp.write(hex_text(words))


def data_hex_path(out_path):
    base = out_path[:-4] if out_path.lower().endswith('.hex') else out_path
    return base + '.data.hex'


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="RV32I assembler (Pipeline-CPU project)")
    ap.add_argument('source')
    ap.add_argument('-o', '--output', help="output .hex path")
    ap.add_argument('--list', action='store_true',
                    help="also write a <base>.lst listing")
    ap.add_argument('--bin-json', action='store_true',
                    help='print {"text":[...],"data":[...]} to stdout')
    args = ap.parse_args(argv)

    with open(args.source, 'r') as fp:
        src = fp.read()

    try:
        a = assemble_full(src, args.source)
    except AsmError as e:
        sys.stderr.write("error: %s\n" % e)
        return 1

    text_words = a.words('text')
    data_words = a.words('data')

    if args.bin_json:
        ntext = (a.used['text'] + 3) // 4
        ndata = (a.used['data'] + 3) // 4
        json.dump({'text': text_words[:ntext], 'data': data_words[:ndata]},
                  sys.stdout)
        sys.stdout.write("\n")

    if args.output:
        d = os.path.dirname(os.path.abspath(args.output))
        if d:
            os.makedirs(d, exist_ok=True)
        write_hex(args.output, text_words)
        if a.data_nonempty():
            write_hex(data_hex_path(args.output), data_words)
        if args.list:
            base = args.output
            if base.lower().endswith('.hex'):
                base = base[:-4]
            with open(base + '.lst', 'w', newline='\n') as fp:
                fp.write(a.listing())
    elif not args.bin_json:
        sys.stderr.write("error: nothing to do (give -o FILE or --bin-json)\n")
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
