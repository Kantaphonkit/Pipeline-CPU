# bsort.s -- in-place bubble sort of a 16-word array (pseudo-random order,
# includes negatives), nested loops with bge/blt swap logic via lw/sw.
# Leaves a checksum of the sorted array in a register.
#
# Sorted order must be strictly non-decreasing:
#   -9999 -256 -64 -17 -3 -1 0 5 7 8 17 42 64 99 123 1000
# (ISS trace / dump confirms this -- see gen_fixtures.py output.)

        .data
arr:    .word 42, -17, 8, 1000, -3, 0, 99, -256, 17, 5, -1, 123, 64, -64, 7, -9999

        .text
_start:
        li      sp, 0x1000
        la      x5, arr
        li      x6, 16             # n
        addi    x7, x6, -1         # n-1 (outer trip count)

        li      x8, 0              # i
OUTER:
        bge     x8, x7, OUTER_DONE
        li      x9, 0              # j
        sub     x10, x7, x8        # inner limit = (n-1) - i
INNER:
        bge     x9, x10, INNER_DONE
        slli    x11, x9, 2
        add     x12, x5, x11       # &arr[j]
        lw      x13, 0(x12)        # arr[j]
        lw      x14, 4(x12)        # arr[j+1]
        blt     x14, x13, DO_SWAP  # swap if arr[j+1] < arr[j]
        j       NO_SWAP
DO_SWAP:
        sw      x14, 0(x12)
        sw      x13, 4(x12)
NO_SWAP:
        addi    x9, x9, 1
        j       INNER
INNER_DONE:
        addi    x8, x8, 1
        j       OUTER
OUTER_DONE:

        # checksum the sorted array
        la      x21, arr
        li      x22, 0             # index
        li      x23, 16            # limit
        li      x24, 0             # checksum
CHK_LOOP:
        bge     x22, x23, CHK_DONE
        slli    x25, x22, 2
        add     x26, x21, x25
        lw      x27, 0(x26)
        add     x24, x24, x27
        addi    x22, x22, 1
        j       CHK_LOOP
CHK_DONE:
        ebreak
