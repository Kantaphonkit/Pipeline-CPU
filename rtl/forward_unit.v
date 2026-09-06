`timescale 1ns/1ps
//=============================================================================
// forward_unit.v -- EX-stage operand forwarding selects.
//
// Purely combinational.  Compares the register numbers the instruction in EX
// reads against the destinations of the two older instructions still in flight
// (the one in MEM, held by the EX/MEM register, and the one in WB, held by the
// MEM/WB register) and picks where each EX operand should come from.
//
// Select encoding (shared by all three outputs):
//   2'b00  the register-file value carried in ID/EX (no forward needed)
//   2'b10  EX/MEM result  (the instruction one stage ahead -- the NEWER one)
//   2'b01  MEM/WB write data (the instruction two stages ahead -- OLDER)
//
// Three separate selects because three different EX operands need forwarding:
//   fwd_a  ALU operand A / branch compare rs1 / CSR write source (rs1)
//   fwd_b  ALU operand B and branch compare rs2, taken BEFORE the rs2 vs.
//          immediate mux (a branch compares rs2 even though the ALU sees imm)
//   fwd_c  store data for sb/sh/sw (rs2 again, on its own path to dmem.wdata)
//
// Truth table (per operand; `rs` is the operand's source register number):
//
//   FORWARDING | EX/MEM match           | MEM/WB match          | select
//   -----------+------------------------+-----------------------+--------
//        0     | (don't care)           | (don't care)          | 2'b00
//        1     | reg_we & rd!=0 & rd==rs| (don't care)          | 2'b10
//        1     | no                     | reg_we & rd!=0 & rd==rs| 2'b01
//        1     | no                     | no                    | 2'b00
//
// Two rules the table encodes, both on the classic-bug checklist:
//
//  * **EX/MEM wins over MEM/WB.**  When both older instructions write the same
//    architectural register, the one in MEM is the newer writer and its value
//    is the one the architecture says this instruction must read.  Checking
//    MEM/WB first would resurrect the stale value.  (asm/hazard/fwd_ex_ex.s
//    ends with exactly that sequence: x5=100, x5=x5+1, then a consumer that
//    must see 101 and not 100.)
//
//  * **Never forward from x0.**  A producer whose rd is x0 wrote nothing --
//    the register file suppresses the write -- so forwarding its result would
//    make x0 read non-zero for one instruction.  The `rd != 0` test here is
//    what stops that; note it also implies `rs != 0`, so no separate check on
//    the consumer side is needed.  (asm/hazard/x0_hazard.s.)
//
// Not covered here, by design: a **load** whose result is still in EX/MEM.
// EX/MEM carries the ALU result, which for a load is the effective address,
// not the loaded data.  hazard_unit.v's load-use interlock guarantees a
// consumer never reaches EX while its producing load is only as far as MEM, so
// the 2'b10 path is never taken for a load.  By the time the consumer does
// reach EX the load is in WB and the 2'b01 path carries real load data.
//
// FORWARDING = 0 is the CPI-comparison build: every select is forced to 2'b00
// and hazard_unit.v stalls on every RAW hazard instead.
//
// Naming: `mem_*` are the EX/MEM register outputs (instruction now in MEM),
// `wb_*` are the MEM/WB register outputs (instruction now in WB).
//=============================================================================

module forward_unit #(
    parameter FORWARDING = 1
) (
    // consumer: instruction currently in EX
    input  wire [4:0] ex_rs1,
    input  wire [4:0] ex_rs2,
    // producer one stage ahead: instruction currently in MEM (EX/MEM register)
    input  wire       mem_reg_we,
    input  wire [4:0] mem_rd,
    // producer two stages ahead: instruction currently in WB (MEM/WB register)
    input  wire       wb_reg_we,
    input  wire [4:0] wb_rd,

    output wire [1:0] fwd_a,        // ALU operand A / branch rs1 / CSR source
    output wire [1:0] fwd_b,        // ALU operand B / branch rs2 (pre-imm mux)
    output wire [1:0] fwd_c         // store data (rs2 of sb/sh/sw)
);

    localparam FWD_ON = (FORWARDING != 0);

    // A producer only forwards if it really writes a register other than x0.
    wire mem_writes = FWD_ON && mem_reg_we && (mem_rd != 5'd0);
    wire wb_writes  = FWD_ON && wb_reg_we  && (wb_rd  != 5'd0);

    // rs1
    assign fwd_a = (mem_writes && (mem_rd == ex_rs1)) ? 2'b10 :
                   (wb_writes  && (wb_rd  == ex_rs1)) ? 2'b01 :
                                                        2'b00;
    // rs2, ALU / branch path
    assign fwd_b = (mem_writes && (mem_rd == ex_rs2)) ? 2'b10 :
                   (wb_writes  && (wb_rd  == ex_rs2)) ? 2'b01 :
                                                        2'b00;
    // rs2, store-data path (same rule, kept explicit so the store path can be
    // reasoned about and tested on its own -- asm/hazard/store_data_fwd.s)
    assign fwd_c = (mem_writes && (mem_rd == ex_rs2)) ? 2'b10 :
                   (wb_writes  && (wb_rd  == ex_rs2)) ? 2'b01 :
                                                        2'b00;

endmodule
