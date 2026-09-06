`timescale 1ns/1ps

// tb_branch_unit -- self-checking testbench for rtl/branch_unit.v.
// See docs/INTERFACES.md §8.4: funct3 000 beq, 001 bne, 100 blt, 101 bge,
// 110 bltu, 111 bgeu; others (010, 011) -> 0.
module tb_branch_unit;

    reg  [31:0] rs1, rs2;
    reg  [2:0]  funct3;
    wire        taken;

    integer checks;
    integer failures;
    integer fi, pi, ri;
    reg [31:0] seed;

    reg [31:0] a_vec [0:8];
    reg [31:0] b_vec [0:8];

    branch_unit dut (
        .rs1(rs1),
        .rs2(rs2),
        .funct3(funct3),
        .taken(taken)
    );

    // Golden model: same semantics the DUT must implement.
    function exp_taken;
        input [31:0] a;
        input [31:0] b;
        input [2:0]  f3;
        begin
            case (f3)
                3'b000:  exp_taken = (a == b);                     // beq
                3'b001:  exp_taken = (a != b);                     // bne
                3'b100:  exp_taken = ($signed(a) <  $signed(b));   // blt
                3'b101:  exp_taken = ($signed(a) >= $signed(b));   // bge
                3'b110:  exp_taken = (a <  b);                     // bltu
                3'b111:  exp_taken = (a >= b);                     // bgeu
                default: exp_taken = 1'b0;                         // 010, 011
            endcase
        end
    endfunction

    task chk;
        input [31:0] a;
        input [31:0] b;
        input [2:0]  f3;
        begin
            rs1 = a;
            rs2 = b;
            funct3 = f3;
            #1;
            checks = checks + 1;
            if (taken !== exp_taken(a, b, f3)) begin
                failures = failures + 1;
                $display("FAIL check: rs1=%08x rs2=%08x funct3=%03b got=%0d exp=%0d",
                          a, b, f3, taken, exp_taken(a, b, f3));
            end
        end
    endtask

    initial begin
        checks = 0;
        failures = 0;

        a_vec[0] = 32'h00000000; b_vec[0] = 32'h00000000;
        a_vec[1] = 32'h00000001; b_vec[1] = 32'h00000001;
        a_vec[2] = 32'hFFFFFFFF; b_vec[2] = 32'h00000001; // (-1, 1)
        a_vec[3] = 32'h00000001; b_vec[3] = 32'hFFFFFFFF; // (1, -1)
        a_vec[4] = 32'h80000000; b_vec[4] = 32'h7FFFFFFF;
        a_vec[5] = 32'h7FFFFFFF; b_vec[5] = 32'h80000000;
        a_vec[6] = 32'h00000005; b_vec[6] = 32'h00000005;
        a_vec[7] = 32'h00000005; b_vec[7] = 32'h00000006;
        a_vec[8] = 32'h00000006; b_vec[8] = 32'h00000005;

        // ---- directed pairs for all 8 funct3 codes (covers 000/001/100/101/110/111
        //      per the spec table, and 010/011 which must always yield 0) ----
        for (fi = 0; fi < 8; fi = fi + 1) begin
            for (pi = 0; pi < 9; pi = pi + 1) begin
                chk(a_vec[pi], b_vec[pi], fi[2:0]);
            end
        end

        // ---- 2000 random pairs x all 8 funct3 codes ----
        seed = 32'hC0FFEE01;
        for (ri = 0; ri < 2000; ri = ri + 1) begin
            for (fi = 0; fi < 8; fi = fi + 1) begin
                chk($random(seed), $random(seed), fi[2:0]);
            end
        end

        if (failures == 0) begin
            $display("PASS: tb_branch_unit (%0d checks)", checks);
        end else begin
            $display("FAIL: tb_branch_unit (%0d failures)", failures);
        end
        $finish;
    end

endmodule
