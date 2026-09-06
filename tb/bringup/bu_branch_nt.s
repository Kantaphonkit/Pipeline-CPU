# bu_branch_nt.s -- step-4 bring-up: all 6 conditional branches, every one
# NOT taken, so the pipeline never redirects and never needs a flush.  That
# makes this the one branch program whose commit trace must match the ISS
# byte for byte even with the hazard unit stubbed out.

        .text
        addi    x5, x0, 5
        addi    x6, x0, 6
        addi    x7, x0, -1          # 0xffffffff: huge unsigned, negative signed
        nop
        nop
        nop

        beq     x5, x6, BAD         # 5 == 6 ? no
        nop
        nop
        bne     x5, x5, BAD         # 5 != 5 ? no
        nop
        nop
        blt     x6, x5, BAD         # 6 < 5 signed ? no
        nop
        nop
        bge     x5, x6, BAD         # 5 >= 6 signed ? no
        nop
        nop
        bltu    x6, x5, BAD         # 6 < 5 unsigned ? no
        nop
        nop
        bgeu    x5, x6, BAD         # 5 >= 6 unsigned ? no
        nop
        nop
        bltu    x7, x5, BAD         # 0xffffffff < 5 unsigned ? no
        nop
        nop
        bge     x7, x0, BAD         # -1 >= 0 signed ? no
        nop
        nop

        addi    x10, x0, 1          # reached iff no branch fired
        ebreak

BAD:
        addi    x11, x0, 0xBB       # poison: must never execute
        ebreak
