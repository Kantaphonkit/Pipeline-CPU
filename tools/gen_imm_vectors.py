#!/usr/bin/env python3
"""gen_imm_vectors.py -- build the stimulus/expected file for tb_imm_gen.

Writes
    tb/vectors/imm_gen_vectors.hex   $readmemh image consumed by tb/tb_imm_gen.v
    tb/vectors/imm_gen_vectors.txt   human-readable companion (debugging only)

Hex file layout (one 8-hex-digit word per line, lowercase):

    line 0        : vector count N
    lines 1..3N   : N triples  <inst> <imm_sel> <expected imm>

Golden values policy
--------------------
The expected immediates are NEVER produced by re-implementing the RV32I bit
shuffle in Python -- that would only duplicate rtl/imm_gen.v and hide a shared
misreading of the spec.  Instead every expected value comes out of the already
cross-validated tools:

  * stimulus words are produced by the assembler (`asm.encode`) from ordinary
    source operands, with random rd/rs1/rs2 so the non-immediate bits are noise;
  * expected values are read back out of the ISS decoder (`iss.decode`), using
    the `Decoded.imm` / `Decoded.zimm` fields;
  * the two documented places where `Decoded` does not store the raw field --
    U (stores the unshifted 20-bit field) and the shift-immediates (store the
    5-bit shamt) -- are handled without hand-shuffling bits either:
      - U: `imm << 12`, the exact expression the ISS *executes* for lui/auipc,
        additionally anchored below by running lui through the ISS;
      - I-shift: the instruction word's inst[31:20] is re-decoded as a
        synthetic `addi`, so the ISS's own I-field sign extension produces the
        value.
  * ANCHORS(): before emitting anything, each format's expected-value helper is
    cross-checked against ISS *execution* (register results / next PC), which
    is an independent path through iss.py.

Deterministic: fixed RNG seed, so re-running reproduces the files byte for byte.
"""

import os
import random
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from asm import encode                                    # noqa: E402
from iss import Cpu, decode, u32                          # noqa: E402

SEED = 20260906
RANDOM_PER_FORMAT = 240        # >= 200 required by the task
MEM_WORDS = 16384              # must match tb/tb_imm_gen.v VEC_MEM_WORDS

SEL_I, SEL_S, SEL_B, SEL_U, SEL_J, SEL_Z = 0, 1, 2, 3, 4, 5

EBREAK = 0x00100073


# ---------------------------------------------------------------------------
# expected-value helpers -- all delegate to iss.decode
# ---------------------------------------------------------------------------

def exp_i(word):
    """I immediate = ISS decode of a synthetic `addi` carrying inst[31:20]."""
    synth = (word & 0xFFF00000) | 0x00000013          # rd=x0, rs1=x0, funct3=0
    return u32(decode(synth).imm)


def exp_s(word):
    return u32(decode(word).imm)


def exp_b(word):
    return u32(decode(word).imm)


def exp_u(word):
    # Decoded.imm for lui/auipc is the raw 20-bit field; the ISS executes
    # `u32(d.imm << 12)`.  Anchored against ISS execution in anchors().
    return u32(decode(word).imm << 12)


def exp_j(word):
    return u32(decode(word).imm)


def exp_z(word):
    return u32(decode(word).zimm)


# ---------------------------------------------------------------------------
# independent anchors: expected helpers vs. ISS execution
# ---------------------------------------------------------------------------

def _run_one(word, pc=0):
    """Fetch/execute exactly one instruction at `pc`; return the Cpu."""
    imem = [EBREAK] * 1024
    imem[pc >> 2] = word
    cpu = Cpu(imem=imem)
    cpu.pc = pc
    cpu.step()
    return cpu


def anchors():
    """Cross-check every exp_* helper against ISS *execution*, not decoding."""
    rng = random.Random(SEED ^ 0x5A5A)

    # I: addi x5, x0, imm  ->  x5 == sign-extended immediate
    for imm in [-2048, -1, 0, 1, 2047] + [rng.randint(-2048, 2047)
                                          for _ in range(60)]:
        w = encode('addi', 'x5', 'x0', str(imm))
        cpu = _run_one(w)
        assert cpu.regs[5] == exp_i(w) == u32(imm), (hex(w), imm)

    # I-shift: srai x5, x0, sh -> the raw field, checked against a synthetic
    # addi carrying the same inst[31:20] executed by the ISS.
    for sh in range(32):
        w = encode('srai', 'x5', 'x6', str(sh))
        synth = (w & 0xFFF00000) | 0x00000013 | (5 << 7)      # addi x5,x0,field
        cpu = _run_one(synth)
        assert cpu.regs[5] == exp_i(w), (hex(w), sh)

    # S: sw x0, imm(x0) -> store to effective address == imm (mod memory)
    for imm in [-2048, -1, 0, 1, 2047] + [rng.randint(-2048, 2047)
                                          for _ in range(60)]:
        w = encode('sw', 'x0', '%d(x0)' % imm)
        assert exp_s(w) == u32(imm), (hex(w), imm)
        cpu = Cpu(imem=[w, EBREAK])
        cpu.regs[7] = 0
        line = cpu.step()
        # trace line ends with mem[<addr>]=..., addr = 0 + imm (wrapped)
        assert line.split('mem[')[1].split(']')[0] == '%08x' % u32(imm), line

    # B: beq x0, x0, off (always taken) -> next PC == off
    for off in [-4096, -2, 0, 2, 2048, 4094] + [
            2 * rng.randint(-2048, 2047) for _ in range(60)]:
        w = encode('beq', 'x0', 'x0', str(off))
        cpu = _run_one(w)
        assert cpu.pc == exp_b(w) == u32(off), (hex(w), off)

    # U: lui x5, field -> x5 == field << 12  (anchors the <<12 in exp_u)
    for field in [0, 1, 0x7FFFF, 0xFFFFF, -0x80000] + [
            rng.randint(-0x80000, 0xFFFFF) for _ in range(60)]:
        w = encode('lui', 'x5', str(field))
        cpu = _run_one(w)
        assert cpu.regs[5] == exp_u(w), (hex(w), field)

    # J: jal x5, off -> next PC == off, x5 == pc+4
    for off in [-1048576, -2, 0, 2, 2048, 1048574] + [
            2 * rng.randint(-524288, 524287) for _ in range(60)]:
        w = encode('jal', 'x5', str(off))
        cpu = _run_one(w)
        assert cpu.pc == exp_j(w) == u32(off), (hex(w), off)
        assert cpu.regs[5] == 4

    # Z: csrrsi x5, mscratch-ish, zimm with mcause -> rd = old csr value, and
    # csrrwi into mcause makes mcause == zimm, which is the zero-extended zimm.
    for z in range(32):
        w = encode('csrrwi', 'x5', '0x342', str(z))     # mcause is writable
        cpu = _run_one(w)
        assert cpu.mcause == exp_z(w) == z, (hex(w), z)


# ---------------------------------------------------------------------------
# immediate value sets
# ---------------------------------------------------------------------------

def _pow_family(bits, lo, hi, step=1):
    """Powers of two, negations, +/-step around each, clipped to [lo,hi]."""
    out = set()
    for k in range(bits + 1):
        p = 1 << k
        for v in (p, -p, p - step, p + step, -p - step, -p + step):
            if lo <= v <= hi and (v % step == 0 if step > 1 else True):
                out.add(v)
    for v in (0, lo, hi, -step, step):
        if lo <= v <= hi:
            out.add(v)
    return out


def i_values(rng):
    vals = _pow_family(11, -2048, 2047)
    vals |= {-2048, 2047, -1, 0, 1, -2047, 2046, 0x7FF, -0x800}
    vals |= {rng.randint(-2048, 2047) for _ in range(RANDOM_PER_FORMAT)}
    return sorted(vals)


def b_values(rng):
    vals = _pow_family(12, -4096, 4094, step=2)
    # classic trap: imm[11]=1 with imm[12]=0  ->  positive offsets 2048..4094
    vals |= {2048, 2050, 2052, 3000, 4094, 4092, 2046, 2044}
    # and imm[11]=0 with imm[12]=1 -> negative offsets -4096..-2050
    vals |= {-4096, -4094, -3000, -2052, -2050}
    vals |= {2 * rng.randint(-2048, 2047) for _ in range(RANDOM_PER_FORMAT)}
    return sorted(v for v in vals if -4096 <= v <= 4094 and v % 2 == 0)


def u_values(rng):
    vals = _pow_family(19, -0x80000, 0xFFFFF)
    vals |= {0, 1, 0x7FFFF, 0x80000, 0xFFFFF, -0x80000, -1, 0xFFFFE}
    vals |= {rng.randint(-0x80000, 0xFFFFF) for _ in range(RANDOM_PER_FORMAT)}
    return sorted(vals)


def j_values(rng):
    vals = _pow_family(20, -1048576, 1048574, step=2)
    # imm[11] (inst[20]) set, everything above it clear
    vals |= {0x800, 0x802, 0xFFE, -0x800, -0x802}
    # imm[19:12] nonzero with imm[10:1] zero  (target multiple of 4096)
    vals |= {0x1000, 0x2000, 0x1800, 0x3000, 0xFF000, 0x1F000, -0x1000,
             -0x2000, -0xFF000}
    vals |= {2 * rng.randint(-524288, 524287)
             for _ in range(RANDOM_PER_FORMAT)}
    return sorted(v for v in vals
                  if -1048576 <= v <= 1048574 and v % 2 == 0)


# ---------------------------------------------------------------------------
# vector construction
# ---------------------------------------------------------------------------

I_ARITH_FORMS = ['addi', 'slti', 'sltiu', 'xori', 'ori', 'andi']
LOAD_FORMS = ['lw', 'lh', 'lb', 'lhu', 'lbu']
STORE_FORMS = ['sw', 'sh', 'sb']
BRANCH_FORMS = ['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu']
U_FORMS = ['lui', 'auipc']
CSRI_FORMS = ['csrrwi', 'csrrsi', 'csrrci']

CSR_ADDRS = [0x300, 0x304, 0x305, 0x341, 0x342, 0x000, 0x7FF, 0xC00, 0x123]


def build(rng):
    """Return a list of (inst, sel, expected, description) tuples."""
    vecs = []

    def reg(exclude_zero=False):
        return 'x%d' % rng.randint(1 if exclude_zero else 0, 31)

    def add(word, sel, expected, desc):
        vecs.append((u32(word), sel, u32(expected), desc))

    # ---- I format (sel 0): arith, loads, jalr ----------------------------
    for n, imm in enumerate(i_values(rng)):
        kind = n % 3
        if kind == 0:
            m = I_ARITH_FORMS[n % len(I_ARITH_FORMS)]
            rd, rs1 = reg(), reg()
            w = encode(m, rd, rs1, str(imm))
            desc = '%s %s, %s, %d' % (m, rd, rs1, imm)
        elif kind == 1:
            m = LOAD_FORMS[n % len(LOAD_FORMS)]
            rd, rs1 = reg(), reg()
            w = encode(m, rd, '%d(%s)' % (imm, rs1))
            desc = '%s %s, %d(%s)' % (m, rd, imm, rs1)
        else:
            rd, rs1 = reg(), reg()
            w = encode('jalr', rd, rs1, str(imm))
            desc = 'jalr %s, %s, %d' % (rd, rs1, imm)
        add(w, SEL_I, exp_i(w), desc)

    # ---- I format, shift immediates (raw field, funct7 included) ---------
    for m in ('slli', 'srli', 'srai'):
        for sh in range(32):
            rd, rs1 = reg(), reg()
            w = encode(m, rd, rs1, str(sh))
            add(w, SEL_I, exp_i(w), '%s %s, %s, %d' % (m, rd, rs1, sh))

    # ---- S format (sel 1) -------------------------------------------------
    for n, imm in enumerate(i_values(rng)):
        m = STORE_FORMS[n % len(STORE_FORMS)]
        rs2, rs1 = reg(), reg()
        w = encode(m, rs2, '%d(%s)' % (imm, rs1))
        add(w, SEL_S, exp_s(w), '%s %s, %d(%s)' % (m, rs2, imm, rs1))

    # ---- B format (sel 2) -------------------------------------------------
    for n, off in enumerate(b_values(rng)):
        m = BRANCH_FORMS[n % len(BRANCH_FORMS)]
        rs1, rs2 = reg(), reg()
        w = encode(m, rs1, rs2, str(off))
        add(w, SEL_B, exp_b(w), '%s %s, %s, %d' % (m, rs1, rs2, off))

    # ---- U format (sel 3) -------------------------------------------------
    for n, field in enumerate(u_values(rng)):
        m = U_FORMS[n % len(U_FORMS)]
        rd = reg()
        w = encode(m, rd, str(field))
        add(w, SEL_U, exp_u(w), '%s %s, %d' % (m, rd, field))

    # ---- J format (sel 4) -------------------------------------------------
    for off in j_values(rng):
        rd = reg()
        w = encode('jal', rd, str(off))
        add(w, SEL_J, exp_j(w), 'jal %s, %d' % (rd, off))

    # ---- Z format (sel 5): all 32 zimm values, noisy rd / csr -----------
    for z in range(32):
        for rep in range(3):
            m = CSRI_FORMS[(z + rep) % len(CSRI_FORMS)]
            rd = reg()
            csr = CSR_ADDRS[(z * 3 + rep) % len(CSR_ADDRS)]
            w = encode(m, rd, '0x%x' % csr, str(z))
            add(w, SEL_Z, exp_z(w),
                '%s %s, 0x%03x, %d' % (m, rd, csr, z))

    # ---- reserved selectors 6 and 7 -> always zero ------------------------
    for sel in (6, 7):
        for _ in range(25):
            w = rng.getrandbits(32)
            add(w, sel, 0, 'reserved sel=%d, random word' % sel)
        for w in (0x00000000, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xDEADBEEF):
            add(w, sel, 0, 'reserved sel=%d, corner word' % sel)

    return vecs


def main():
    rng = random.Random(SEED)
    anchors()
    vecs = build(rng)

    n = len(vecs)
    if 1 + 3 * n > MEM_WORDS:
        raise SystemExit("error: %d vectors need %d words, memory holds %d"
                         % (n, 1 + 3 * n, MEM_WORDS))

    repo = os.path.dirname(_HERE)
    outdir = os.path.join(repo, 'tb', 'vectors')
    os.makedirs(outdir, exist_ok=True)
    hex_path = os.path.join(outdir, 'imm_gen_vectors.hex')
    txt_path = os.path.join(outdir, 'imm_gen_vectors.txt')

    with open(hex_path, 'w', newline='\n') as fp:
        fp.write('%08x\n' % n)
        for inst, sel, expected, _ in vecs:
            fp.write('%08x\n%08x\n%08x\n' % (inst, sel, expected))

    with open(txt_path, 'w', newline='\n') as fp:
        fp.write('# tb_imm_gen vectors -- generated by tools/gen_imm_vectors.py'
                 ' (seed %d)\n' % SEED)
        fp.write('# idx  inst      sel  expected  source\n')
        for i, (inst, sel, expected, desc) in enumerate(vecs):
            fp.write('%5d  %08x  %d    %08x  %s\n'
                     % (i, inst, sel, expected, desc))

    by_sel = {}
    for _, sel, _, _ in vecs:
        by_sel[sel] = by_sel.get(sel, 0) + 1
    print("vectors: %d" % n)
    for sel in sorted(by_sel):
        print("  sel=%d (%s): %d" % (
            sel, {0: 'I', 1: 'S', 2: 'B', 3: 'U', 4: 'J', 5: 'Z'}.get(
                sel, 'reserved'), by_sel[sel]))
    # print repo-relative paths: the absolute path contains non-ANSI
    # characters that a cp1252 console cannot encode.
    print("wrote %s" % os.path.relpath(hex_path, repo).replace(os.sep, '/'))
    print("wrote %s" % os.path.relpath(txt_path, repo).replace(os.sep, '/'))


if __name__ == '__main__':
    main()
