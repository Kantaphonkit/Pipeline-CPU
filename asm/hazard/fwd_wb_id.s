# fwd_wb_id.s -- dependency at distance 3: producer's write lands in the
# regfile in the same cycle the consumer reads it in ID (WB->ID internal
# bypass in regfile.v), with NO EX/MEM or MEM/WB forwarding in play.

addi    x5, x0, 9
addi    x6, x0, 1           # filler 1
addi    x7, x0, 2           # filler 2
add     x8, x5, x5          # x5 written 3 instructions back -> regfile
                            # WB->ID bypass path -> x8 = 18

addi    x9, x0, 5
addi    x10, x0, 1
addi    x11, x0, 1
sub     x12, x9, x0         # rs1 at distance 3, rs2 = x0 (never hazardous)
                            # -> x12 = 5

ebreak
