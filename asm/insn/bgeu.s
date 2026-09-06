# bgeu.s -- B-type bgeu: branch if (unsigned) rs1 >= rs2.
# Unsigned corner: 0x80000000 >= 1 is true unsigned (huge >= small), even
# though bge.s's signed version of the mirrored comparison differs.

li      x5, 5
li      x6, 5
li      x7, 1
nop
nop
nop
bgeu    x5, x6, FWD_TAKEN     # taken: 5 >= 5 (forward)
nop
nop
nop
addi    x10, x0, 0xAA
FWD_TAKEN:
addi    x10, x0, 1

nop
nop
nop
bgeu    x7, x5, NOT_TAKEN_TGT # not taken: 1 >= 5 is false
nop
nop
nop
addi    x11, x0, 1
j       AFTER_NT
NOT_TAKEN_TGT:
addi    x11, x0, 0xBB
AFTER_NT:

li      x8, 0x80000000        # huge unsigned
li      x9, 1
nop
nop
nop
bgeu    x8, x9, UNS_TAKEN     # unsigned: 0x80000000 >= 1 -> true, taken
nop
nop
nop
addi    x12, x0, 0xAA
UNS_TAKEN:
addi    x12, x0, 1

# backward taken bgeu -- "for (i = 3; i >= 1; i--)" with unsigned compare
li      x20, 3
li      x21, 1
BWD:
addi    x20, x20, -1
nop
nop
nop
bgeu    x20, x21, BWD          # taken while i >= 1 unsigned (2 passes)
nop
nop
nop
addi    x23, x0, 1             # x20 should read 0

ebreak
