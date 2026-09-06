# branch_flush.s -- control-flow flush correctness. Poison instructions
# placed in the branch/jump delay slots MUST be squashed; if not, they
# corrupt a result register and the test fails when diffed against iss.py.

li      x5, 5
li      x6, 5
beq     x5, x6, T1          # taken; 2 poison slots follow (EX resolution)
addi    x10, x0, 999        # poison 1 -- must be flushed
addi    x10, x0, 998        # poison 2 -- must be flushed
T1:
addi    x10, x0, 1          # the only value x10 may end up holding

jal     x11, T2             # resolves in ID -> 1 poison slot
addi    x12, x0, 999        # poison -- must be flushed
T2:
addi    x12, x0, 1

la      x13, T3
jalr    x14, x13, 0         # resolves in EX -> 2 poison slots
addi    x15, x0, 999        # poison 1
addi    x15, x0, 998        # poison 2
T3:
addi    x15, x0, 1

# not-taken branch: the following instructions are the CORRECT path and
# must execute (nothing to flush here).
li      x16, 1
li      x17, 2
beq     x16, x17, WRONG     # not taken (1 != 2): fall-through must run
addi    x18, x0, 1          # must execute (not-taken path)
j       AFTER_NT
WRONG:
addi    x18, x0, 0xBB
AFTER_NT:

# branch operands forwarded from the immediately preceding instruction
addi    x19, x0, 7
addi    x20, x0, 7
beq     x19, x20, T5        # both compare operands need EX/MEM forwarding
                            # into the branch_unit
addi    x21, x0, 0xBB
T5:
addi    x21, x0, 1

ebreak
