# bpred.s -- branch-prediction demo: loop-heavy program that a 2-bit BHT
# predicts well. Every loop back-edge is a conditional branch (bne/blt/bge)
# that is taken on nearly every pass, so a 2-bit saturating counter locks
# onto "taken" quickly and only mispredicts once per loop (on exit). This is
# the mirror image of bloop.s's alternating if/else, which a 2-bit predictor
# cannot learn.
#
# Structure:
#   1. Outer(20) x Inner(30) running checksum (add/xor/slli mix)      -> x28
#   2. Fixed 32-word "count set bits" loop, bltz tests on top 4 bits  -> x29
#   3. Linear search over the same 32-word array, exits via beq       -> x30
#   4. Triangular loop for i<40: for j<i, i*j accumulated via
#      repeated addition (no MUL in RV32I)                            -> x31
#
# Expected dynamic mix: several thousand retired instructions, well over
# 600 dynamic conditional branches, with a large majority taken (loop
# back-edges dominate) -- so static-not-taken accuracy should land well
# below 50%, which is exactly the case a 2-bit BHT wins big on.

        .data
arr:    .word 0x00000001, 0x00000002, 0x00000003, 0x00000004
        .word 0x00000005, 0x80000006, 0x00000007, 0x00000008
        .word 0x00000009, 0x0000000a, 0x0000000b, 0x0000000c
        .word 0x0000000d, 0x0000000e, 0x0000000f, 0x00000010
        .word 0x00000011, 0x00000041, 0x00000012, 0x00000013
        .word 0x40000014, 0x00000015, 0x00000016, 0x00000017
        .word 0x00000018, 0x20000019, 0x0000001a, 0x0000001b
        .word 0x0000001c, 0x0000001d, 0x1000001e, 0x0000001f

        .text
_start:
        li      sp, 0x1000
        li      x28, 0             # checksum
        li      x29, 0             # set-bit count
        li      x31, 0             # triangular sum

        # ---- 1. outer(20) x inner(30) running checksum ----
        li      x5, 0              # i
        li      x6, 20             # outer limit
OUTER1:
        slli    x9, x5, 1          # mix: slli on outer index
        xor     x28, x28, x9       # mix: xor into checksum once per outer pass
        li      x7, 0              # j
        li      x8, 30             # inner limit
INNER1:
        add     x28, x28, x7       # mix: add inner index into checksum
        addi    x7, x7, 1
        blt     x7, x8, INNER1     # back-edge, taken 29/30 passes
        addi    x5, x5, 1
        blt     x5, x6, OUTER1     # back-edge, taken 19/20 passes

        # ---- 2. count set bits (top 4 bits) over 32 words ----
        la      x12, arr
        li      x13, 0             # word index
        li      x14, 32            # word limit
BITWORD:
        slli    x15, x13, 2
        add     x16, x12, x15
        lw      x17, 0(x16)        # cur word
        bltz    x17, BS1
        j       BC1
BS1:    addi    x29, x29, 1
BC1:    slli    x17, x17, 1
        bltz    x17, BS2
        j       BC2
BS2:    addi    x29, x29, 1
BC2:    slli    x17, x17, 1
        bltz    x17, BS3
        j       BC3
BS3:    addi    x29, x29, 1
BC3:    slli    x17, x17, 1
        bltz    x17, BS4
        j       BC4
BS4:    addi    x29, x29, 1
BC4:    addi    x13, x13, 1
        blt     x13, x14, BITWORD  # back-edge, taken 31/32 passes

        # ---- 3. linear search over the same array, exits via beq ----
        la      x20, arr
        li      x30, 0             # search index
        li      x21, 32            # bound
        li      x22, 0x00000041    # target: arr[17]
SEARCH:
        slli    x23, x30, 2
        add     x24, x20, x23
        lw      x25, 0(x24)
        beq     x25, x22, FOUND    # exit via beq once, after a known trip count
        addi    x30, x30, 1
        blt     x30, x21, SEARCH   # back-edge, taken while still searching
FOUND:
        # ---- 4. triangular loop: for i<40: for j<i, sum += i*j ----
        li      x5, 0              # i
        li      x6, 40             # outer limit
TRIOUTER:
        li      x7, 0              # j
        li      x9, 0              # term = i*j, starts at i*0 = 0
        bge     x7, x5, TRIDONE    # guard: skip inner loop entirely when i==0
TRIINNER:
        add     x31, x31, x9       # sum += term (term == i*j on entry)
        add     x9, x9, x5         # term += i  (repeated add, no MUL)
        addi    x7, x7, 1
        blt     x7, x5, TRIINNER   # back-edge, taken while j < i
TRIDONE:
        addi    x5, x5, 1
        blt     x5, x6, TRIOUTER   # back-edge, taken 39/40 passes

        ebreak
