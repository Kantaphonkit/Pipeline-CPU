# auipc.s -- U-type auipc: rd = PC + (imm20 << 12)

auipc   x5, 0             # x5 = PC of this instruction (offset 0)
nop
nop
nop
auipc   x6, 1             # x6 = PC(of this instr) + 0x1000
nop
nop
nop
auipc   x7, 0xfffff       # x7 = PC(of this instr) + 0xFFFFF000 (wraps around)

ebreak
