# load_use.s -- lw immediately followed by a consumer: must load-use STALL
# (no amount of forwarding alone can supply data the load hasn't fetched
# yet). Covers rs1 and rs2 variants, load-as-store-data, load-as-store-
# address, and load-then-branch.

li      x5, 0x40
li      x6, 0x1234
sw      x6, 0(x5)

lw      x7, 0(x5)
add     x8, x7, x0          # rs1 = loaded value (immediate use)          -> 0x1234
add     x9, x0, x7          # rs2 = loaded value (immediate use)          -> 0x1234

lw      x10, 0(x5)
add     x11, x10, x10       # both operands are the loaded value

# load used as the ADDRESS of a subsequent store
li      x12, 0x44
li      x13, 0xAAAA
sw      x13, 0(x12)         # mem[0x44] = 0xAAAA  (an address value to load)
lw      x14, 0(x12)         # x14 = 0xAAAA
sw      x0, 0(x14)          # x14 used immediately as rs1 (base address)
                            # writes 0 to mem[0xAAAA & 0xFFF]

# load used as the DATA of a subsequent store
lw      x15, 0(x5)          # x15 = 0x1234 again
sw      x15, 4(x5)          # x15 used immediately as rs2 (store data)
lw      x16, 4(x5)          # verify -> 0x1234

# load then branch on the loaded value
li      x17, 0x48
li      x18, 1
sw      x18, 0(x17)
lw      x19, 0(x17)
beq     x19, x18, TAKEN     # branch operand is the just-loaded value
addi    x20, x0, 0xBB
TAKEN:
addi    x20, x0, 1

ebreak
