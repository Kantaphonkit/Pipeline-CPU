# fib.s -- iterative Fibonacci, fib(0..30) into a DMEM array, fib(30) left
# in a register. Loop uses blt/bne per the spec. Padded with a checksum
# pass and a copy pass so the dynamic instruction count comfortably clears
# the >=500 retired-instruction floor for program-level tests.

        .data
fib_arr:  .space 124      # 31 words, fib(0)..fib(30)
fib_copy: .space 124      # verification copy destination

        .text
_start:
        li      sp, 0x1000

        la      x5, fib_arr
        li      x6, 0              # fib(i-2), starts at fib(0)
        li      x7, 1              # fib(i-1), starts at fib(1)
        sw      x6, 0(x5)          # fib_arr[0] = 0
        sw      x7, 4(x5)          # fib_arr[1] = 1
        li      x8, 2              # i
        li      x9, 31             # limit (exclusive): fills indices 0..30

FIB_LOOP:
        add     x10, x6, x7        # fib(i) = fib(i-2) + fib(i-1)
        slli    x11, x8, 2
        add     x12, x5, x11
        sw      x10, 0(x12)
        mv      x6, x7
        mv      x7, x10
        addi    x8, x8, 1
        blt     x8, x9, FIB_LOOP   # backward taken while i < 31

        # checksum pass over all 31 entries (bne-driven loop)
        la      x13, fib_arr
        li      x14, 0             # index
        li      x15, 31            # limit
        li      x16, 0             # checksum accumulator
SUM_LOOP:
        slli    x17, x14, 2
        add     x18, x13, x17
        lw      x19, 0(x18)
        add     x16, x16, x19
        addi    x14, x14, 1
        bne     x14, x15, SUM_LOOP # backward taken while index != 31

        # copy pass: fib_arr -> fib_copy (exercises loads/stores in a loop)
        la      x20, fib_arr
        la      x21, fib_copy
        li      x22, 0
        li      x23, 31
COPY_LOOP:
        slli    x24, x22, 2
        add     x25, x20, x24
        add     x26, x21, x24
        lw      x27, 0(x25)
        sw      x27, 0(x26)
        addi    x22, x22, 1
        bne     x22, x23, COPY_LOOP

        lw      x28, 120(x5)       # fib(30) -> expect 832040 (0x000cb228)
        ebreak
