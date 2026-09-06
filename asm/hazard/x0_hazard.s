# x0_hazard.s -- writes to x0 must never be forwarded and must never
# actually change x0 (regfile suppresses the write; forward_unit must also
# suppress forwarding from a producer whose rd == x0).

addi    x0, x0, 5           # "writes" 5 to x0 -- must have no effect
add     x5, x0, x0          # if x0 were corrupted to 5, x5 would be 10 here
                            # instead of 0

addi    x0, x0, 123         # another x0 write, immediately followed by a
add     x6, x0, x0          # consumer -- classic forwarding-from-x0 trap:
                            # the forward_unit must see rd==0 and NOT
                            # present 123 to this add

sub     x0, x5, x5          # arithmetic result would be 0 anyway, but this
                            # still must not "write" x0
addi    x7, x0, 1           # x7 = 1 (proves x0 still reads 0)

lw      x0, 0(x5)           # a load targeting x0 (address 0, dmem is zero)
                            # -- must not write x0 either
add     x8, x0, x0          # -> 0

ebreak
