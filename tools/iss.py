#!/usr/bin/env python3
"""RV32I instruction-set simulator -- golden reference for the Pipeline-CPU.

Implements exactly the contract in docs/INTERFACES.md sections 1, 2, 3 and 5.
Pure standard library.

CLI
    python tools/iss.py prog.hex [--data prog.data.hex] [--trace prog.trace]
                        [--max-insns N] [--irq-after N] [--dump-regs]
                        [--dump-mem lo hi]

Exit codes (testbench contract):
    0  ebreak retired
    2  --max-insns exceeded
    3  illegal instruction (message on stderr)

Module
    from iss import Cpu, decode, Decoded, IllegalInstruction
"""

from __future__ import annotations

import argparse
import os
import sys

MEM_WORDS = 1024
MEM_MASK = 0xFFF                      # 4 KB, addresses above bit 11 ignored
WORD_INDEX_MASK = MEM_WORDS - 1

CSR_MSTATUS = 0x300
CSR_MIE     = 0x304
CSR_MTVEC   = 0x305
CSR_MEPC    = 0x341
CSR_MCAUSE  = 0x342

CAUSE_ECALL_M = 11
CAUSE_MEI     = 0x8000000B            # interrupt bit | 11


class IllegalInstruction(Exception):
    def __init__(self, pc, insn):
        super().__init__("illegal instruction 0x%08x at pc 0x%08x" % (insn, pc))
        self.pc = pc
        self.insn = insn


def u32(x):
    return x & 0xFFFFFFFF


def s32(x):
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def sext(value, bits):
    m = 1 << (bits - 1)
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & m else value


# --------------------------------------------------------------------------
# Decoder
# --------------------------------------------------------------------------

_R = {(0x00, 0x0): 'add', (0x20, 0x0): 'sub', (0x00, 0x1): 'sll',
      (0x00, 0x2): 'slt', (0x00, 0x3): 'sltu', (0x00, 0x4): 'xor',
      (0x00, 0x5): 'srl', (0x20, 0x5): 'sra', (0x00, 0x6): 'or',
      (0x00, 0x7): 'and'}
_IA = {0x0: 'addi', 0x2: 'slti', 0x3: 'sltiu',
       0x4: 'xori', 0x6: 'ori', 0x7: 'andi'}
_LD = {0x0: 'lb', 0x1: 'lh', 0x2: 'lw', 0x4: 'lbu', 0x5: 'lhu'}
_ST = {0x0: 'sb', 0x1: 'sh', 0x2: 'sw'}
_BR = {0x0: 'beq', 0x1: 'bne', 0x4: 'blt',
       0x5: 'bge', 0x6: 'bltu', 0x7: 'bgeu'}
_CSRR = {0x1: 'csrrw', 0x2: 'csrrs', 0x3: 'csrrc'}
_CSRI = {0x5: 'csrrwi', 0x6: 'csrrsi', 0x7: 'csrrci'}


class Decoded:
    """Decoded instruction.

    `imm` conventions (chosen so they round-trip against the assembler's
    source operands exactly):
      I-arith / load / jalr : signed 12-bit immediate
      shifts                : shamt, 0..31
      store                 : signed 12-bit immediate
      branch / jal          : signed byte offset relative to this PC
      lui / auipc           : the raw 20-bit field (NOT shifted left by 12)
      CSR immediate forms   : `zimm` holds the zero-extended 5-bit immediate
    """

    __slots__ = ('mnem', 'fmt', 'rd', 'rs1', 'rs2', 'imm', 'csr', 'zimm',
                 'raw')

    def __init__(self, mnem, fmt, raw, rd=0, rs1=0, rs2=0, imm=0,
                 csr=None, zimm=None):
        self.mnem = mnem
        self.fmt = fmt
        self.raw = raw
        self.rd = rd
        self.rs1 = rs1
        self.rs2 = rs2
        self.imm = imm
        self.csr = csr
        self.zimm = zimm

    def __repr__(self):
        return ("Decoded(%s fmt=%s rd=%d rs1=%d rs2=%d imm=%d csr=%s zimm=%s)"
                % (self.mnem, self.fmt, self.rd, self.rs1, self.rs2,
                   self.imm, self.csr, self.zimm))


def decode(insn, pc=0):
    """Decode a 32-bit instruction word. Raises IllegalInstruction."""
    insn = u32(insn)
    opcode = insn & 0x7F
    rd = (insn >> 7) & 0x1F
    rs1 = (insn >> 15) & 0x1F
    rs2 = (insn >> 20) & 0x1F
    funct3 = (insn >> 12) & 0x7
    funct7 = (insn >> 25) & 0x7F

    if opcode == 0x33:
        m = _R.get((funct7, funct3))
        if m is None:
            raise IllegalInstruction(pc, insn)
        return Decoded(m, 'R', insn, rd=rd, rs1=rs1, rs2=rs2)

    if opcode == 0x13:
        if funct3 in (0x1, 0x5):
            if funct3 == 0x1 and funct7 == 0x00:
                m = 'slli'
            elif funct3 == 0x5 and funct7 == 0x00:
                m = 'srli'
            elif funct3 == 0x5 and funct7 == 0x20:
                m = 'srai'
            else:
                raise IllegalInstruction(pc, insn)
            return Decoded(m, 'I-shift', insn, rd=rd, rs1=rs1, imm=rs2)
        m = _IA.get(funct3)
        if m is None:
            raise IllegalInstruction(pc, insn)
        return Decoded(m, 'I', insn, rd=rd, rs1=rs1, imm=sext(insn >> 20, 12))

    if opcode == 0x03:
        m = _LD.get(funct3)
        if m is None:
            raise IllegalInstruction(pc, insn)
        return Decoded(m, 'I-load', insn, rd=rd, rs1=rs1,
                       imm=sext(insn >> 20, 12))

    if opcode == 0x23:
        m = _ST.get(funct3)
        if m is None:
            raise IllegalInstruction(pc, insn)
        imm = ((insn >> 25) << 5) | ((insn >> 7) & 0x1F)
        return Decoded(m, 'S', insn, rs1=rs1, rs2=rs2, imm=sext(imm, 12))

    if opcode == 0x63:
        m = _BR.get(funct3)
        if m is None:
            raise IllegalInstruction(pc, insn)
        imm = ((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11) |
               (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1))
        return Decoded(m, 'B', insn, rs1=rs1, rs2=rs2, imm=sext(imm, 13))

    if opcode == 0x37:
        return Decoded('lui', 'U', insn, rd=rd, imm=(insn >> 12) & 0xFFFFF)
    if opcode == 0x17:
        return Decoded('auipc', 'U', insn, rd=rd, imm=(insn >> 12) & 0xFFFFF)

    if opcode == 0x6F:
        imm = ((((insn >> 31) & 1) << 20) | (((insn >> 12) & 0xFF) << 12) |
               (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1))
        return Decoded('jal', 'J', insn, rd=rd, imm=sext(imm, 21))

    if opcode == 0x67:
        if funct3 != 0:
            raise IllegalInstruction(pc, insn)
        return Decoded('jalr', 'I-jalr', insn, rd=rd, rs1=rs1,
                       imm=sext(insn >> 20, 12))

    if opcode == 0x73:
        if funct3 == 0:
            if insn == 0x00000073:
                return Decoded('ecall', 'SYS', insn)
            if insn == 0x00100073:
                return Decoded('ebreak', 'SYS', insn)
            if insn == 0x30200073:
                return Decoded('mret', 'SYS', insn)
            raise IllegalInstruction(pc, insn)
        csr = (insn >> 20) & 0xFFF
        if funct3 in _CSRR:
            return Decoded(_CSRR[funct3], 'CSR-R', insn, rd=rd, rs1=rs1,
                           csr=csr)
        if funct3 in _CSRI:
            return Decoded(_CSRI[funct3], 'CSR-I', insn, rd=rd, csr=csr,
                           zimm=rs1)
        raise IllegalInstruction(pc, insn)

    raise IllegalInstruction(pc, insn)


# --------------------------------------------------------------------------
# CPU
# --------------------------------------------------------------------------

class Cpu:
    """RV32I core with the simplified M-mode CSR/trap model of INTERFACES.md."""

    def __init__(self, imem=None, dmem=None, irq_after=(), max_insns=1000000):
        self.imem = list(imem or [])[:MEM_WORDS]
        self.imem += [0] * (MEM_WORDS - len(self.imem))
        self.dmem = list(dmem or [])[:MEM_WORDS]
        self.dmem += [0] * (MEM_WORDS - len(self.dmem))
        self.regs = [0] * 32
        self.pc = 0
        self.retired = 0            # retired instruction count
        self.steps = 0              # executed steps (traps included)
        self.halted = False
        self.exit_code = 0
        self.max_insns = max_insns
        self.trace_lines = []
        # pending one-shot interrupts keyed by retirement index
        self.irq_pending = {}
        for n in irq_after:
            self.irq_pending[n] = self.irq_pending.get(n, 0) + 1
        # CSRs
        self.mstatus_mie = 0
        self.mstatus_mpie = 0
        self.mie_meie = 0
        self.mtvec = 0
        self.mepc = 0
        self.mcause = 0

    # ---- register helpers -------------------------------------------------
    def rd_reg(self, n):
        return self.regs[n] if n else 0

    def wr_reg(self, n, value):
        if n:
            self.regs[n] = u32(value)

    # ---- memory -----------------------------------------------------------
    def _widx(self, addr):
        return (addr >> 2) & WORD_INDEX_MASK

    def load(self, addr, mnem):
        w = self.dmem[self._widx(addr)]
        if mnem == 'lw':
            return u32(w)
        if mnem in ('lh', 'lhu'):
            half = (w >> (16 * ((addr >> 1) & 1))) & 0xFFFF
            return u32(sext(half, 16)) if mnem == 'lh' else half
        byte = (w >> (8 * (addr & 3))) & 0xFF
        return u32(sext(byte, 8)) if mnem == 'lb' else byte

    def store(self, addr, value, mnem):
        """Perform the store; return the value shown in the commit trace."""
        i = self._widx(addr)
        w = self.dmem[i]
        if mnem == 'sw':
            self.dmem[i] = u32(value)
            return u32(value)
        if mnem == 'sh':
            v = value & 0xFFFF
            sh = 16 * ((addr >> 1) & 1)
            self.dmem[i] = u32((w & ~(0xFFFF << sh)) | (v << sh))
            return v
        v = value & 0xFF
        sh = 8 * (addr & 3)
        self.dmem[i] = u32((w & ~(0xFF << sh)) | (v << sh))
        return v

    # ---- CSRs -------------------------------------------------------------
    def csr_read(self, addr):
        if addr == CSR_MSTATUS:
            return (self.mstatus_mie << 3) | (self.mstatus_mpie << 7)
        if addr == CSR_MIE:
            return self.mie_meie << 11
        if addr == CSR_MTVEC:
            return self.mtvec & 0xFFFFFFFC
        if addr == CSR_MEPC:
            return self.mepc & 0xFFFFFFFC
        if addr == CSR_MCAUSE:
            return u32(self.mcause)
        return 0

    def csr_write(self, addr, value):
        value = u32(value)
        if addr == CSR_MSTATUS:
            self.mstatus_mie = (value >> 3) & 1
            self.mstatus_mpie = (value >> 7) & 1
        elif addr == CSR_MIE:
            self.mie_meie = (value >> 11) & 1
        elif addr == CSR_MTVEC:
            self.mtvec = value & 0xFFFFFFFC
        elif addr == CSR_MEPC:
            self.mepc = value & 0xFFFFFFFC
        elif addr == CSR_MCAUSE:
            self.mcause = value
        # every other CSR: writes ignored

    def enter_trap(self, epc, cause):
        self.mepc = u32(epc) & 0xFFFFFFFC
        self.mcause = u32(cause)
        self.mstatus_mpie = self.mstatus_mie
        self.mstatus_mie = 0
        self.pc = u32(self.mtvec) & 0xFFFFFFFC

    # ---- execution --------------------------------------------------------
    def step(self):
        """Execute one instruction (or take a pending trap).

        Returns the commit-trace line (str) if an instruction retired,
        otherwise None. Sets self.halted / self.exit_code on ebreak.
        """
        if self.halted:
            return None
        self.steps += 1

        # interrupt sampled at the instruction boundary before retirement N
        if self.retired in self.irq_pending:
            self.irq_pending[self.retired] -= 1
            if self.irq_pending[self.retired] <= 0:
                del self.irq_pending[self.retired]
            if self.mstatus_mie and self.mie_meie:
                self.enter_trap(self.pc, CAUSE_MEI)
                return None
            # otherwise the pulse is dropped

        pc = u32(self.pc)
        insn = u32(self.imem[self._widx(pc)])
        d = decode(insn, pc)

        rd_we = False
        rd_val = 0
        mem_we = False
        mem_addr = 0
        mem_val = 0
        next_pc = u32(pc + 4)

        m = d.mnem
        a = self.rd_reg(d.rs1)
        b = self.rd_reg(d.rs2)

        if d.fmt == 'R':
            if m == 'add':
                r = u32(a + b)
            elif m == 'sub':
                r = u32(a - b)
            elif m == 'sll':
                r = u32(a << (b & 31))
            elif m == 'slt':
                r = 1 if s32(a) < s32(b) else 0
            elif m == 'sltu':
                r = 1 if a < b else 0
            elif m == 'xor':
                r = a ^ b
            elif m == 'srl':
                r = a >> (b & 31)
            elif m == 'sra':
                r = u32(s32(a) >> (b & 31))
            elif m == 'or':
                r = a | b
            else:                                     # and
                r = a & b
            rd_we, rd_val = True, u32(r)

        elif d.fmt == 'I':
            imm = d.imm
            if m == 'addi':
                r = u32(a + imm)
            elif m == 'slti':
                r = 1 if s32(a) < imm else 0
            elif m == 'sltiu':
                r = 1 if a < u32(imm) else 0
            elif m == 'xori':
                r = a ^ u32(imm)
            elif m == 'ori':
                r = a | u32(imm)
            else:                                     # andi
                r = a & u32(imm)
            rd_we, rd_val = True, u32(r)

        elif d.fmt == 'I-shift':
            sh = d.imm & 31
            if m == 'slli':
                r = u32(a << sh)
            elif m == 'srli':
                r = a >> sh
            else:                                     # srai
                r = u32(s32(a) >> sh)
            rd_we, rd_val = True, u32(r)

        elif d.fmt == 'I-load':
            addr = u32(a + d.imm)
            rd_we, rd_val = True, u32(self.load(addr, m))

        elif d.fmt == 'S':
            addr = u32(a + d.imm)
            mem_we = True
            mem_addr = addr
            mem_val = self.store(addr, b, m)

        elif d.fmt == 'B':
            if m == 'beq':
                take = a == b
            elif m == 'bne':
                take = a != b
            elif m == 'blt':
                take = s32(a) < s32(b)
            elif m == 'bge':
                take = s32(a) >= s32(b)
            elif m == 'bltu':
                take = a < b
            else:                                     # bgeu
                take = a >= b
            if take:
                next_pc = u32(pc + d.imm)

        elif d.fmt == 'U':
            val = u32(d.imm << 12)
            rd_we, rd_val = True, u32(val if m == 'lui' else pc + val)

        elif d.fmt == 'J':
            rd_we, rd_val = True, u32(pc + 4)
            next_pc = u32(pc + d.imm)

        elif d.fmt == 'I-jalr':
            rd_we, rd_val = True, u32(pc + 4)
            next_pc = u32(a + d.imm) & 0xFFFFFFFE

        elif d.fmt in ('CSR-R', 'CSR-I'):
            old = u32(self.csr_read(d.csr))
            if d.fmt == 'CSR-R':
                src = a
                do_write = (m == 'csrrw') or (d.rs1 != 0)
            else:
                src = u32(d.zimm)
                do_write = (m == 'csrrwi') or (d.zimm != 0)
            if do_write:
                if m in ('csrrw', 'csrrwi'):
                    new = src
                elif m in ('csrrs', 'csrrsi'):
                    new = old | src
                else:                                 # csrrc / csrrci
                    new = old & u32(~src)
                self.csr_write(d.csr, new)
            rd_we, rd_val = True, old

        elif d.fmt == 'SYS':
            if m == 'ecall':
                self.enter_trap(pc, CAUSE_ECALL_M)
                return None                            # not retired
            if m == 'mret':
                next_pc = u32(self.mepc) & 0xFFFFFFFC
                self.mstatus_mie = self.mstatus_mpie
                self.mstatus_mpie = 1
            else:                                      # ebreak
                self.halted = True
                self.exit_code = 0

        else:                                          # pragma: no cover
            raise IllegalInstruction(pc, insn)

        if rd_we:
            self.wr_reg(d.rd, rd_val)
        self.pc = next_pc
        self.retired += 1

        line = "%08x %08x" % (pc, insn)
        if rd_we and d.rd != 0:
            line += " x%d=%08x" % (d.rd, u32(rd_val))
        if mem_we:
            line += " mem[%08x]=%08x" % (u32(mem_addr), u32(mem_val))
        return line

    def run(self, trace_fp=None, collect=False):
        """Run until halt / limit / illegal instruction. Returns the exit code."""
        while not self.halted:
            if self.steps >= self.max_insns:
                self.exit_code = 2
                return 2
            try:
                line = self.step()
            except IllegalInstruction as e:
                sys.stderr.write("iss: %s\n" % e)
                self.exit_code = 3
                return 3
            if line is not None:
                if trace_fp is not None:
                    trace_fp.write(line + "\n")
                if collect:
                    self.trace_lines.append(line)
        return self.exit_code


# --------------------------------------------------------------------------
# hex image loading
# --------------------------------------------------------------------------

def load_hex(path):
    words = []
    with open(path, 'r') as fp:
        for lineno, raw in enumerate(fp, 1):
            t = raw.strip()
            if not t or t.startswith('//') or t.startswith('#'):
                continue
            if t.startswith('@'):
                raise ValueError("%s:%d: address records are not allowed"
                                 % (path, lineno))
            words.append(int(t, 16) & 0xFFFFFFFF)
    if len(words) > MEM_WORDS:
        raise ValueError("%s: %d words, memory holds %d"
                         % (path, len(words), MEM_WORDS))
    return words


def default_data_path(hex_path):
    base = hex_path[:-4] if hex_path.lower().endswith('.hex') else hex_path
    return base + '.data.hex'


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _auto_int(text):
    return int(text, 0)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="RV32I golden-reference ISS (Pipeline-CPU project)")
    ap.add_argument('program', help=".hex instruction image")
    ap.add_argument('--data', help=".data.hex image for DMEM")
    ap.add_argument('--trace', help="write the commit trace to this file")
    ap.add_argument('--max-insns', type=_auto_int, default=1000000)
    ap.add_argument('--irq-after', type=_auto_int, action='append', default=[],
                    metavar='N',
                    help="pulse irq at the boundary before retirement N "
                         "(repeatable)")
    ap.add_argument('--dump-regs', action='store_true')
    ap.add_argument('--dump-mem', nargs=2, type=_auto_int,
                    metavar=('LO', 'HI'))
    args = ap.parse_args(argv)

    imem = load_hex(args.program)
    data_path = args.data
    if data_path is None:
        guess = default_data_path(args.program)
        if os.path.exists(guess):
            data_path = guess
    dmem = load_hex(data_path) if data_path else []

    cpu = Cpu(imem, dmem, irq_after=args.irq_after, max_insns=args.max_insns)

    trace_fp = None
    if args.trace:
        d = os.path.dirname(os.path.abspath(args.trace))
        if d:
            os.makedirs(d, exist_ok=True)
        trace_fp = open(args.trace, 'w', newline='\n')
    try:
        code = cpu.run(trace_fp=trace_fp)
    finally:
        if trace_fp is not None:
            trace_fp.close()

    if code == 2:
        sys.stderr.write("iss: instruction limit %d exceeded at pc 0x%08x\n"
                         % (args.max_insns, cpu.pc))

    if args.dump_regs:
        for n in range(32):
            sys.stdout.write("x%d=%08x\n" % (n, u32(cpu.regs[n])))
    if args.dump_mem:
        lo, hi = args.dump_mem
        for addr in range(lo & ~3, hi + 1, 4):
            sys.stdout.write("mem[%08x]=%08x\n"
                             % (u32(addr), cpu.dmem[(addr >> 2) & WORD_INDEX_MASK]))
    return code


if __name__ == '__main__':
    sys.exit(main())
