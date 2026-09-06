# irq_demo.s -- installs an ISR, enables mie.MEIE + mstatus.MIE, then runs
# a ~200-iteration main loop incrementing x10. The ISR saves/restores
# x5/x6 on the stack, increments x11, and mrets. External-interrupt
# semantics (INTERFACES.md sec 3): mepc <- PC of the NOT-yet-executed
# instruction, and the ISR must NOT advance mepc (unlike ecall). Result
# must not depend on exactly when the irq(s) land -- run under the ISS
# with --irq-after 50 --irq-after 120 (see tools/gen_fixtures.py).

        .text
_start:
        li      sp, 0x1000
        li      x5, 0              # scratch saved/restored by the ISR
        li      x6, 0              # scratch saved/restored by the ISR
        li      x11, 0             # ISR-visit counter (init before any use)

        la      x7, ISR
        csrw    mtvec, x7
        li      x8, 0x800          # mie.MEIE (bit 11)
        csrw    mie, x8
        li      x9, 0x08           # mstatus.MIE (bit 3)
        csrw    mstatus, x9

        li      x10, 0             # main loop counter
        li      x12, 200           # iterations
MAIN_LOOP:
        bge     x10, x12, MAIN_DONE
        addi    x10, x10, 1
        j       MAIN_LOOP
MAIN_DONE:
        ebreak

ISR:
        addi    sp, sp, -8
        sw      x5, 0(sp)
        sw      x6, 4(sp)
        addi    x11, x11, 1
        lw      x5, 0(sp)
        lw      x6, 4(sp)
        addi    sp, sp, 8
        mret
