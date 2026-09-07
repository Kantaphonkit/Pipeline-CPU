`timescale 1ns/1ps

// imem.v -- instruction memory, synchronous read with enable (BRAM-inferable).
// See docs/INTERFACES.md §8.6.
module imem #(
    parameter INIT = "asm/smoke.hex"
) (
    input  wire        clk,
    input  wire        en,
    input  wire [31:0] addr,
    output reg  [31:0] inst
);

    // ram_style: force block-RAM (ROM) inference.  Without it Vivado
    // collapses this sparsely-initialised array into LUT logic, which
    // makes the whole synthesis result an artifact of the loaded image
    // rather than a characterisation of the CPU.  The read below is
    // registered, so the attribute is satisfiable.  Simulation-neutral:
    // Verilog-2001 attributes are ignored by xsim.
    (* ram_style = "block" *)
    reg [31:0] mem [0:1023];

    initial $readmemh(INIT, mem);

    always @(posedge clk) begin
        if (en)
            inst <= mem[addr[11:2]];
    end

endmodule
