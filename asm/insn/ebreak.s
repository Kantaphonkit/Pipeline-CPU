# ebreak.s -- SYSTEM ebreak: not a trap. Retires normally (visible in the
# commit trace/perf counters) and sets the sticky `done` halt flag. Just a
# few ordinary instructions beforehand.

li      x5, 1
li      x6, 2
nop
nop
nop
add     x10, x5, x6        # x10 = 3, proves normal execution up to here

ebreak
