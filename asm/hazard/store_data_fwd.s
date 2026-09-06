# store_data_fwd.s -- store-data (rs2) forwarding for sw, including the
# load-then-store case which needs BOTH a load-use stall and a forward.

li      x5, 0x40
addi    x6, x0, 0x55
sw      x6, 0(x5)          # rs2 (x6) forwarded straight from EX/MEM (produced
                            # by the immediately preceding addi)

addi    x7, x0, 0x66
addi    x8, x0, 4
sw      x7, 0(x8)          # rs2 forwarded (EX/MEM), rs1 also EX/MEM -- both
                            # operands need forwarding at once

# load then store: the loaded value needs a load-use stall to reach EX,
# then gets forwarded (from MEM/WB, since a load's result is only ready
# after MEM) as the store's data.
lw      x9, 0(x5)          # x9 = 0x55
sw      x9, 4(x5)          # store the just-loaded value immediately

lw      x10, 4(x5)         # verify -> 0x55

ebreak
