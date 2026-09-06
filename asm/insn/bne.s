# bne.s -- B-type bne: branch if rs1 != rs2.

li      x5, 5
li      x6, 6
li      x7, 5
nop
nop
nop
bne     x5, x6, FWD_TAKEN     # taken: 5 != 6 (forward)
nop
nop
nop
addi    x10, x0, 0xAA         # fall-through poison
FWD_TAKEN:
addi    x10, x0, 1

nop
nop
nop
bne     x5, x7, NOT_TAKEN_TGT # not taken: 5 == 5
nop
nop
nop
addi    x11, x0, 1
j       AFTER_NT
NOT_TAKEN_TGT:
addi    x11, x0, 0xBB
AFTER_NT:

# backward taken bne -- the classic decrement-to-zero loop
li      x20, 3                # trip count
li      x22, 0                # iteration marker
BWD:
addi    x22, x22, 1
addi    x20, x20, -1
nop
nop
nop
bne     x20, x0, BWD          # backward taken while x20 != 0 (3 passes)
nop
nop
nop
addi    x23, x0, 1            # x22 should read 3

ebreak
