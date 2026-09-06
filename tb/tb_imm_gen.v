`timescale 1ns / 1ps
//=============================================================================
// tb_imm_gen.v -- self-checking testbench for rtl/imm_gen.v
//
// Two independent stimulus sources:
//
//  1. HARDCODED GOLDENS -- a handful of instruction words whose immediates were
//     worked out by hand from the RISC-V spec.  They exist so the test cannot
//     silently "pass" on a missing or empty vector file, and so a bug in
//     tools/gen_imm_vectors.py cannot mask a bug in the RTL.
//
//  2. VECTOR FILE tb/vectors/imm_gen_vectors.hex, produced by
//     `python tools/gen_imm_vectors.py`.  Layout: word 0 = vector count N,
//     then N triples <inst> <imm_sel> <expected imm>.  Expected values come
//     from the golden-reference ISS decoder, never from a second Verilog-style
//     bit shuffle.
//
// Prints one MISMATCH line per failing check, then exactly one
//   PASS: tb_imm_gen (<n> vectors)      or
//   FAIL: tb_imm_gen (<n> mismatches)
// as required by docs/INTERFACES.md Section 7.
//
// Run: sim/run.sh tb_imm_gen   (CWD = repo root, so the relative path works)
//=============================================================================

module tb_imm_gen;

    // Must be >= 1 + 3*vectors and match MEM_WORDS in tools/gen_imm_vectors.py
    localparam integer VEC_MEM_WORDS = 16384;
    localparam VEC_FILE = "tb/vectors/imm_gen_vectors.hex";

    reg [31:0] vecmem [0:VEC_MEM_WORDS-1];

    reg  [31:0] inst;
    reg  [2:0]  imm_sel;
    wire [31:0] imm;

    integer errors;
    integer checks;
    integer nvec;
    integer i;
    integer base;
    reg [31:0] selword;

    imm_gen dut (
        .inst    (inst),
        .imm_sel (imm_sel),
        .imm     (imm)
    );

    // One combinational check: drive, settle, compare.
    task check;
        input [31:0] w;
        input [2:0]  s;
        input [31:0] e;
        begin
            inst    = w;
            imm_sel = s;
            #1;
            checks = checks + 1;
            if (imm !== e) begin
                errors = errors + 1;
                $display("MISMATCH inst=%08x sel=%0d got=%08x exp=%08x",
                         w, s, imm, e);
            end
        end
    endtask

    initial begin
        errors = 0;
        checks = 0;
        inst    = 32'h00000000;
        imm_sel = 3'd0;

        // -------------------------------------------------------------------
        // 1. Hand-verified goldens (independent of the generator)
        // -------------------------------------------------------------------
        // I: inst[31:20] sign-extended
        check(32'h80020183, 3'd0, 32'hfffff800); // lb  x3, -2048(x4)  min I
        check(32'h7ff00093, 3'd0, 32'h000007ff); // addi x1, x0, 2047  max I
        check(32'h00000013, 3'd0, 32'h00000000); // nop
        check(32'h41f35513, 3'd0, 32'h0000041f); // srai x10,x6,31 -> raw field
        check(32'h01f51513, 3'd0, 32'h0000001f); // slli x10,x10,31

        // S: {inst[31:25], inst[11:7]} sign-extended
        check(32'hfe32afa3, 3'd1, 32'hffffffff); // sw x3, -1(x5)
        check(32'h7e112fa3, 3'd1, 32'h000007ff); // sh x1, 2047(x2)

        // B: the classic split-field format
        check(32'hfe208ee3, 3'd2, 32'hfffffffc); // beq x1,x2,-4
        check(32'h7e105fe3, 3'd2, 32'h00000ffe); // bge x0,x1,4094
                                                 //   (inst[7]=1, inst[31]=0)
        check(32'h80004063, 3'd2, 32'hfffff000); // blt x0,x0,-4096 (min B)

        // U: inst[31:12] << 12
        check(32'hfffff2b7, 3'd3, 32'hfffff000); // lui x5, 0xfffff
        check(32'h7ffff137, 3'd3, 32'h7ffff000); // lui x2, 0x7ffff (max)

        // J: the other split-field format
        check(32'h8000006f, 3'd4, 32'hfff00000); // jal x0, -1048576 (min J)
        check(32'h001000ef, 3'd4, 32'h00000800); // jal x1, 2048  (inst[20]=1)
        check(32'h0000106f, 3'd4, 32'h00001000); // jal x0, 4096
                                                 //   (inst[19:12]!=0, [30:21]=0)

        // Z: CSR zimm, zero-extended (never sign-extended)
        check(32'h30045073, 3'd5, 32'h00000008); // csrrwi x0, mstatus, 8
        check(32'h342ff773, 3'd5, 32'h0000001f); // csrrci x14, mcause, 31

        // Reserved selectors
        check(32'hffffffff, 3'd6, 32'h00000000);
        check(32'hffffffff, 3'd7, 32'h00000000);

        if (errors != 0) begin
            $display("NOTE: hardcoded golden checks already failed (%0d)",
                     errors);
        end

        // -------------------------------------------------------------------
        // 2. Generated vectors
        // -------------------------------------------------------------------
        for (i = 0; i < VEC_MEM_WORDS; i = i + 1) begin
            vecmem[i] = 32'hxxxxxxxx;
        end

        $readmemh(VEC_FILE, vecmem);

        if (vecmem[0] === 32'hxxxxxxxx) begin
            $display("ERROR: could not read %0s (empty or missing)", VEC_FILE);
            $display("FAIL: tb_imm_gen (vector file not loaded)");
            $finish;
        end

        nvec = vecmem[0];
        if (nvec <= 0 || (1 + 3 * nvec) > VEC_MEM_WORDS) begin
            $display("ERROR: bad vector count %0d in %0s", nvec, VEC_FILE);
            $display("FAIL: tb_imm_gen (bad vector count)");
            $finish;
        end

        for (i = 0; i < nvec; i = i + 1) begin
            base = 1 + 3 * i;
            selword = vecmem[base+1];
            check(vecmem[base], selword[2:0], vecmem[base+2]);
        end

        // -------------------------------------------------------------------
        // 3. Verdict -- exactly one PASS/FAIL line
        // -------------------------------------------------------------------
        if (errors == 0) begin
            $display("PASS: tb_imm_gen (%0d vectors)", checks);
        end else begin
            $display("FAIL: tb_imm_gen (%0d mismatches)", errors);
        end
        $finish;
    end

endmodule
