`timescale 1ns/1ps

// imem.v -- instruction memory, synchronous read with enable (BRAM-inferable).
// See docs/INTERFACES.md §8.6.
module imem #(
    parameter INIT = "asm/smoke.hex"
) (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] addr,
    output reg  [31:0] inst
);

    reg [31:0] mem [0:1023];

    initial $readmemh(INIT, mem);

    always @(posedge clk) begin
        if (en)
            inst <= mem[addr[11:2]];
    end

endmodule
