# asm/smoke.s -- exercises all 46 encodings of docs/INTERFACES.md section 1
#
#   python tools/asm.py asm/smoke.s -o sim/work/smoke.hex
#   python tools/iss.py sim/work/smoke.hex --trace sim/work/smoke.trace --dump-regs
#
# Runs straight through, takes every branch, calls a subroutine, traps on
# ecall into a handler that advances mepc and returns with mret, then halts
# on ebreak.  No .data section: the program stores into DMEM at run time.

        .text
_start:
        li      sp, 0x1000              # lui + addi   (stack top = top of DMEM)
        auipc   t0, 0                   # auipc
        la      t1, trap_handler        # lui + addi
        csrrw   x0, mtvec, t1           # csrrw   mtvec <- handler
        csrrs   t2, mtvec, x0           # csrrs   (rs1=x0 -> read only)
        csrrc   t3, mcause, x0          # csrrc   (rs1=x0 -> read only)
        csrrwi  x0, mcause, 8           # csrrwi  mcause <- 8
        csrrsi  x0, mcause, 1           # csrrsi  mcause <- 9
        csrrci  x0, mcause, 1           # csrrci  mcause <- 8

        # ---- register-register ALU ----
        addi    a0, x0, 100
        addi    a1, x0, -7
        add     a2, a0, a1              # add    93
        sub     a3, a0, a1              # sub    107
        sll     a4, a0, a1              # sll    shamt = rs2[4:0] = 25
        srl     a5, a0, a1              # srl    shamt = 25
        sra     a6, a1, a0              # sra    shamt = 100 & 31 = 4
        slt     a7, a1, a0              # slt    1
        sltu    s2, a1, a0              # sltu   0
        xor     s3, a0, a1              # xor
        or      s4, a0, a1              # or
        and     s5, a0, a1              # and

        # ---- register-immediate ALU ----
        slti    s6, a1, 0               # slti   1
        sltiu   s7, a1, 0               # sltiu  0
        xori    s8, a0, -1              # xori
        ori     s9, a0, 0x0f            # ori
        andi    s10, a0, 0x0f           # andi
        slli    s11, a0, 3              # slli
        srli    t4, a0, 2               # srli
        srai    t5, a1, 1               # srai

        # ---- memory ----
        addi    t6, x0, 0x40            # data scratch at DMEM 0x40
        sw      a0, 0(t6)               # sw
        sh      a1, 4(t6)               # sh
        sb      a1, 8(t6)               # sb
        lw      t0, 0(t6)               # lw
        lh      t1, 4(t6)               # lh   sign extended
        lhu     t2, 4(t6)               # lhu  zero extended
        lb      t3, 8(t6)               # lb   sign extended
        lbu     a0, 8(t6)               # lbu  zero extended

        # ---- branches (every one is taken; the fillers never execute) ----
        addi    a1, x0, 5
        addi    a2, x0, 6
        beq     a1, a1, B1
        ebreak
B1:     bne     a1, a2, B2
        ebreak
B2:     blt     a1, a2, B3
        ebreak
B3:     bge     a2, a1, B4
        ebreak
B4:     bltu    a1, a2, B5
        ebreak
B5:     bgeu    a2, a1, B6
        ebreak
B6:
        # ---- jumps ----
        jal     ra, subr                # jal
        # ---- synchronous trap ----
        ecall                           # ecall -> trap_handler -> mret
        ebreak                          # halt (done flag for the testbench)

subr:
        addi    a3, x0, 1
        jalr    x0, 0(ra)               # jalr

trap_handler:
        csrrs   t0, mepc, x0            # read faulting PC
        addi    t0, t0, 4               # synchronous trap: skip the ecall
        csrrw   x0, mepc, t0
        mret                            # mret
