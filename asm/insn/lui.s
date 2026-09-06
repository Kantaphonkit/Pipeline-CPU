# lui.s -- U-type lui: rd = imm20 << 12 (upper 20 bits, low 12 bits zero)

lui     x5, 0xfffff       # -> 0xFFFFF000 (negative-looking pattern)
lui     x6, 1             # -> 0x00001000
lui     x7, 0             # -> 0x00000000
lui     x8, 0x7ffff       # -> 0x7FFFF000 (max positive-looking pattern)

ebreak
