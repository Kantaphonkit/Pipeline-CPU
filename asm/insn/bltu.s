# bltu.s -- B-type bltu: branch if (unsigned) rs1 < rs2.
# Unsigned corner: 0x80000000 is a HUGE unsigned number, so
# bltu(0x80000000, 1) is false even though signed it would be true (blt.s
# tests that contrast).

li      x5, 1
li      x6, 5
li      x7, 5
nop
nop
nop
bltu    x5, x6, FWD_TAKEN     # taken: 1 < 5 (forward)
nop
nop
nop
addi    x10, x0, 0xAA
FWD_TAKEN:
addi    x10, x0, 1

nop
nop
nop
bltu    x6, x7, NOT_TAKEN_TGT # not taken: 5 < 5 is false
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
bltu    x8, x9, UNS_TAKEN     # unsigned: 0x80000000 < 1 -> false, not taken
nop
nop
nop
addi    x12, x0, 1            # executes (not taken)
j       AFTER_UNS
UNS_TAKEN:
addi    x12, x0, 0xBB         # must NOT run
AFTER_UNS:
nop
nop
nop
bltu    x9, x8, UNS_TAKEN2    # unsigned: 1 < 0x80000000 -> true, taken
nop
nop
nop
addi    x13, x0, 0xAA
UNS_TAKEN2:
addi    x13, x0, 1

# backward taken bltu -- "for (i = 0; i < 3; i++)" with unsigned compare
li      x20, 0
li      x21, 3
BWD:
addi    x20, x20, 1
nop
nop
nop
bltu    x20, x21, BWD          # backward taken while i < 3 (unsigned)
nop
nop
nop
addi    x23, x0, 1             # x20 should read 3

ebreak
