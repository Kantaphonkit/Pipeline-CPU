`timescale 1ns/1ps
//=============================================================================
// forward_unit.v -- EX-stage operand forwarding selects.
//
// STATUS: build step 4 STUB.  The port list, the select encoding and the
// FORWARDING parameter below are final; the body currently drives every select
// to 2'b00 (= use the value read from the register file in ID) so the step-4
// datapath is a plain NOP-padded machine with no bypasses.  Build step 5 fills
// the always block in -- nothing outside this file has to change.
//
// Select encoding (shared by all three outputs):
//   2'b00  register-file value carried in ID/EX
//   2'b10  EX/MEM result  (older instruction, one stage ahead)
//   2'b01  MEM/WB result  (oldest instruction, two stages ahead)
//
// Rules that step 5 must implement (docs/DESIGN.md section 6):
//   * EX/MEM has PRIORITY over MEM/WB.  MEM/WB forwards only when EX/MEM does
//     not match.  (Forwarding the older value would resurrect a stale result.)
//   * Never forward from x0: a producer with rd = 0 wrote nothing, and x0 must
//     read as 0.  Both the rd != 0 test here and the x0 test in regfile.v are
//     required.
//   * fwd_a  -> ALU operand A source (rs1)
//     fwd_b  -> ALU operand B source (rs2, before the rs2/immediate mux)
//     fwd_c  -> store-data source (rs2 of sb/sh/sw).  Logically identical to
//               fwd_b, kept separate so the store-data path is explicit in the
//               datapath drawing and can be checked independently.
//   * FORWARDING = 0 (the CPI-comparison build) must force all three selects to
//     2'b00; hazard_unit.v then stalls on every RAW hazard instead.
//
//   assign fwd_a = (FORWARDING == 0)                      ? 2'b00 :
//                  (mem_reg_we && mem_rd != 0 &&
//                   mem_rd == ex_rs1)                     ? 2'b10 :
//                  (wb_reg_we  && wb_rd  != 0 &&
//                   wb_rd  == ex_rs1)                     ? 2'b01 : 2'b00;
//   ... same shape for fwd_b (ex_rs2) and fwd_c (ex_rs2).
//
// Naming note: `mem_*` are the EX/MEM register outputs (the instruction now in
// MEM), `wb_*` are the MEM/WB register outputs (the instruction now in WB).
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

    output wire [1:0] fwd_a,        // ALU operand A (rs1)
    output wire [1:0] fwd_b,        // ALU operand B (rs2, pre-immediate mux)
    output wire [1:0] fwd_c         // store data (rs2 of sb/sh/sw)
);

    // ---- STEP 4 STUB: no forwarding at all -------------------------------
    assign fwd_a = 2'b00;
    assign fwd_b = 2'b00;
    assign fwd_c = 2'b00;

    // Keep the (as yet unused) inputs and parameter referenced so that lint and
    // elaboration do not prune the port list step 5 depends on.
    // verilator lint_off UNUSED
    wire _unused = (FORWARDING != 0) & mem_reg_we & wb_reg_we &
                   (|ex_rs1) & (|ex_rs2) & (|mem_rd) & (|wb_rd);
    // verilator lint_on UNUSED

endmodule
