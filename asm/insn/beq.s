# beq.s -- B-type beq: branch if rs1 == rs2.
# NOTE on control-flow NOP padding: at this build stage the pipeline may not
# yet flush the 1-2 instructions fetched along the wrong path while a branch
# resolves in EX. We place 3 literal `nop`s immediately after every
# branch/jump (the fall-through slots) so that whether or not those slots
# get squashed, they are harmless -- the test result is identical either way.

li      x5, 5
li      x6, 5
li      x7, 6
nop
nop
nop
beq     x5, x6, FWD_TAKEN     # taken: 5 == 5 (forward)
nop
nop
nop
addi    x10, x0, 0xAA         # fall-through poison; must not be the final
                                # value of x10 if the branch worked
FWD_TAKEN:
addi    x10, x0, 1            # taken-path result

nop
nop
nop
beq     x5, x7, NOT_TAKEN_TGT # not taken: 5 != 6 (forward)
nop
nop
nop
addi    x11, x0, 1            # executes: branch was not taken
j       AFTER_NT
NOT_TAKEN_TGT:
addi    x11, x0, 0xBB         # must NOT run
AFTER_NT:

# backward taken beq, bounded by a bne-driven loop counter used as scaffold
li      x20, 3                # trip count
li      x22, 0                # visit counter (incremented each backward pass)
BWD:
addi    x22, x22, 1
addi    x20, x20, -1
nop
nop
nop
bne     x20, x0, CONT_BACK    # scaffold: still work to do -> take the beq path
nop
nop
nop
j       BWD_DONE
CONT_BACK:
beq     x20, x20, BWD         # always true (self-compare) -> backward taken
BWD_DONE:
addi    x23, x0, 1            # x22 should read 3 visits, x23 = 1

ebreak
