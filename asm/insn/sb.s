# sb.s -- S-type sb: mem[rs1+imm] = rs2[7:0], other bytes of the word
# untouched. Pre-fill the word with sw, overwrite one byte with sb, verify
# by reading the whole word back with lw plus the byte with lbu.

li      x5, 0x40
li      x6, 0x11223344
nop
nop
nop
sw      x6, 0(x5)          # pre-existing word = 0x11223344

li      x7, 0xAA
nop
nop
nop
sb      x7, 0(x5)          # overwrite byte 0 only -> 0x112233AA
sb      x7, 3(x5)          # overwrite byte 3 (highest lane) -> 0xAA2233AA

nop
nop
nop
lw      x10, 0(x5)         # readback whole word -> 0xAA2233AA
lbu     x11, 0(x5)         # readback byte0 -> 0xAA
lbu     x12, 3(x5)         # readback byte3 -> 0xAA
lbu     x13, 1(x5)         # untouched byte1 -> 0x33
lbu     x14, 2(x5)         # untouched byte2 -> 0x22

ebreak
