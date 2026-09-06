`timescale 1ns/1ps

// tb_regfile — self-checking testbench for rtl/regfile.v.
// 10 ns clock period. See CLAUDE.md task spec for the required checks.
module tb_regfile;

    reg         clk;
    reg         we;
    reg  [4:0]  waddr;
    reg  [31:0] wdata;
    reg  [4:0]  raddr1, raddr2;
    wire [31:0] rdata1, rdata2;

    integer checks;
    integer failures;
    integer i;
    reg [31:0] expected [0:31];

    regfile dut (
        .clk(clk),
        .we(we),
        .waddr(waddr),
        .wdata(wdata),
        .raddr1(raddr1),
        .raddr2(raddr2),
        .rdata1(rdata1),
        .rdata2(rdata2)
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
        we = 0;
        waddr = 0;
        wdata = 0;
        raddr1 = 0;
        raddr2 = 0;

        // ---- Write x1..x31 with distinct values on successive posedges ----
        @(negedge clk);
        for (i = 1; i <= 31; i = i + 1) begin
            we = 1;
            waddr = i[4:0];
            wdata = 32'hA5000000 + i * 32'h01010101;
            expected[i] = wdata;
            @(posedge clk);
            #1;
        end
        we = 0;
        @(negedge clk);

        // Read back every register on both ports simultaneously.
        for (i = 1; i <= 31; i = i + 1) begin
            raddr1 = i[4:0];
            raddr2 = 31 - i;
            #1;
            chk(rdata1, expected[i], "readback rdata1");
            if ((31 - i) == 0)
                chk(rdata2, 32'h0, "readback rdata2 (x0)");
            else
                chk(rdata2, expected[31 - i], "readback rdata2");
        end

        // ---- x0: write attempt then read ----
        raddr1 = 0;
        raddr2 = 0;
        we = 1;
        waddr = 0;
        wdata = 32'hdeadbeef;
        #1;
        chk(rdata1, 32'h0, "x0 read port1 during write attempt");
        chk(rdata2, 32'h0, "x0 read port2 during write attempt");
        @(posedge clk);
        #1;
        we = 0;
        raddr1 = 0;
        raddr2 = 0;
        #1;
        chk(rdata1, 32'h0, "x0 after write attempt port1");
        chk(rdata2, 32'h0, "x0 after write attempt port2");

        // Bypass case with waddr=0: we=1, waddr=0, wdata=0xdeadbeef, raddr1=0 -> 0 (not bypassed)
        we = 1;
        waddr = 0;
        wdata = 32'hdeadbeef;
        raddr1 = 0;
        raddr2 = 5; // arbitrary, unrelated
        #1;
        chk(rdata1, 32'h0, "x0 bypass suppressed");
        @(posedge clk);
        #1;
        we = 0;

        // ---- Bypass: waddr=5, wdata=0x12345678, raddr1=5, raddr2=5 before edge ----
        @(negedge clk);
        we = 1;
        waddr = 5;
        wdata = 32'h12345678;
        raddr1 = 5;
        raddr2 = 5;
        #1; // sample combinationally before the clock edge
        chk(rdata1, 32'h12345678, "bypass rdata1 before edge");
        chk(rdata2, 32'h12345678, "bypass rdata2 before edge");
        @(posedge clk);
        #1;
        we = 0;
        #1;
        chk(rdata1, 32'h12345678, "stored rdata1 after edge");
        chk(rdata2, 32'h12345678, "stored rdata2 after edge");
        expected[5] = 32'h12345678;

        // ---- No-write: we=0, waddr=7, wdata=0xffffffff -> x7 unchanged ----
        @(negedge clk);
        we = 0;
        waddr = 7;
        wdata = 32'hffffffff;
        raddr1 = 7;
        raddr2 = 7;
        #1;
        chk(rdata1, expected[7], "no-write x7 unaffected port1 (not wdata)");
        chk(rdata2, expected[7], "no-write x7 unaffected port2 (not wdata)");
        @(posedge clk);
        #1;
        chk(rdata1, expected[7], "no-write x7 unchanged after edge");

        // ---- Two different registers written on consecutive cycles then both read ----
        @(negedge clk);
        we = 1;
        waddr = 10;
        wdata = 32'h11112222;
        @(posedge clk);
        #1;
        expected[10] = 32'h11112222;
        waddr = 20;
        wdata = 32'h33334444;
        @(posedge clk);
        #1;
        expected[20] = 32'h33334444;
        we = 0;
        raddr1 = 10;
        raddr2 = 20;
        #1;
        chk(rdata1, expected[10], "consecutive write reg10");
        chk(rdata2, expected[20], "consecutive write reg20");

        if (failures == 0) begin
            $display("PASS: tb_regfile (%0d checks)", checks);
        end else begin
            $display("FAIL: tb_regfile (%0d failures)", failures);
        end
        $finish;
    end

endmodule
