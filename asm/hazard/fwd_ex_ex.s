# fwd_ex_ex.s -- EX/MEM-forwarding-wins-over-MEM/WB priority case, and
# back-to-back dependent ALU chains. NOT NOP-padded: this exercises the
# forwarding unit (build step 5).

addi    x5, x0, 1
addi    x5, x5, 1          # x5 = 2 (depends on x5 immediately -- EX/MEM fwd)
add     x6, x5, x5         # both operands need EX/MEM forward -> x6 = 4

# chain of 5 back-to-back dependent adds
addi    x7, x0, 1
addi    x7, x7, 1          # 2
addi    x7, x7, 1          # 3
addi    x7, x7, 1          # 4
addi    x7, x7, 1          # 5   -- each step forwards from the immediately
                            #        preceding instruction (EX/MEM)

# rs1 dependency and rs2 dependency, distinct sources
addi    x8, x0, 10
addi    x9, x0, 20
add     x10, x8, x9        # rs1 (x8) from 2 back, rs2 (x9) from 1 back:
                            # x9's producer is in EX/MEM when add is in EX,
                            # x8's producer is in MEM/WB -> tests priority
                            # picking EX/MEM (x9) and MEM/WB (x8) correctly.
                            # x10 = 30

# dependency on a register written by an OLDER instruction too (both
# EX/MEM and MEM/WB hold a pending write to the same architectural reg):
# the sequence below writes x5 three times in a row; the consumer must see
# the NEWEST (EX/MEM) value, not the older (MEM/WB) one.
addi    x5, x0, 100
addi    x5, x5, 1          # x5 = 101 (EX/MEM, newer)
                            # at this point the previous "x5=100" write is
                            # sitting in MEM/WB -- priority must pick 101.
add     x11, x5, x0        # x11 = 101 (must forward EX/MEM's 101, not
                            # MEM/WB's 100)

ebreak
