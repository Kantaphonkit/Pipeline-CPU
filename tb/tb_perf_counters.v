`timescale 1ns/1ps

// tb_perf_counters -- self-checking testbench for rtl/perf_counters.v.
// See docs/INTERFACES.md §8.8. Definition used here: cycles counts every
// posedge clk with rst=0 (rst forces all counters to 0 that cycle,
// regardless of pulse inputs).
module tb_perf_counters;

    reg  clk, rst;
    reg  retire, lu_stall, flush, bht_pred, bht_miss;
    wire [31:0] cycles, insns, lu_stalls, flushes, bht_preds, bht_misses;

    integer checks;
    integer failures;
    integer i;

    perf_counters dut (
        .clk(clk), .rst(rst),
        .retire(retire), .lu_stall(lu_stall), .flush(flush),
        .bht_pred(bht_pred), .bht_miss(bht_miss),
        .cycles(cycles), .insns(insns), .lu_stalls(lu_stalls),
        .flushes(flushes), .bht_preds(bht_preds), .bht_misses(bht_misses)
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

        // ---- reset clears all, even while pulses are asserted ----
        rst = 1;
        retire = 1; lu_stall = 1; flush = 1; bht_pred = 1; bht_miss = 1;
        @(negedge clk);
        @(posedge clk);
        #1;
        chk(cycles,     32'd0, "reset: cycles");
        chk(insns,      32'd0, "reset: insns");
        chk(lu_stalls,  32'd0, "reset: lu_stalls");
        chk(flushes,    32'd0, "reset: flushes");
        chk(bht_preds,  32'd0, "reset: bht_preds");
        chk(bht_misses, 32'd0, "reset: bht_misses");

        @(negedge clk);
        @(posedge clk);
        #1;
        chk(cycles, 32'd0, "reset held a 2nd cycle: cycles still 0");

        // ---- release reset, drive known pulse counts over 50 cycles ----
        // retire on 30 cycles, lu_stall on 7, flush on 4, bht_pred on 12, bht_miss on 3.
        rst = 0;
        for (i = 0; i < 50; i = i + 1) begin
            @(negedge clk);
            retire   = (i < 30) ? 1'b1 : 1'b0;
            lu_stall = (i < 7)  ? 1'b1 : 1'b0;
            flush    = (i < 4)  ? 1'b1 : 1'b0;
            bht_pred = (i < 12) ? 1'b1 : 1'b0;
            bht_miss = (i < 3)  ? 1'b1 : 1'b0;
            @(posedge clk);
        end
        #1;

        chk(cycles,     32'd50, "cycles after 50 cycles");
        chk(insns,      32'd30, "insns (retire pulses)");
        chk(lu_stalls,  32'd7,  "lu_stalls (lu_stall pulses)");
        chk(flushes,    32'd4,  "flushes (flush pulses)");
        chk(bht_preds,  32'd12, "bht_preds (bht_pred pulses)");
        chk(bht_misses, 32'd3,  "bht_misses (bht_miss pulses)");

        // ---- reset again mid-stream clears everything ----
        rst = 1;
        retire = 0; lu_stall = 0; flush = 0; bht_pred = 0; bht_miss = 0;
        @(negedge clk);
        @(posedge clk);
        #1;
        chk(cycles,     32'd0, "post-run reset: cycles");
        chk(insns,      32'd0, "post-run reset: insns");
        chk(lu_stalls,  32'd0, "post-run reset: lu_stalls");
        chk(flushes,    32'd0, "post-run reset: flushes");
        chk(bht_preds,  32'd0, "post-run reset: bht_preds");
        chk(bht_misses, 32'd0, "post-run reset: bht_misses");

        if (failures == 0) begin
            $display("PASS: tb_perf_counters (%0d checks)", checks);
        end else begin
            $display("FAIL: tb_perf_counters (%0d failures)", failures);
        end
        $finish;
    end

endmodule
