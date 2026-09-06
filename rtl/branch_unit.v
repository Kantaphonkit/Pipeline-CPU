`timescale 1ns/1ps

// branch_unit.v -- combinational branch-condition evaluation.
// See docs/INTERFACES.md §8.4. funct3: 000 beq, 001 bne, 100 blt, 101 bge,
// 110 bltu, 111 bgeu; others -> 0.
module branch_unit (
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    input  wire [2:0]  funct3,
    output wire        taken
);

    reg taken_r;

    always @(*) begin
        case (funct3)
            3'b000:  taken_r = (rs1 == rs2);                       // beq
            3'b001:  taken_r = (rs1 != rs2);                       // bne
            3'b100:  taken_r = ($signed(rs1) <  $signed(rs2));     // blt
            3'b101:  taken_r = ($signed(rs1) >= $signed(rs2));     // bge
            3'b110:  taken_r = (rs1 <  rs2);                       // bltu
            3'b111:  taken_r = (rs1 >= rs2);                       // bgeu
            default: taken_r = 1'b0;
        endcase
    end

    assign taken = taken_r;

endmodule
