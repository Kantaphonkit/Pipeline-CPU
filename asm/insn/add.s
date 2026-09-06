# add.s -- R-type add: rd = rs1 + rs2
# NOP-padded: no forwarding/stall logic exists yet (build step 4), so every
# read of a register written in one of the previous 3 instructions is
# preceded by 3 nops.

li      x5, 10
li      x6, 32
nop
nop
nop
add     x10, x5, x6        # positive + positive = 42

li      x7, -5
nop
nop
nop
add     x11, x5, x7        # positive + negative = 5

li      x8, 0x7fffffff     # INT_MAX
li      x9, 1
nop
nop
nop
add     x12, x8, x9        # overflow wrap -> 0x80000000

nop
nop
nop
add     x13, x0, x6        # x0 operand -> 32
add     x14, x6, x0        # x0 operand (other side) -> 32

ebreak
