#!/usr/bin/env python3
"""Build the 8-slide final-deck PPTX (dark theme, matching rv32i-final-deck.html)."""
import os
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG = os.path.join(REPO, "Report", "Test screenshot", "Waveform.png")
OUT = os.path.join(REPO, "Report", "rv32i-final-deck.pptx")

# ---- theme (dark) ----
BG      = RGBColor(0x19, 0x15, 0x10)
SURFACE = RGBColor(0x24, 0x20, 0x1A)
INK     = RGBColor(0xED, 0xE4, 0xD2)
INK2    = RGBColor(0xAF, 0xA4, 0x8D)
INK3    = RGBColor(0x7D, 0x74, 0x62)
RULE    = RGBColor(0x3A, 0x34, 0x2B)
BLUE    = RGBColor(0x4F, 0x97, 0xD6)
OCHRE   = RGBColor(0xB8, 0x86, 0x2B)
FWD     = RGBColor(0xB8, 0x86, 0x2B)
STALL   = RGBColor(0x93, 0x85, 0xD2)
FLUSH   = RGBColor(0xD2, 0x69, 0x5C)
OK      = RGBColor(0x6F, 0xA9, 0x7D)
ST1     = RGBColor(0x25, 0x38, 0x4A)
ST2     = RGBColor(0x33, 0x50, 0x6B)
ST3     = RGBColor(0x44, 0x6A, 0x8B)
ST4     = RGBColor(0x5F, 0x8C, 0xB2)
ST5     = RGBColor(0x88, 0xB2, 0xD4)
DARK    = RGBColor(0x19, 0x15, 0x10)

DISPLAY = "Archivo"
MONO    = "IBM Plex Mono"
BODY    = "IBM Plex Sans"

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]

def slide():
    s = prs.slides.add_slide(BLANK)
    s.background.fill.solid()
    s.background.fill.fore_color.rgb = BG
    return s

def _set_font(run, font, size, color, bold, italic):
    f = run.font
    f.name = font
    f.size = Pt(size)
    f.color.rgb = color
    f.bold = bold
    f.italic = italic

def tb(s, l, t, w, h, segs, size=18, color=INK, font=BODY, bold=False, italic=False,
       align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, wrap=True, spacing=1.0):
    """segs: str, or list of (text, dict-overrides)."""
    box = s.shapes.add_textbox(Inches(l), Inches(t), Inches(w), Inches(h))
    tf = box.text_frame
    tf.word_wrap = wrap
    tf.vertical_anchor = anchor
    tf.margin_left = 0; tf.margin_right = 0; tf.margin_top = 0; tf.margin_bottom = 0
    p = tf.paragraphs[0]
    p.alignment = align
    p.line_spacing = spacing
    if isinstance(segs, str):
        segs = [(segs, {})]
    for text, ov in segs:
        r = p.add_run(); r.text = text
        _set_font(r, ov.get("font", font), ov.get("size", size), ov.get("color", color),
                  ov.get("bold", bold), ov.get("italic", italic))
    return box

def rect(s, l, t, w, h, fill=None, line=None, line_w=0.75):
    shp = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(l), Inches(t), Inches(w), Inches(h))
    if fill is None:
        shp.fill.background()
    else:
        shp.fill.solid(); shp.fill.fore_color.rgb = fill
    if line is None:
        shp.line.fill.background()
    else:
        shp.line.color.rgb = line; shp.line.width = Pt(line_w)
    shp.shadow.inherit = False
    return shp

def eyebrow(s, text, t=0.55):
    tb(s, 0.6, t, 12.1, 0.4, text, size=14, color=BLUE, font=MONO, bold=True)

def title(s, text, t=0.95, size=34):
    tb(s, 0.6, t, 12.1, 1.0, text, size=size, color=INK, font=DISPLAY, bold=True)

def keyline(s, text, t=6.85):
    rect(s, 0.6, t, 0.06, 0.55, fill=BLUE)
    tb(s, 0.8, t, 11.9, 0.55, text, size=16, color=INK, font=BODY)

def stage_strip(s, l, t, w, h):
    labels = ["IF", "ID", "EX", "MEM", "WB"]
    colors = [ST1, ST2, ST3, ST4, ST5]
    inks   = [INK, INK, INK, DARK, DARK]
    cw = (w - 0.08*4) / 5
    for i in range(5):
        x = l + i*(cw + 0.08)
        rect(s, x, t, cw, h, fill=colors[i])
        tb(s, x, t + h/2 - 0.2, cw, 0.4, labels[i], size=18, color=inks[i], font=MONO, bold=True, align=PP_ALIGN.CENTER)

def spec_row(s, l, t, w, label, value, label_color=INK2, value_size=14, lw=1.4):
    tb(s, l, t, lw, 0.3, label.upper(), size=11, color=label_color, font=MONO, bold=True)
    tb(s, l + lw + 0.15, t, w - lw - 0.15, 0.5, value, size=value_size, color=INK, font=BODY)

def panel(s, l, t, w, h, accent=None):
    rect(s, l, t, w, h, fill=SURFACE, line=RULE, line_w=1)
    if accent is not None:
        rect(s, l, t, w, 0.05, fill=accent)

def tile(s, l, t, w, h, num, num_color, label, sub):
    panel(s, l, t, w, h)
    tb(s, l + 0.25, t + 0.2, w - 0.5, 0.9, num, size=40, color=num_color, font=DISPLAY, bold=True)
    tb(s, l + 0.25, t + 1.15, w - 0.5, 0.4, label, size=15, color=INK2, font=BODY)
    tb(s, l + 0.25, t + 1.55, w - 0.5, 0.35, sub, size=11, color=INK3, font=MONO)

# ================= 1 · TITLE =================
s = slide()
eyebrow(s, "PIPELINE CPU PROJECT · FINAL DEMO", t=1.1)
tb(s, 0.6, 1.55, 12.1, 2.0, "A 5-stage RISC-V RV32I processor in Verilog",
   size=54, color=INK, font=DISPLAY, bold=True)
tb(s, 0.6, 3.35, 11.0, 1.0,
   "46 encodings, full forwarding, a load-use interlock, branch prediction, and machine-mode "
   "interrupts. Verified byte-for-byte against a golden reference model we wrote ourselves, "
   "and synthesized for an Artix-7 at 74 MHz.",
   size=18, color=INK2, font=BODY, spacing=1.3)
stage_strip(s, 0.6, 4.55, 8.0, 0.85)
# legend
leg = [("bypass network", FWD), ("interlock / stall", STALL), ("flush / killed", FLUSH), ("free", OK)]
lx = 0.6
for label, c in leg:
    rect(s, lx, 5.7, 0.22, 0.22, fill=c)
    tb(s, lx + 0.32, 5.62, 2.2, 0.3, label, size=12, color=INK2, font=MONO)
    lx += 2.9
# team
team = [("Design", "杨辉宗 1820232064 · microarchitecture, hazard scheme, design document"),
        ("Coding", "吴宏庆 1820232044 · 19 RTL modules, assembler, reference model"),
        ("Testing", "王伟成 1820232061 · testbenches, trace diffing, performance measurement")]
ty = 6.15
for role, desc in team:
    tb(s, 0.6, ty, 1.5, 0.3, role.upper(), size=12, color=INK3, font=MONO, bold=True)
    tb(s, 2.2, ty, 10.0, 0.3, desc, size=14, color=INK, font=BODY)
    ty += 0.34

# ================= 2 · THE MACHINE =================
s = slide()
eyebrow(s, "THE MACHINE")
title(s, "One 5-stage pipeline, 46 encodings, two bonuses")
stage_strip(s, 0.6, 1.7, 7.2, 0.7)
panel(s, 0.6, 2.65, 7.2, 4.1)
tb(s, 0.85, 2.85, 6.7, 0.3, "STAGE RESPONSIBILITIES", size=12, color=INK3, font=MONO, bold=True)
rows = [("IF", "Fetch from IMEM; BHT lookup indexed by the fetch PC"),
        ("ID", "Decode, immediate generation, register read; jal resolved here (1 bubble)"),
        ("EX", "ALU, branch compare + target, forwarding muxes; branches + jalr resolve here (2 bubbles)"),
        ("MEM", "Data memory load/store; the BRAM word is registered on the MEM edge"),
        ("WB", "Byte-lane select + extension, then register write-back")]
ry = 3.3
for lab, val in rows:
    spec_row(s, 0.85, ry, 6.7, lab, val, value_size=13, lw=0.75)
    ry += 0.62
# right column
tile(s, 8.0, 1.7, 2.35, 2.3, "46", BLUE, "encodings", "37 core + 9 system")
tile(s, 10.45, 1.7, 2.35, 2.3, "2", OCHRE, "bonus features", "BHT + interrupts")
panel(s, 8.0, 4.2, 4.8, 2.55)
tb(s, 8.25, 4.4, 4.3, 0.3, "INSTRUCTION SET", size=12, color=INK3, font=MONO, bold=True)
isa = [("R-type", "add sub sll slt sltu xor srl sra or and"),
       ("I-arith", "addi slti sltiu xori ori andi slli srli srai"),
       ("Loads/stores", "lb lh lw lbu lhu · sb sh sw"),
       ("Branches", "beq bne blt bge bltu bgeu"),
       ("U + jumps", "lui auipc jal jalr"),
       ("System", "ecall ebreak csr* mret")]
iy = 4.75
for lab, val in isa:
    spec_row(s, 8.25, iy, 4.3, lab, val, value_size=11, lw=1.0)
    iy += 0.32
keyline(s, "The shallowest design that still exposes all three hazard classes — which is the point of the exercise.")

# ================= 3 · HAZARDS =================
s = slide()
eyebrow(s, "HAZARDS")
title(s, "Three mechanisms, one rule each")
panels = [
    ("FORWARD", FWD, "EX/MEM and MEM/WB results route straight back to the ALU inputs — no stall for a data hazard.",
     "EX/MEM wins over MEM/WB · x0 never forwarded · store data forwarded too"),
    ("STALL", STALL, "A load feeding the very next instruction is the one case forwarding cannot save.",
     "load-use interlock · freeze PC + IF/ID · one bubble into ID/EX"),
    ("FLUSH", FLUSH, "A taken branch or trap squashes the younger instructions already in the pipe.",
     "jal = 1 bubble · branch / jalr / trap / mret = 2 bubbles · killed insns never retire"),
]
x = 0.6
for name, c, body, foot in panels:
    panel(s, x, 1.8, 3.85, 4.2, accent=c)
    tb(s, x + 0.3, 2.0, 3.25, 0.35, name, size=14, color=c, font=MONO, bold=True)
    tb(s, x + 0.3, 2.5, 3.25, 2.3, body, size=15, color=INK, font=BODY, spacing=1.25)
    tb(s, x + 0.3, 5.05, 3.25, 0.8, foot, size=11, color=INK3, font=MONO, spacing=1.2)
    x += 4.13
keyline(s, "Everything above CPI 1.0 is control-flow bubbles and load-use stalls. There is no other source of delay.")

# ================= 4 · LIVE DEMO =================
s = slide()
eyebrow(s, "DEMO")
title(s, "The machine in simulation")
if os.path.exists(IMG):
    s.shapes.add_picture(IMG, Inches(0.6), Inches(1.8), width=Inches(7.2))
tb(s, 0.6, 6.0, 7.2, 0.4, "pc_q · stall · flush_id · fwd_a — the three hazards, live",
   size=12, color=INK3, font=MONO)
panel(s, 8.0, 1.8, 4.75, 4.2)
tb(s, 8.25, 2.0, 4.3, 0.3, "WHAT TO POINT AT", size=12, color=INK3, font=MONO, bold=True)
demo = [("STALL", STALL, "stall high for exactly one cycle; PC and IF/ID hold their value"),
        ("FORWARD", FWD, "fwd_a switches to the MEM/WB path the cycle after the stall"),
        ("FLUSH", FLUSH, "both flush signals assert; the trace valid never fires for a killed insn")]
dy = 2.45
for lab, c, val in demo:
    tb(s, 8.25, dy, 1.2, 0.3, lab, size=12, color=c, font=MONO, bold=True)
    tb(s, 9.5, dy, 3.25, 0.6, val, size=12, color=INK, font=BODY, spacing=1.1)
    dy += 1.05
keyline(s, "Function is shown in simulation, not asserted — every test states its own PASS or FAIL verdict.")

# ================= 5 · VERIFICATION =================
s = slide()
eyebrow(s, "VERIFICATION")
title(s, "Green against an independent model, not our own expectations")
panel(s, 0.6, 1.8, 7.3, 4.4)
tb(s, 0.85, 2.0, 6.8, 0.3, "RESULTS — ALL FOUR FORWARDING × BHT CONFIGURATIONS", size=12, color=INK3, font=MONO, bold=True)
vrows = [("Per-instruction", "one program per encoding, golden state", "46 / 46", True),
         ("Hazard", "forwarding, load-use, flush, CSR", "9 / 9", False),
         ("Program-level", "fib, bsort, bloop, bpred, irq — trace diff vs ISS", "5 / 5", False),
         ("Unit testbenches", "imm_gen, ALU, regfile, control, BHT…", "11 / 11", False),
         ("Toolchain self-check", "assembler vs reference model", "4,323", False)]
vy = 2.45
for name, scope, res, hi in vrows:
    if hi:
        rect(s, 0.75, vy - 0.05, 7.0, 0.72, fill=RGBColor(0x24,0x33,0x3C))
    tb(s, 0.85, vy, 1.7, 0.3, name, size=13, color=INK, font=MONO, bold=hi)
    tb(s, 2.6, vy, 3.6, 0.5, scope, size=12, color=INK2, font=BODY)
    tb(s, 6.2, vy, 1.6, 0.3, res, size=13, color=BLUE if hi else INK, font=MONO, bold=True, align=PP_ALIGN.RIGHT)
    vy += 0.72
panel(s, 8.15, 1.8, 4.6, 2.1)
tb(s, 8.4, 2.0, 4.1, 0.3, "WHY A TRACE DIFF", size=12, color=INK3, font=MONO, bold=True)
tb(s, 8.4, 2.4, 4.1, 1.4, "A final-state check tells you the answer is wrong. A commit-trace diff tells you which instruction went wrong — the difference between an afternoon of debugging and a week.",
   size=13, color=INK2, font=BODY, spacing=1.2)
panel(s, 8.15, 4.1, 4.6, 2.1, accent=OCHRE)
tb(s, 8.4, 4.3, 4.1, 0.3, "TESTS ARE TRUSTED, NOT JUST PASSING", size=12, color=OCHRE, font=MONO, bold=True)
tb(s, 8.4, 4.7, 4.1, 1.4, "Every expected value is generated by the reference model, and we injected deliberate bugs to confirm each testbench fails when it should.",
   size=13, color=INK2, font=BODY, spacing=1.2)
keyline(s, "Correctness rests on EX-stage resolution + flush — the predictor only changes when instructions are fetched, never what they compute.")

# ================= 6 · PERFORMANCE =================
s = slide()
eyebrow(s, "PERFORMANCE")
title(s, "Every figure carries its own baseline")
panel(s, 0.6, 1.8, 7.3, 4.4)
tb(s, 0.85, 2.0, 6.8, 0.3, "FORWARDING ON VS OFF — SAME PROGRAMS", size=12, color=INK3, font=MONO, bold=True)
# header
hdr = ["Program", "CPI fwd on", "CPI fwd off", "Speedup"]
hx = [0.85, 3.4, 5.0, 6.6]
for i, htxt in enumerate(hdr):
    tb(s, hx[i], 2.4, 1.4, 0.3, htxt, size=11, color=INK3, font=MONO, bold=True, align=PP_ALIGN.RIGHT if i else PP_ALIGN.LEFT)
cpi = [("fib", "1.368", "2.263", "1.65×"),
       ("bsort", "1.376", "1.904", "1.38×"),
       ("bloop", "1.396", "1.707", "1.22×"),
       ("average", "1.387", "1.837", "1.32×")]
cy = 2.8
for i, (p, on, off, sp) in enumerate(cpi):
    if p == "average":
        rect(s, 0.75, cy - 0.05, 7.05, 0.7, fill=RGBColor(0x24,0x33,0x3C))
    vals = [p, on, off, sp]
    for j, v in enumerate(vals):
        tb(s, hx[j], cy, 1.6, 0.3, v, size=13, color=BLUE if p == "average" else INK, font=MONO, bold=(p == "average" or j == 0), align=PP_ALIGN.RIGHT if j else PP_ALIGN.LEFT)
    cy += 0.7
tb(s, 0.85, 5.7, 6.8, 0.4, "A feature is switched off and the same programs re-run — the 'show performance' requirement, not a number with no baseline.",
   size=12, color=INK3, font=BODY)
tile(s, 8.15, 1.8, 2.2, 2.3, "95.5%", BLUE, "BHT accuracy", "branch-heavy demo")
tile(s, 10.45, 1.8, 2.3, 2.3, "−14.5%", OK, "cycles saved", "same program")
panel(s, 8.15, 4.35, 4.6, 1.85)
tb(s, 8.4, 4.55, 4.1, 0.3, "THE HONEST PART", size=12, color=INK3, font=MONO, bold=True)
tb(s, 8.4, 4.95, 4.1, 1.2, "A 2-bit table helps loop-dominated code (fib 93.4%), and hurts on alternating branches (49.9%, +10%). We report the case where it loses.",
   size=13, color=INK2, font=BODY, spacing=1.2)
keyline(s, "The BHT is a cheap heuristic, not a guarantee — and saying so is more useful than hiding the case where it loses.")

# ================= 7 · BONUS FEATURES =================
s = slide()
eyebrow(s, "BONUS FEATURES")
title(s, "Two shipped, one deliberately cut")
panel(s, 0.6, 1.8, 7.3, 4.4, accent=BLUE)
tb(s, 0.85, 2.0, 6.8, 0.3, "INTERRUPTS — CSRS + MRET", size=12, color=BLUE, font=MONO, bold=True)
irows = [("CSRs", "mstatus (MIE/MPIE) · mie · mtvec · mepc · mcause"),
         ("Insns", "csrrw csrrs csrrc + immediate forms · mret"),
         ("Demo", "testbench-driven irq → timer-like ISR saves regs, toggles a counter, returns via mret"),
         ("Result", "21 assertions PASS · 633/633 trace lines match the ISS · irq held while MIE=0")]
iy = 2.45
for lab, val in irows:
    tb(s, 0.85, iy, 1.3, 0.3, lab.upper(), size=11, color=INK3, font=MONO, bold=True)
    tb(s, 2.25, iy, 5.5, 0.6, val, size=13, color=INK, font=BODY, spacing=1.1)
    iy += 0.88
panel(s, 8.15, 1.8, 4.6, 2.1, accent=STALL)
tb(s, 8.4, 2.0, 4.1, 0.3, "THE TRAP ASYMMETRY", size=12, color=STALL, font=MONO, bold=True)
tb(s, 8.4, 2.4, 4.1, 1.5, "ecall leaves mepc at the ecall itself — the handler adds 4 before mret. An interrupt leaves mepc at an instruction that never ran, so the handler must not. Get this wrong and the handler loops forever.",
   size=13, color=INK2, font=BODY, spacing=1.2)
panel(s, 8.15, 4.1, 4.6, 2.1, accent=OCHRE)
tb(s, 8.4, 4.3, 4.1, 0.3, "I-CACHE — DESIGNED, NOT BUILT", size=12, color=OCHRE, font=MONO, bold=True)
tb(s, 8.4, 4.7, 4.1, 1.5, "Direct-mapped 128 × 16 B (2 KB) — but the whole suite fits in 2 KB, so the hit rate would read ~99% on every program. A figure that reads 99% proves nothing.",
   size=13, color=INK2, font=BODY, spacing=1.2)
keyline(s, "Both bonuses are switchable off — a feature that cannot be disabled cannot be measured.")

# ================= 8 · SYNTHESIS + CLOSE =================
s = slide()
eyebrow(s, "SYNTHESIS")
title(s, "74 MHz on an Artix-7, with the path that limits it")
tiles = [("74 MHz", BLUE, "setup met", "13.5 ns · WNS +0.052"),
         ("1,461", INK, "LUTs", "post-route"),
         ("819", INK, "flip-flops", "post-route"),
         ("2", OCHRE, "BRAMs", "IMEM + DMEM")]
x = 0.6
for num, c, lab, sub in tiles:
    tile(s, x, 1.8, 2.9, 2.3, num, c, lab, sub)
    x += 3.08
panel(s, 0.6, 4.35, 12.13, 2.3)
tb(s, 0.85, 4.55, 11.6, 0.3, "CRITICAL PATH — THE LOAD-TO-BRANCH CHAIN", size=12, color=INK3, font=MONO, bold=True)
tb(s, 0.85, 4.95, 11.6, 1.5,
   "DMEM block-RAM clock-to-output (2.454 ns, the largest single term) → byte-lane select + sign extension in WB → "
   "the MEM/WB→EX forwarding mux → branch comparator → redirect into the PC clock-enable.",
   size=14, color=INK2, font=BODY, spacing=1.3)
keyline(s, "A 16-instruction minimum; we shipped 46, verified byte-for-byte, synthesized at 74 MHz — with both bonuses green. Thank you.")

prs.save(OUT)
print("wrote", OUT, "with", len(prs.slides._sldIdLst), "slides")
