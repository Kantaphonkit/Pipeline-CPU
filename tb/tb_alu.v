`timescale 1ns/1ps

// tb_alu — directed + random self-checking testbench for rtl/alu.v.
// See CLAUDE.md task spec for the required directed cases.
module tb_alu;

    reg  [31:0] a, b;
    reg  [3:0]  alu_op;
    wire [31:0] y;

    integer mismatches;
    integer cases;
    integer i;
    reg [31:0] exp;
    integer seed;
    reg [31:0] ra, rb;
    reg [3:0]  rop;

    alu dut (
        .a(a),
        .b(b),
        .alu_op(alu_op),
        .y(y)
    );

    // Behavioural reference model.
    function [31:0] ref_alu;
        input [31:0] ra;
        input [31:0] rb;
        input [3:0]  rop;
        begin
            case (rop)
                4'd0:  ref_alu = ra + rb;
                4'd1:  ref_alu = ra - rb;
                4'd2:  ref_alu = ra << rb[4:0];
                4'd3:  ref_alu = ($signed(ra) < $signed(rb)) ? 32'd1 : 32'd0;
                4'd4:  ref_alu = (ra < rb) ? 32'd1 : 32'd0;
                4'd5:  ref_alu = ra ^ rb;
                4'd6:  ref_alu = ra >> rb[4:0];
                4'd7:  ref_alu = $signed(ra) >>> rb[4:0];
                4'd8:  ref_alu = ra | rb;
                4'd9:  ref_alu = ra & rb;
                4'd10: ref_alu = rb;
                default: ref_alu = 32'b0;
            endcase
        end
    endfunction

    task check;
        input [31:0] ta;
        input [31:0] tb_;
        input [3:0]  top;
        begin
            a = ta;
            b = tb_;
            alu_op = top;
            #1;
            exp = ref_alu(ta, tb_, top);
            cases = cases + 1;
            if (y !== exp) begin
                mismatches = mismatches + 1;
                $display("MISMATCH op=%0d a=%08x b=%08x got=%08x exp=%08x", top, ta, tb_, y, exp);
            end
        end
    endtask

    initial begin
        mismatches = 0;
        cases = 0;

        // ---- Directed cases, per op ----
        for (i = 0; i <= 10; i = i + 1) begin
            check(32'h00000000, 32'h00000000, i[3:0]); // 0/0
            check(32'hffffffff, 32'hffffffff, i[3:0]); // all-ones
            check(32'h80000000, 32'h00000001, i[3:0]); // sign edge
            check(32'h7fffffff, 32'h00000001, i[3:0]); // overflow edge
        end

        // SUB 0 - 1
        check(32'h00000000, 32'h00000001, 4'd1);

        // SLT / SLTU with (-1, 1), (1, -1), (0x80000000, 0x7fffffff)
        check(32'hffffffff, 32'h00000001, 4'd3);
        check(32'hffffffff, 32'h00000001, 4'd4);
        check(32'h00000001, 32'hffffffff, 4'd3);
        check(32'h00000001, 32'hffffffff, 4'd4);
        check(32'h80000000, 32'h7fffffff, 4'd3);
        check(32'h80000000, 32'h7fffffff, 4'd4);

        // SLL/SRL/SRA with shamt 0, 1, 31
        check(32'h00000001, 32'd0,  4'd2);
        check(32'h00000001, 32'd1,  4'd2);
        check(32'h00000001, 32'd31, 4'd2);
        check(32'h80000000, 32'd0,  4'd6);
        check(32'h80000000, 32'd1,  4'd6);
        check(32'h80000000, 32'd31, 4'd6);
        check(32'h80000000, 32'd0,  4'd7);
        check(32'h80000000, 32'd1,  4'd7);
        check(32'h80000000, 32'd31, 4'd7);

        // b with bits above [4:0] set: b = 0xffffffe1 must shift by 1 only (0xe1 & 0x1f = 1)
        check(32'h00000002, 32'hffffffe1, 4'd2); // SLL
        check(32'h80000000, 32'hffffffe1, 4'd6); // SRL
        check(32'h80000000, 32'hffffffe1, 4'd7); // SRA

        // SRA of 0x80000000 by 31 = 0xffffffff
        check(32'h80000000, 32'd31, 4'd7);
        // SRL of 0x80000000 by 31 = 1
        check(32'h80000000, 32'd31, 4'd6);

        // PASSB ignores a
        check(32'hdeadbeef, 32'h12345678, 4'd10);
        check(32'h00000000, 32'hffffffff, 4'd10);

        // ops 11..15 give 0
        for (i = 11; i <= 15; i = i + 1) begin
            check(32'hdeadbeef, 32'h12345678, i[3:0]);
        end

        // ---- 5000 random cases, fixed seed ----
        seed = 32'hC0FFEE01;
        for (i = 0; i < 5000; i = i + 1) begin
            ra  = $random(seed);
            rb  = $random(seed);
            rop = $random(seed) & 4'hF;
            check(ra, rb, rop);
        end

        if (mismatches == 0) begin
            $display("PASS: tb_alu (%0d cases)", cases);
        end else begin
            $display("FAIL: tb_alu (%0d mismatches)", mismatches);
        end
        $finish;
    end

endmodule
