# bloop.s -- branch-heavy 3-nested-loop program, ~3000-3800 dynamic
# instructions. The outer/middle loop-exit branches (bge) are highly
# predictable (taken only on the final pass of each run -- a 2-bit
# saturating counter learns them quickly). The inner if/else (beq on
# k's parity) ALTERNATES every single iteration -- the pattern a simple
# 2-bit predictor cannot learn.

        .text
_start:
        li      sp, 0x1000
        li      x30, 0             # counts "odd k" passes
        li      x31, 0             # counts "even k" passes

        li      x5, 0              # i
        li      x6, 5              # outer limit
OUTER:
        bge     x5, x6, OUTER_DONE
        li      x7, 0              # j
        li      x8, 8              # middle limit
MID:
        bge     x7, x8, MID_DONE
        li      x9, 0              # k
        li      x10, 10            # inner limit
INNER:
        bge     x9, x10, INNER_DONE
        andi    x11, x9, 1         # k's parity -- alternates 0,1,0,1,...
        beq     x11, x0, EVEN_CASE # unpredictable: flips every iteration
        addi    x30, x30, 1        # odd-k path
        j       AFTER_IF
EVEN_CASE:
        addi    x31, x31, 1        # even-k path
AFTER_IF:
        addi    x9, x9, 1
        j       INNER
INNER_DONE:
        addi    x7, x7, 1
        j       MID
MID_DONE:
        addi    x5, x5, 1
        j       OUTER
OUTER_DONE:
        ebreak
