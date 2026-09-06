`timescale 1ns/1ps

// tb_smoke — trivial testbench used only to prove the sim/run.sh + sim/run.ps1 flow.
// Instantiates nothing; toggles a clock a few cycles then reports PASS.
module tb_smoke;

    reg clk;
    integer i;

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
        end
        $display("PASS: tb_smoke");
        $finish;
    end

endmodule
