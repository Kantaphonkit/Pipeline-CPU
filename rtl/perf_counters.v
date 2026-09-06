`timescale 1ns/1ps

// perf_counters.v -- free-running performance counters. See docs/INTERFACES.md §8.8.
// All counters clear on rst; cycles increments every non-reset cycle; the
// others increment when their respective pulse input is 1. This module stays
// dumb: cpu_top is responsible for gating the pulses (e.g. once `done`).
module perf_counters (
    input  wire        clk,
    input  wire        rst,
    input  wire        retire,
    input  wire        lu_stall,
    input  wire        flush,
    input  wire        bht_pred,
    input  wire        bht_miss,
    output reg  [31:0] cycles,
    output reg  [31:0] insns,
    output reg  [31:0] lu_stalls,
    output reg  [31:0] flushes,
    output reg  [31:0] bht_preds,
    output reg  [31:0] bht_misses
);

    always @(posedge clk) begin
        if (rst) begin
            cycles     <= 32'b0;
            insns      <= 32'b0;
            lu_stalls  <= 32'b0;
            flushes    <= 32'b0;
            bht_preds  <= 32'b0;
            bht_misses <= 32'b0;
        end else begin
            cycles <= cycles + 32'd1;
            if (retire)   insns      <= insns      + 32'd1;
            if (lu_stall) lu_stalls  <= lu_stalls  + 32'd1;
            if (flush)    flushes    <= flushes    + 32'd1;
            if (bht_pred) bht_preds  <= bht_preds  + 32'd1;
            if (bht_miss) bht_misses <= bht_misses + 32'd1;
        end
    end

endmodule
