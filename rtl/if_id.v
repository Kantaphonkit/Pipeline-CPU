`timescale 1ns/1ps
//=============================================================================
// if_id.v -- IF/ID pipeline register.
//
// Holds the PC and the valid bit of the instruction currently being fetched.
// The *instruction word* itself is NOT registered here: imem.v is a
// synchronous-read memory, so its output register already is the instruction
// half of the IF/ID boundary (see docs/DESIGN.md section 5).  Registering it a
// second time would add a spurious cycle of fetch latency.  cpu_top therefore
// drives imem's `en` with the same enable that clocks this register
// (en = ~stall_q), and squashes the instruction word to a NOP whenever
// valid_q = 0, so a flushed slot decodes as a bubble regardless of what imem's
// output register happens to hold.
//
// It also carries the 2-bit BHT counter state looked up in IF with the same
// PC, so that the prediction travels with the instruction and ID can act on it
// without a second table read.  A bubble carries 2'b00 = strongly not taken,
// which is the safe answer for a slot that holds no branch.
//
// Ports:
//   stall  hold the current contents (pipeline interlock)
//   flush  overwrite with a bubble (valid = 0); has priority over stall,
//          because a control-flow redirect makes any stall the flushed
//          instruction raised moot (docs/DESIGN.md section 5, PC-select rules)
//
// Build step 4 never asserts stall or flush -- the hazard unit is a stub.
// Step 5 fills hazard_unit.v in and these ports come alive unchanged.
//=============================================================================

module if_id (
    input  wire        clk,
    input  wire        rst,
    input  wire        stall,
    input  wire        flush,

    input  wire [31:0] pc_d,
    input  wire        valid_d,
    input  wire [1:0]  pred_state_d,

    output reg  [31:0] pc_q,
    output reg         valid_q,
    output reg  [1:0]  pred_state_q
);

    always @(posedge clk) begin
        if (rst || flush) begin
            pc_q         <= 32'b0;
            valid_q      <= 1'b0;
            pred_state_q <= 2'b00;
        end else if (!stall) begin
            pc_q         <= pc_d;
            valid_q      <= valid_d;
            pred_state_q <= pred_state_d;
        end
    end

endmodule
