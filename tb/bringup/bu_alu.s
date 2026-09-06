# bu_alu.s -- step-4 bring-up: every R-type and I-arith op, plus lui/auipc.
# Straight line, no control transfers, >= 3 NOPs between producer and consumer.

        .text
        addi    x5, x0, 100         # x5 = 100
        addi    x6, x0, -7          # x6 = -7
        nop
        nop
        nop

        # ---- R-type (all 10) ----  every one reads only x5 / x6
        add     x10, x5, x6         # 93
        sub     x11, x5, x6         # 107
        sll     x12, x5, x6         # shamt = rs2[4:0] = 25
        slt     x13, x6, x5         # 1
        sltu    x14, x6, x5         # 0 (x6 is huge unsigned)
        xor     x15, x5, x6
        srl     x16, x5, x6         # shamt 25
        sra     x17, x6, x5         # shamt = 100 & 31 = 4
        or      x18, x5, x6
        and     x19, x5, x6

        # ---- I-arith (all 9) ----  same sources, still no new dependency
        addi    x20, x5, -1         # inst[30] = 1 but must stay ADD
        slti    x21, x6, 0          # 1
        sltiu   x22, x6, 0          # 0
        xori    x23, x5, -1
        ori     x24, x5, 0x0f
        andi    x25, x5, 0x0f
        slli    x26, x5, 3
        srli    x27, x5, 2
        srai    x28, x6, 1          # -4

        # ---- U-type ----
        lui     x29, 0xABCDE        # 0xABCDE000
        auipc   x30, 0              # PC of this instruction
        auipc   x31, 1              # PC + 0x1000

        # ---- shift-amount masking with a register source ----
        addi    x7, x0, 33          # 33 & 31 = 1
        nop
        nop
        nop
        sll     x9, x5, x7          # 200
        srl     x8, x5, x7          # 50

        ebreak
