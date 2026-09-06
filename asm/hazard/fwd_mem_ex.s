# fwd_mem_ex.s -- dependency at distance 2 (one instruction in between):
# the producer is in MEM/WB by the time the consumer reaches EX.

addi    x5, x0, 7
addi    x6, x0, 1          # unrelated filler instruction between producer/consumer
add     x7, x5, x5         # x5 is 2 instructions back -> MEM/WB forward -> x7=14

addi    x8, x0, 3
addi    x9, x0, 4          # filler
sub     x10, x9, x8        # x9 at distance 1 (EX/MEM), x8 at distance 2 (MEM/WB)
                            # -> x10 = 1, exercises both forwarding sources
                            #    at once

li      x11, 0x40
addi    x12, x0, 99        # filler
sw      x11, 0(x12)        # rs1 (x12) at distance 2 needs MEM/WB forward for
                            # the address; rs2 (x11) at distance... (li may be
                            # 1 insn) -- exercises non-ALU consumer too

ebreak
