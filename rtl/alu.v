`timescale 1ns/1ps

// alu.v — combinational ALU. See docs/INTERFACES.md §8.2 for the fixed op table.
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] y
);

    always @(*) begin
        case (alu_op)
            4'd0:  y = a + b;                                  // ADD
            4'd1:  y = a - b;                                  // SUB
            4'd2:  y = a << b[4:0];                             // SLL
            4'd3:  y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; // SLT
            4'd4:  y = (a < b) ? 32'd1 : 32'd0;                 // SLTU
            4'd5:  y = a ^ b;                                   // XOR
            4'd6:  y = a >> b[4:0];                             // SRL
            4'd7:  y = $signed(a) >>> b[4:0];                   // SRA
            4'd8:  y = a | b;                                   // OR
            4'd9:  y = a & b;                                   // AND
            4'd10: y = b;                                       // PASSB
            default: y = 32'b0;
        endcase
    end

endmodule
