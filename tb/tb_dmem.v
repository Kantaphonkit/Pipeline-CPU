`timescale 1ns/1ps

// tb_dmem -- self-checking testbench for rtl/dmem.v.
// Two instances: dut_empty (INIT="") must read zero everywhere at reset;
// dut_init (INIT="tb/vectors/dmem_init.hex") must read back the fixture
// (words 0..7 = 0x11223344+i, rest zero). Exercises byte/half/word load and
// store lanes, sign/zero extension, address wrap (bits above 11 ignored),
// and the wmask_data trace-port output, on dut_empty.
module tb_dmem;

    reg clk;

    // ---- instance: empty init ----
    reg         we_e, re_e;
    reg  [31:0] addr_e;
    reg  [2:0]  f3_e;
    reg  [31:0] wdata_e;
    wire [31:0] rdata_e;
    wire [31:0] wmask_e;

    // ---- instance: fixture init ----
    reg         we_i, re_i;
    reg  [31:0] addr_i;
    reg  [2:0]  f3_i;
    reg  [31:0] wdata_i;
    wire [31:0] rdata_i;
    wire [31:0] wmask_i;

    integer checks;
    integer failures;
    integer k;
    reg [31:0] captured;

    dmem #(.INIT("")) dut_empty (
        .clk(clk), .we(we_e), .re(re_e), .addr(addr_e), .funct3(f3_e),
        .wdata(wdata_e), .rdata(rdata_e), .wmask_data(wmask_e)
    );

    dmem #(.INIT("tb/vectors/dmem_init.hex")) dut_init (
        .clk(clk), .we(we_i), .re(re_i), .addr(addr_i), .funct3(f3_i),
        .wdata(wdata_i), .rdata(rdata_i), .wmask_data(wmask_i)
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

    // ---- dut_empty helpers ----
    task write_e;
        input [31:0] a;
        input [2:0]  f3;
        input [31:0] wd;
        begin
            @(negedge clk);
            we_e = 1; re_e = 0; addr_e = a; f3_e = f3; wdata_e = wd;
            @(posedge clk);
            #1;
            we_e = 0;
        end
    endtask

    task read_e;
        input [31:0] a;
        input [2:0]  f3;
        begin
            @(negedge clk);
            re_e = 1; we_e = 0; addr_e = a; f3_e = f3;
            @(posedge clk);
            #1;
            captured = rdata_e;
            re_e = 0;
        end
    endtask

    // ---- dut_init helpers ----
    task read_i;
        input [31:0] a;
        input [2:0]  f3;
        begin
            @(negedge clk);
            re_i = 1; we_i = 0; addr_i = a; f3_i = f3;
            @(posedge clk);
            #1;
            captured = rdata_i;
            re_i = 0;
        end
    endtask

    initial begin
        checks = 0;
        failures = 0;
        we_e = 0; re_e = 0; addr_e = 0; f3_e = 0; wdata_e = 0;
        we_i = 0; re_i = 0; addr_i = 0; f3_i = 0; wdata_i = 0;

        // ---- dut_empty: must read zeros everywhere at start ----
        read_e(32'h00000000, 3'b010); chk(captured, 32'h0, "empty init addr 0x000");
        read_e(32'h00000004, 3'b010); chk(captured, 32'h0, "empty init addr 0x004");
        read_e(32'h00000800, 3'b010); chk(captured, 32'h0, "empty init addr 0x800");
        read_e(32'h00000FFC, 3'b010); chk(captured, 32'h0, "empty init addr 0xFFC");

        // ---- dut_init: check words 0..7 read back ----
        for (k = 0; k < 8; k = k + 1) begin
            read_i(k * 4, 3'b010);
            chk(captured, 32'h11223344 + k, "fixture init word readback");
        end

        // ---- sw 0x89abcdef to 0x100; lw -> 0x89abcdef ----
        write_e(32'h100, 3'b010, 32'h89abcdef);
        read_e(32'h100, 3'b010);
        chk(captured, 32'h89abcdef, "sw/lw 0x100");

        // ---- lb sign-extended, little-endian ----
        read_e(32'h100, 3'b000); chk(captured, 32'hffffffef, "lb 0x100");
        read_e(32'h101, 3'b000); chk(captured, 32'hffffffcd, "lb 0x101");
        read_e(32'h102, 3'b000); chk(captured, 32'hffffffab, "lb 0x102");
        read_e(32'h103, 3'b000); chk(captured, 32'hffffff89, "lb 0x103");

        // ---- lbu zero-extended ----
        read_e(32'h100, 3'b100); chk(captured, 32'h000000ef, "lbu 0x100");
        read_e(32'h101, 3'b100); chk(captured, 32'h000000cd, "lbu 0x101");
        read_e(32'h102, 3'b100); chk(captured, 32'h000000ab, "lbu 0x102");
        read_e(32'h103, 3'b100); chk(captured, 32'h00000089, "lbu 0x103");

        // ---- lh sign-extended ----
        read_e(32'h100, 3'b001); chk(captured, 32'hffffcdef, "lh 0x100");
        read_e(32'h102, 3'b001); chk(captured, 32'hffff89ab, "lh 0x102");

        // ---- lhu zero-extended ----
        read_e(32'h100, 3'b101); chk(captured, 32'h0000cdef, "lhu 0x100");
        read_e(32'h102, 3'b101); chk(captured, 32'h000089ab, "lhu 0x102");

        // ---- sb 0x12 at 0x101 -> lw 0x100 = 0x89ab12ef ----
        write_e(32'h101, 3'b000, 32'h00000012);
        read_e(32'h100, 3'b010);
        chk(captured, 32'h89ab12ef, "sb 0x101 then lw 0x100");

        // ---- sh 0x3456 at 0x102 -> lw 0x100 = 0x345612ef ----
        write_e(32'h102, 3'b001, 32'h00003456);
        read_e(32'h100, 3'b010);
        chk(captured, 32'h345612ef, "sh 0x102 then lw 0x100");

        // ---- sw to 0xFFC then lw back ----
        write_e(32'hFFC, 3'b010, 32'hcafebabe);
        read_e(32'hFFC, 3'b010);
        chk(captured, 32'hcafebabe, "sw/lw 0xFFC");

        // ---- address wrap: sw to 0x1100 -> lw 0x100 changed (bits above 11 ignored) ----
        write_e(32'h1100, 3'b010, 32'haaaaaaaa);
        read_e(32'h100, 3'b010);
        chk(captured, 32'haaaaaaaa, "address wrap: sw 0x1100 aliases word at 0x100");

        // ---- wmask_data: masked-to-width store data, not shifted ----
        wdata_e = 32'h89abcdef; f3_e = 3'b000; #1;
        chk(wmask_e, 32'h000000ef, "wmask_data sb");
        f3_e = 3'b001; #1;
        chk(wmask_e, 32'h0000cdef, "wmask_data sh");
        f3_e = 3'b010; #1;
        chk(wmask_e, 32'h89abcdef, "wmask_data sw");

        if (failures == 0) begin
            $display("PASS: tb_dmem (%0d checks)", checks);
        end else begin
            $display("FAIL: tb_dmem (%0d failures)", failures);
        end
        $finish;
    end

endmodule
