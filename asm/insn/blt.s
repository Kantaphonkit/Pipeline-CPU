# blt.s -- B-type blt: branch if (signed) rs1 < rs2.
# Signed corner: 0x80000000 (INT_MIN) is LESS than 1 when compared signed,
# even though as raw bits it is numerically larger than 1 unsigned.

li      x5, 1
li      x6, 5
li      x7, 5
nop
nop
nop
blt     x5, x6, FWD_TAKEN     # taken: 1 < 5 (forward)
nop
nop
nop
addi    x10, x0, 0xAA
FWD_TAKEN:
addi    x10, x0, 1

nop
nop
nop
blt     x6, x7, NOT_TAKEN_TGT # not taken: 5 < 5 is false
nop
nop
nop
addi    x11, x0, 1
j       AFTER_NT
NOT_TAKEN_TGT:
addi    x11, x0, 0xBB
AFTER_NT:

li      x8, 0x80000000        # INT_MIN
li      x9, 1
nop
nop
nop
blt     x8, x9, SIGNED_TAKEN  # signed: INT_MIN < 1 -> taken
nop
nop
nop
addi    x12, x0, 0xAA
SIGNED_TAKEN:
addi    x12, x0, 1

# backward taken blt -- classic "for (i = 0; i < 3; i++)" idiom
li      x20, 0                 # i
li      x21, 3                 # limit
BWD:
addi    x20, x20, 1
nop
nop
nop
blt     x20, x21, BWD          # backward taken while i < 3
nop
nop
nop
addi    x23, x0, 1             # x20 should read 3

ebreak
