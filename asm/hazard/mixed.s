# mixed.s -- dense, hand-written mix of dependent ALU ops, loads/stores and
# branches (60-100 dynamic instructions), NOT nop-padded. Exercises
# forwarding, load-use stalling and branch flushing together.

li      x5, 0x100           # data base pointer
li      x6, 1
li      x7, 2
add     x8, x6, x7          # 3
sub     x9, x8, x6          # 2
add     x10, x8, x9         # 5  (both operands forwarded from EX/MEM & MEM/WB)
sw      x10, 0(x5)          # store 5
sw      x8, 4(x5)           # store 3

lw      x11, 0(x5)          # load-use: consumer right after
add     x12, x11, x11       # 10

lw      x13, 4(x5)
sw      x13, 8(x5)          # load->store, data forwarded after stall
lw      x14, 8(x5)          # verify -> 3

li      x15, 3
beq     x14, x15, EQ1       # branch operand (x14) forwarded from a load 2
                            # instructions back
addi    x16, x0, 0xBB
j       AFTER_EQ1
EQ1:
addi    x16, x0, 1
AFTER_EQ1:

# small countdown loop mixing forwarding + backward branch
li      x17, 4              # counter
li      x18, 0              # accumulator
LOOP:
add     x18, x18, x17       # x18 += x17 (rs2 forwarded from the loop update)
addi    x17, x17, -1        # counter-- (its own producer 2 back each pass)
bne     x17, x0, LOOP       # backward taken while x17 != 0
                            # sum = 4+3+2+1 = 10 -> x18 = 10

addi    x19, x18, 5         # forward from the loop's last write -> 15
sub     x20, x19, x16       # x19 (EX/MEM) and x16 (older, MEM/WB by now)

# store-data forward immediately into a load-use chain
li      x21, 0x200
addi    x22, x0, 42
sw      x22, 0(x21)         # rs2 forwarded
lw      x23, 0(x21)         # load
addi    x24, x23, 1         # load-use -> 43
bge     x24, x22, GE1       # 43 >= 42 -> taken, operand forwarded from
                            # the immediately preceding addi
addi    x25, x0, 0xBB
j       AFTER_GE1
GE1:
addi    x25, x0, 1
AFTER_GE1:

# x0 hazard woven into the mix
addi    x0, x0, 99
add     x26, x0, x24        # must read x0 as 0, not 99 -> x26 = 43

# a final dependency chain touching a CSR
csrrw   x27, 0x340, x26     # 0x340 (mscratch) is an unimplemented CSR:
                            # reads 0, write ignored -> x27 = 0
addi    x28, x27, 7         # immediate consumer -> 7

ebreak
