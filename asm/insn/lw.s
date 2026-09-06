# lw.s -- I-load lw: rd = mem[rs1+imm] (full word, no extension needed)

li      x5, 0x40
li      x6, 0x89ABCDEF     # value with sign bit set, must NOT be sign-extended
                            # (it's already a full 32-bit word)
nop
nop
nop
sw      x6, 0(x5)
sw      x0, 4(x5)          # store 0 at next word

nop
nop
nop
lw      x10, 0(x5)         # -> 0x89ABCDEF
lw      x11, 4(x5)         # -> 0

lw      x12, -0x40(x5)     # 0x40 + (-0x40) = 0, reads whatever imem/dmem init
                            # gives at dmem address 0 (dmem is zero-initialised
                            # unless a .data section loads it) -> 0

ebreak
