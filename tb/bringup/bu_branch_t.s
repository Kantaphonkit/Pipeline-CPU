# bu_branch_t.s -- step-4 bring-up: all 6 conditional branches TAKEN, plus jal
# and jalr.  Every control transfer is followed by 2 NOPs, which is exactly the
# shadow the step-4 machine cannot flush, so the architectural result is still
# correct; the instruction one slot beyond the shadow is a poison `addi` that a
# working redirect must skip.
#
# The commit trace necessarily differs from the ISS here (the RTL retires the
# shadow NOPs, the ISS never sees them), so this program is run with +NOTRACE
# until the flush logic lands in step 5.

        .text
        addi    x5, x0, 5
        addi    x6, x0, 6
        nop
        nop
        nop

        beq     x5, x5, L1
        nop
        nop
        addi    x20, x0, 0xBB       # poison
L1:     bne     x5, x6, L2
        nop
        nop
        addi    x21, x0, 0xBB       # poison
L2:     blt     x5, x6, L3
        nop
        nop
        addi    x22, x0, 0xBB       # poison
L3:     bge     x6, x5, L4
        nop
        nop
        addi    x23, x0, 0xBB       # poison
L4:     bltu    x5, x6, L5
        nop
        nop
        addi    x24, x0, 0xBB       # poison
L5:     bgeu    x6, x5, L6
        nop
        nop
        addi    x25, x0, 0xBB       # poison

        # ---- jal: resolves in ID (1 shadow slot), rd is NOT ra on purpose ----
L6:     jal     x10, J1
        nop
        nop
        addi    x26, x0, 0xBB       # poison
J1:     addi    x11, x0, 1          # reached via jal; x10 holds the link

        # ---- jalr: resolves in EX (2 shadow slots) ----
        lui     x12, %hi(JT)
        nop
        nop
        nop
        addi    x12, x12, %lo(JT)
        nop
        nop
        nop
        jalr    x13, x12, 0
        nop
        nop
        addi    x27, x0, 0xBB       # poison
JT:     addi    x14, x0, 1          # reached via jalr; x13 holds the link

        # ---- backward branch: a 3-iteration counted loop ----
        addi    x15, x0, 3          # trip count
        addi    x16, x0, 0          # accumulator
        nop
        nop
        nop
LOOP:   addi    x16, x16, 10
        addi    x15, x15, -1
        nop
        nop
        nop
        bne     x15, x0, LOOP       # taken twice, falls through on the third
        nop
        nop

        addi    x17, x0, 1          # x16 must be 30, x15 must be 0
        ebreak
