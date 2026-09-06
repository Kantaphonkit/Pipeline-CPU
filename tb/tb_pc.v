`timescale 1ns/1ps

// tb_pc -- self-checking testbench for rtl/pc.v.
// Checks: reset -> 0; en=1 loads pc_next; en=0 holds; reset again mid-run -> 0.
module tb_pc;

    reg         clk;
    reg         rst;
    reg         en;
    reg  [31:0] pc_next;
    wire [31:0] pc_q;

    integer checks;
    integer failures;

    pc dut (
        .clk(clk),
        .rst(rst),
        .en(en),
        .pc_next(pc_next),
        .pc_q(pc_q)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task chk;
        input [31:0] got;
        input [31:0] exp;
        input [255:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                failures = failures + 1;
                $display("FAIL check: %0s got=%08x exp=%08x", msg, got, exp);
            end
        end
    endtask

    initial begin
        checks = 0;
        failures = 0;
        rst = 1;
        en = 0;
        pc_next = 32'hDEADBEEF;

        // ---- reset -> 0 ----
        @(posedge clk);
        #1;
        chk(pc_q, 32'h0, "reset holds pc at 0");
        @(posedge clk);
        #1;
        chk(pc_q, 32'h0, "reset still holds pc at 0");

        // ---- en=1 loads pc_next ----
        rst = 0;
        en = 1;
        pc_next = 32'h00000004;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h00000004, "en=1 loads pc_next (1)");

        pc_next = 32'h00000008;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h00000008, "en=1 loads pc_next (2)");

        pc_next = 32'h12345678;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h12345678, "en=1 loads pc_next (3)");

        // ---- en=0 holds ----
        en = 0;
        pc_next = 32'hFFFFFFFF;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h12345678, "en=0 holds pc (1)");
        @(posedge clk);
        #1;
        chk(pc_q, 32'h12345678, "en=0 holds pc (2)");

        // en still 0, pc_next changes again -- must still hold
        pc_next = 32'hCAFEBABE;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h12345678, "en=0 holds pc despite pc_next change");

        // ---- resume with en=1 ----
        en = 1;
        pc_next = 32'h00000100;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h00000100, "en=1 resumes loading");

        // ---- reset again mid-run -> 0 ----
        rst = 1;
        en = 1;
        pc_next = 32'hABCDEF01;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h0, "reset mid-run forces pc to 0 (even with en=1)");
        @(posedge clk);
        #1;
        chk(pc_q, 32'h0, "reset mid-run still 0");

        // release reset, confirm normal operation resumes
        rst = 0;
        pc_next = 32'h00000200;
        @(posedge clk);
        #1;
        chk(pc_q, 32'h00000200, "operation resumes after reset release");

        if (failures == 0) begin
            $display("PASS: tb_pc (%0d checks)", checks);
        end else begin
            $display("FAIL: tb_pc (%0d failures)", failures);
        end
        $finish;
    end

endmodule
