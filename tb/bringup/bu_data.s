# bu_data.s -- step-4 bring-up: a program with a .data section, so the
# testbench has to preload DMEM from <prog>.data.hex before releasing reset.
# Straight line, hazard-free, so the commit trace must match the ISS exactly.

        .data
        .org    0x80
vals:   .word   0x11223344, 0xdeadbeef, 0x00000001, 0xffffffff
halves: .half   0x1234, 0x8765
bytes:  .byte   0x7f, 0x80, 0x01, 0xfe

        .text
        addi    x5, x0, 0x80        # &vals, fits in 12 signed bits
        nop
        nop
        nop
        lw      x10, 0(x5)          # 0x11223344
        lw      x11, 4(x5)          # 0xdeadbeef
        lw      x12, 8(x5)          # 0x00000001
        lw      x13, 12(x5)         # 0xffffffff
        lh      x14, 16(x5)         # 0x1234
        lh      x15, 18(x5)         # 0x8765 -> 0xffff8765
        lhu     x16, 18(x5)         # 0x00008765
        lb      x17, 20(x5)         # 0x7f
        lb      x18, 21(x5)         # 0x80 -> 0xffffff80
        lbu     x19, 21(x5)         # 0x00000080
        lb      x20, 23(x5)         # 0xfe -> 0xfffffffe
        nop
        nop
        nop
        add     x21, x10, x12       # 0x11223345 (loads are 4+ slots back)
        nop
        nop
        nop
        sw      x21, 32(x5)         # write it back out
        nop
        nop
        nop
        lw      x22, 32(x5)         # 0x11223345
        ebreak
