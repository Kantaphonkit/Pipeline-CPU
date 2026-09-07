`timescale 1ns/1ps

// regfile.v — 32x32 register file. See docs/INTERFACES.md §8.3.
// Asynchronous read with WB->ID internal bypass; synchronous write; x0 hardwired to 0.
module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);

    // ram_style: 32x32 with two asynchronous read ports is a distributed
    // (LUT) RAM.  Without the attribute Vivado has been observed to pack
    // it into a RAMB36, wasting a block RAM the memories need.
    // Simulation-neutral: Verilog-2001 attributes are ignored by xsim.
    (* ram_style = "distributed" *)
    reg [31:0] regs [0:31];

    assign rdata1 = (raddr1 == 5'd0) ? 32'b0 :
                     (we && waddr == raddr1) ? wdata :
                     regs[raddr1];

    assign rdata2 = (raddr2 == 5'd0) ? 32'b0 :
                     (we && waddr == raddr2) ? wdata :
                     regs[raddr2];

    always @(posedge clk) begin
        if (we && waddr != 5'd0) begin
            regs[waddr] <= wdata;
        end
    end

endmodule
