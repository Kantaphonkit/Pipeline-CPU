`timescale 1ns/1ps
//=============================================================================
// bht.v -- 64-entry branch history table of 2-bit saturating counters.
//
// Direction predictor only: there is no branch target buffer, because the
// target of a conditional branch is PC + B-immediate and the pipeline already
// computes that in ID from information it has anyway.  This table therefore
// answers exactly one question -- "taken or not?" -- and the datapath supplies
// the address.
//
// Indexing: `pc[7:2]`, i.e. bits 2..7 of the byte address, giving 64 entries
// that cover a 256-byte window of instruction space.  Addresses 256 bytes
// apart alias onto the same counter; that is the intended (and cheap) cost of
// an untagged table, and it degrades accuracy, never correctness.
//
// Counter FSM (Smith 2-bit saturating):
//
//        taken            taken            taken
//    +----------+     +----------+     +----------+
//    |          v     |          v     |          v
//   00 <---- 01 <---- 10 <---- 11 ----+
//   ^  n.t.   ^  n.t.  |  n.t.  |  n.t.
//   |         |        |        |
//   +---------+--------+--------+   (00 and 11 are the saturating ends)
//
//    00 strongly not taken     10 weakly taken
//    01 weakly not taken       11 strongly taken
//
//  prediction = state[1].  Reset puts every entry in 01 (weakly not taken),
//  which makes an unvisited branch behave exactly like the no-predictor
//  machine and lets a loop's backward branch reach "taken" after a single
//  observation.
//
// Timing: the lookup is combinational so it can happen in IF in parallel with
// the instruction fetch; cpu_top registers `pred_state` into IF/ID so the
// prediction travels with the instruction.  The update is synchronous and is
// driven from EX with the resolved outcome.  A lookup and an update of the
// same index in the same cycle is allowed: the lookup sees the old value.
// That costs at most one extra mispredict on a tight self-recurring branch
// and needs no bypass.
//
// ENABLE = 0 turns the predictor off: every lookup answers "not taken" and no
// counter is written, so the machine reverts bit-for-bit to the static
// not-taken behaviour used as the baseline in the performance comparison.
// With the outputs constant, synthesis prunes the whole array away.
//
// Verilog-2001, synthesizable, no vendor primitives.
//=============================================================================

module bht #(
    parameter ENABLE = 1
) (
    input  wire        clk,
    input  wire        rst,

    // ---- lookup (IF stage, combinational) ----
    input  wire [31:0] lookup_pc,
    output wire        pred_taken,
    output wire [1:0]  pred_state,

    // ---- update (EX stage, synchronous) ----
    input  wire        update_en,
    input  wire [31:0] update_pc,
    input  wire        update_taken
);

    localparam ENTRIES  = 64;
    localparam WEAK_NT  = 2'b01;

    reg [1:0] ctr [0:ENTRIES-1];

    wire [5:0] lookup_idx = lookup_pc[7:2];
    wire [5:0] update_idx = update_pc[7:2];

    // ---- lookup ------------------------------------------------------------
    reg [1:0] lookup_state;
    always @(*) lookup_state = ctr[lookup_idx];

    assign pred_state = (ENABLE != 0) ? lookup_state : WEAK_NT;
    assign pred_taken = (ENABLE != 0) ? lookup_state[1] : 1'b0;

    // ---- saturating update -------------------------------------------------
    reg [1:0] update_state;
    always @(*) update_state = ctr[update_idx];

    reg [1:0] update_next;
    always @(*) begin
        if (update_taken)
            update_next = (update_state == 2'b11) ? 2'b11 : (update_state + 2'b01);
        else
            update_next = (update_state == 2'b00) ? 2'b00 : (update_state - 2'b01);
    end

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1)
                ctr[i] <= WEAK_NT;
        end else if ((ENABLE != 0) && update_en) begin
            ctr[update_idx] <= update_next;
        end
    end

endmodule
