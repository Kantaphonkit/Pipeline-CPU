`timescale 1ns/1ps
//=============================================================================
// hazard_unit.v -- pipeline interlock and control-flow flush generation.
//
// STATUS: build step 4 STUB.  The port list below is final; the body drives
// stall = flush_if = flush_id = 0, which is exactly what step 4 wants: no
// interlock, no flushing, so a NOP-padded straight-line program executes on a
// bare 5-stage datapath.  Build step 5 fills the always block in -- cpu_top
// already wires every signal the real logic needs and does not have to change.
//
// Consequences of the stub (documented so step-4 results are not mistaken for
// bugs):
//   * A taken branch / jalr / trap / mret still redirects the PC, but the two
//     instructions already in ID and IF behind it are NOT killed and DO commit.
//     Only programs whose control transfers are followed by >= 2 NOPs (>= 1 for
//     jal, which resolves in ID) produce architecturally correct results.
//   * A load followed within 2 instructions by a consumer of its rd reads a
//     stale register value.  Same NOP-padding requirement.
//   * The commit trace therefore contains wrong-path instructions; the program
//     testbench is run with +NOTRACE in step 4 for that reason.
//
// Rules that step 5 must implement (docs/DESIGN.md section 6):
//
//   Load-use interlock (FORWARDING = 1):
//     stall = id_valid && ex_valid && ex_mem_re && ex_rd != 0 &&
//             ((id_uses_rs1 && id_rs1 == ex_rd) ||
//              (id_uses_rs2 && id_rs2 == ex_rd))
//     Effect: hold PC and IF/ID, bubble ID/EX for one cycle.
//
//   FORWARDING = 0 (CPI comparison build): no bypasses exist, so stall on ANY
//   RAW against a pending write in EX/MEM or MEM/WB (up to two cycles):
//     stall = id_valid && ( (ex_reg_we  && ex_rd  != 0 && matches) ||
//                           (mem_reg_we && mem_rd != 0 && matches) )
//   The WB->ID bypass inside regfile.v covers the third distance, so no third
//   stall class is needed.
//
//   Flushes (independent of FORWARDING):
//     redirect_ex = taken branch | jalr | trap | mret, resolved in EX
//                -> flush_if = 1 and flush_id = 1   (2 bubbles)
//     redirect_id = jal, resolved in ID
//                -> flush_if = 1                    (1 bubble)
//     A redirect OVERRIDES a stall: the stalling instruction in ID is being
//     killed anyway, so cpu_top gives flush priority over stall in every
//     pipeline register (rst || flush) before (!stall).
//
//   flush_if clears the IF/ID register (valid = 0 -> ID decodes a NOP);
//   flush_id clears the ID/EX register (all control bits 0).
//
// Naming note: `ex_*` are ID/EX register outputs (instruction in EX), `mem_*`
// are EX/MEM register outputs (instruction in MEM).
//=============================================================================

module hazard_unit #(
    parameter FORWARDING = 1
) (
    // instruction currently in ID
    input  wire        id_valid,
    input  wire [4:0]  id_rs1,
    input  wire [4:0]  id_rs2,
    input  wire        id_uses_rs1,     // decoder says rs1 is a real source
    input  wire        id_uses_rs2,     // decoder says rs2 is a real source
    // instruction currently in EX (ID/EX register)
    input  wire        ex_valid,
    input  wire        ex_mem_re,       // it is a load
    input  wire        ex_reg_we,
    input  wire [4:0]  ex_rd,
    // instruction currently in MEM (EX/MEM register)
    input  wire        mem_valid,
    input  wire        mem_reg_we,
    input  wire [4:0]  mem_rd,
    // control-flow redirects
    input  wire        redirect_ex,     // taken branch / jalr / trap / mret
    input  wire        redirect_id,     // jal

    output wire        stall,           // hold PC + IF/ID, bubble ID/EX
    output wire        flush_if,        // clear IF/ID to a bubble
    output wire        flush_id         // clear ID/EX to a bubble
);

    // ---- STEP 4 STUB: no interlock, no flushing --------------------------
    assign stall    = 1'b0;
    assign flush_if = 1'b0;
    assign flush_id = 1'b0;

    // Keep the (as yet unused) inputs and parameter referenced so that lint and
    // elaboration do not prune the port list step 5 depends on.
    // verilator lint_off UNUSED
    wire _unused = (FORWARDING != 0) &
                   id_valid & id_uses_rs1 & id_uses_rs2 & (|id_rs1) & (|id_rs2) &
                   ex_valid & ex_mem_re & ex_reg_we & (|ex_rd) &
                   mem_valid & mem_reg_we & (|mem_rd) &
                   redirect_ex & redirect_id;
    // verilator lint_on UNUSED

endmodule
