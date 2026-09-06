# bge.s -- B-type bge: branch if (signed) rs1 >= rs2.
# Signed corner: 1 >= 0x80000000 (INT_MIN) is true signed (1 > INT_MIN).

li      x5, 5
li      x6, 5
li      x7, 1
nop
nop
nop
bge     x5, x6, FWD_TAKEN     # taken: 5 >= 5 (forward)
nop
nop
nop
addi    x10, x0, 0xAA
FWD_TAKEN:
addi    x10, x0, 1

nop
nop
nop
bge     x7, x5, NOT_TAKEN_TGT # not taken: 1 >= 5 is false
nop
nop
nop
addi    x11, x0, 1
j       AFTER_NT
NOT_TAKEN_TGT:
addi    x11, x0, 0xBB
AFTER_NT:

li      x8, 1
li      x9, 0x80000000        # INT_MIN
nop
nop
nop
bge     x8, x9, SIGNED_TAKEN  # signed: 1 >= INT_MIN -> taken
nop
nop
nop
addi    x12, x0, 0xAA
SIGNED_TAKEN:
addi    x12, x0, 1

# backward taken bge -- "for (i = 3; i >= 1; i--)" idiom: decrement then
# test; backward-taken while the post-decrement value is still >= 1.
li      x20, 3                 # i
li      x21, 1                 # threshold
BWD:
addi    x20, x20, -1
nop
nop
nop
bge     x20, x21, BWD          # taken while i >= 1 (2 backward passes: 3->2, 2->1)
nop
nop
nop
addi    x23, x0, 1             # x20 should read 0

ebreak
