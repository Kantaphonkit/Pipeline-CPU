# bu_csr.s -- step-4 bring-up: all 6 CSR ops against all 5 implemented CSRs.
# No trap and no control transfer, so the commit trace must match the ISS
# byte for byte.  The last three CSR instructions are deliberately NOT padded:
# the CSR file does its read-modify-write inside EX in a single cycle, so the
# next instruction sees the updated value one cycle later with no interlock.

        .text
        addi    x5, x0, 0x123
        nop
        nop
        nop
        csrrw   x6, mcause, x5      # x6 = 0 (old), mcause = 0x123
        nop
        nop
        nop
        csrrs   x7, mcause, x0      # rs1 = x0 -> read only, x7 = 0x123
        addi    x8, x0, 0x400
        nop
        nop
        nop
        csrrs   x9, mcause, x8      # x9 = 0x123, mcause = 0x523
        nop
        nop
        nop
        csrrc   x10, mcause, x8     # x10 = 0x523, mcause = 0x123
        nop
        nop
        nop
        csrrwi  x11, mcause, 7      # x11 = 0x123, mcause = 7
        nop
        nop
        nop
        csrrsi  x12, mcause, 8      # x12 = 7, mcause = 0x0f
        nop
        nop
        nop
        csrrci  x13, mcause, 1      # x13 = 0x0f, mcause = 0x0e
        nop
        nop
        nop

        # ---- mstatus: only MIE (bit 3) and MPIE (bit 7) exist ----
        addi    x14, x0, 8
        nop
        nop
        nop
        csrrs   x15, mstatus, x14   # x15 = 0, mstatus.MIE = 1
        nop
        nop
        nop
        csrrs   x16, mstatus, x0    # x16 = 8
        addi    x17, x0, 0x780      # bits 7 and 10:8; only bit 7 is implemented
        nop
        nop
        nop
        csrrs   x18, mstatus, x17   # x18 = 8, mstatus = MIE|MPIE = 0x88
        nop
        nop
        nop
        csrrs   x19, mstatus, x0    # x19 = 0x88 (unimplemented bits read 0)

        # ---- mie: only MEIE (bit 11) exists ----
        addi    x20, x0, 1          # 0x800 needs 12 bits + sign, so build it
        nop
        nop
        nop
        slli    x20, x20, 11        # x20 = 0x800 (MEIE)
        nop
        nop
        nop
        csrrs   x21, mie, x20       # x21 = 0, mie.MEIE = 1
        nop
        nop
        nop
        csrrs   x22, mie, x0        # x22 = 0x800

        # ---- mtvec / mepc: bits [1:0] are hardwired to 00 ----
        addi    x23, x0, 0x103      # low bits set on purpose
        nop
        nop
        nop
        csrrw   x24, mtvec, x23     # x24 = 0, mtvec = 0x100
        nop
        nop
        nop
        csrrs   x25, mtvec, x0      # x25 = 0x100
        csrrw   x26, mepc, x23      # x26 = 0, mepc = 0x100
        nop
        nop
        nop
        csrrs   x27, mepc, x0       # x27 = 0x100

        # ---- unimplemented CSR: reads 0, writes ignored ----
        csrrw   x28, 0x7C0, x23     # x28 = 0
        nop
        nop
        nop
        csrrs   x29, 0x7C0, x0      # x29 = 0

        # ---- back-to-back CSR read-modify-write, no padding ----
        csrrwi  x30, mcause, 5      # x30 = 0x0e, mcause = 5
        csrrsi  x31, mcause, 2      # x31 = 5,    mcause = 7
        csrrs   x3,  mcause, x0     # x3  = 7

        ebreak
