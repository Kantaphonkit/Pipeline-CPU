`timescale 1ns/1ps

// pc.v -- program counter register. See docs/INTERFACES.md §8.5.
module pc (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire [31:0] pc_next,
    output reg  [31:0] pc_q
);

    always @(posedge clk) begin
        if (rst)
            pc_q <= 32'b0;
        else if (en)
            pc_q <= pc_next;
    end

endmodule
