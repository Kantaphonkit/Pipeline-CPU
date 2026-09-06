# bu_mem.s -- step-4 bring-up: all 3 stores and all 5 loads, byte lanes and
# sign/zero extension.  Straight line, >= 3 NOPs between producer and consumer,
# no `li` of a wide constant (the two halves are written out explicitly).

        .text
        addi    x5, x0, 0x40        # base address, fits in 12 signed bits
        lui     x6, 0x84838         # x6 = 0x84838000
        nop
        nop
        nop
        addi    x6, x6, 0x281       # x6 = 0x84838281  (bytes LE 81 82 83 84)
        lui     x7, 0x12345         # x7 = 0x12345000
        nop
        nop
        nop
        addi    x7, x7, 0x678       # x7 = 0x12345678
        nop
        nop
        nop

        # ---- stores ----
        sw      x6, 0(x5)           # mem[0x40] = 0x84838281
        sw      x7, 4(x5)           # mem[0x44] = 0x12345678
        sh      x7, 8(x5)           # mem[0x48] halfword 0 = 0x5678
        sh      x6, 10(x5)          # mem[0x48] halfword 1 = 0x8281
        sb      x7, 12(x5)          # mem[0x4c] byte 0 = 0x78
        sb      x6, 13(x5)          # mem[0x4c] byte 1 = 0x81
        sb      x7, 14(x5)          # mem[0x4c] byte 2 = 0x78
        sb      x6, 15(x5)          # mem[0x4c] byte 3 = 0x81
        sw      x0, 16(x5)          # mem[0x50] = 0

        # ---- loads (no consumer of any loaded value: no load-use hazard) ----
        lw      x10, 0(x5)          # 0x84838281
        lw      x11, 4(x5)          # 0x12345678
        lh      x12, 0(x5)          # 0x8281 sign-extended -> 0xffff8281
        lh      x13, 2(x5)          # 0x8483 sign-extended -> 0xffff8483
        lhu     x14, 0(x5)          # 0x00008281
        lhu     x15, 2(x5)          # 0x00008483
        lb      x16, 0(x5)          # 0x81 -> 0xffffff81
        lb      x17, 1(x5)          # 0x82 -> 0xffffff82
        lb      x18, 2(x5)          # 0x83 -> 0xffffff83
        lb      x19, 3(x5)          # 0x84 -> 0xffffff84
        lbu     x20, 0(x5)          # 0x00000081
        lbu     x21, 3(x5)          # 0x00000084
        lb      x22, 4(x5)          # 0x78 (positive) -> 0x00000078
        lh      x23, 8(x5)          # 0x5678 -> 0x00005678
        lh      x24, 10(x5)         # 0x8281 -> 0xffff8281
        lw      x25, 12(x5)         # 0x81788178
        lw      x26, 16(x5)         # 0
        lb      x27, 0(x0)          # DMEM word 0 is zero-filled -> 0

        ebreak
