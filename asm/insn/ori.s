# ori.s -- I-arith ori

li      x5, 0x0F000000
nop
nop
nop
ori     x10, x5, 0x0F0     # set low bits -> 0x0F0000F0
ori     x11, x0, 0x7FF     # or with x0, max positive imm -> 0x7FF
ori     x12, x5, -1        # or with -1 (sign-extended) -> 0xFFFFFFFF

ebreak
