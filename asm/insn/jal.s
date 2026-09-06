# jal.s -- J-type jal: rd = PC+4 (link), PC = PC + J-imm.
# Uses rd != ra (x10) per the task requirement -- jal writes whatever rd is
# given, x1-as-ra is convention only. jal resolves in ID (1-bubble) but we
# still pad the fall-through with 3 nops for safety/consistency.

jal     x10, FWD_TARGET   # rd = x10 (not ra), forward jump
nop
nop
nop
addi    x11, x0, 0xBB     # fall-through; must not run if the jump works
FWD_TARGET:
addi    x12, x0, 1        # confirms target reached; x10 holds the link value

# a genuine backward jal (rd = x0, the `j` idiom), bounded by a bne-driven
# trip counter used purely as scaffolding (jal itself is unconditional).
li      x13, 0            # visit counter
li      x16, 2            # trip count
BACK:
addi    x13, x13, 1
addi    x16, x16, -1
nop
nop
nop
bne     x16, x0, CONT_JAL # scaffold: more iterations needed -> take the jal
nop
nop
nop
j       AFTER_BACK        # done -> skip the backward jal entirely
CONT_JAL:
jal     x0, BACK          # backward, unconditional -> x13 visited twice total
AFTER_BACK:
addi    x15, x0, 1        # x13 should read 2

ebreak
