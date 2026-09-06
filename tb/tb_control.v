`timescale 1ns / 1ps
//=============================================================================
// tb_control.v -- self-checking testbench for rtl/control.v + rtl/alu_ctrl.v
//
// The two decoders are exercised together, exactly as the ID stage wires them:
// control.v decodes the instruction word, and its alu_class output plus the
// instruction's funct3 and inst[30] drive alu_ctrl.v.  All nineteen decoded
// signals are compared per vector.
//
// Two independent stimulus sources:
//
//  1. HARDCODED GOLDENS -- instruction words and control settings worked out by
//     hand from the RISC-V spec and written out field by field below.  They
//     exist so the test cannot silently "pass" on a missing or truncated vector
//     file, and so a bug in tools/gen_control_table.py cannot mask a bug in the
//     RTL.  They deliberately include the classic decode traps:
//       fff00093  addi x1,x0,-1  -> ADD, never SUB (inst[30] = 1!)
//       40515093  srai x1,x2,5   -> SRA
//       00515093  srli x1,x2,5   -> SRL
//       300025f3  csrrs x11,mstatus,x0  -> csr_we = 0 (rs1 = x0)
//       3000a5f3  csrrs x11,mstatus,x1  -> csr_we = 1
//       300065f3  csrrsi x11,mstatus,0  -> csr_we = 0 (zimm = 0)
//       10500073  wfi -> illegal
//
//  2. VECTOR FILE tb/vectors/control_vectors.hex, produced by
//     `python tools/gen_control_table.py`.  Layout: word 0 = vector count N,
//     then N pairs <instruction word> <expected packed control word>.
//
// Packed control word (must match the LAYOUT table in gen_control_table.py):
//
//     bit    0     reg_we            bit   13     jal
//     bit    1     alu_src_a         bit   14     jalr
//     bit    2     alu_src_b         bit   15     csr_en
//     bits   5:3   imm_sel           bit   16     csr_we
//     bits   7:6   alu_class         bit   17     csr_imm
//     bit    8     mem_re            bit   18     mret
//     bit    9     mem_we            bit   19     ecall
//     bits  11:10  wb_sel            bit   20     ebreak
//     bit   12     branch            bit   21     illegal
//                                    bits  25:22  alu_op
//
// Prints one MISMATCH line per failing field, then exactly one
//   PASS: tb_control (<n> vectors)      or
//   FAIL: tb_control (<n> mismatches)
// as required by docs/INTERFACES.md Section 7.
//
// Run: sim/run.sh tb_control   (CWD = repo root, so the relative path works)
//=============================================================================

module tb_control;

    // Must be >= 1 + 2*vectors and match MEM_WORDS in tools/gen_control_table.py
    localparam integer VEC_MEM_WORDS = 8192;
    localparam VEC_FILE = "tb/vectors/control_vectors.hex";

    reg [31:0] vecmem [0:VEC_MEM_WORDS-1];

    // ---- DUT wiring --------------------------------------------------------
    reg  [31:0] inst;

    wire [6:0]  opcode   = inst[6:0];
    wire [2:0]  funct3   = inst[14:12];
    wire [6:0]  funct7   = inst[31:25];
    wire [4:0]  rs1      = inst[19:15];
    wire [11:0] csr_addr = inst[31:20];

    wire        reg_we, alu_src_a, alu_src_b;
    wire [2:0]  imm_sel;
    wire [1:0]  alu_class;
    wire        mem_re, mem_we;
    wire [1:0]  wb_sel;
    wire        branch, jal, jalr;
    wire        csr_en, csr_we, csr_imm;
    wire        mret, ecall, ebreak, illegal;
    wire [3:0]  alu_op;

    control u_control (
        .opcode    (opcode),
        .funct3    (funct3),
        .funct7    (funct7),
        .rs1       (rs1),
        .csr_addr  (csr_addr),
        .reg_we    (reg_we),
        .alu_src_a (alu_src_a),
        .alu_src_b (alu_src_b),
        .imm_sel   (imm_sel),
        .alu_class (alu_class),
        .mem_re    (mem_re),
        .mem_we    (mem_we),
        .wb_sel    (wb_sel),
        .branch    (branch),
        .jal       (jal),
        .jalr      (jalr),
        .csr_en    (csr_en),
        .csr_we    (csr_we),
        .csr_imm   (csr_imm),
        .mret      (mret),
        .ecall     (ecall),
        .ebreak    (ebreak),
        .illegal   (illegal)
    );

    // Wired the way cpu_top will wire it: class from control, funct3 and
    // inst[30] straight off the instruction word.
    alu_ctrl u_alu_ctrl (
        .alu_class  (alu_class),
        .funct3     (funct3),
        .funct7_b30 (inst[30]),
        .alu_op     (alu_op)
    );

    integer errors;
    integer checks;
    integer nvec;
    integer i;
    integer base;
    reg [31:0] cur_inst;

    // ---- one field comparison ---------------------------------------------
    task cmpf;
        input [8*10:1] name;
        input [3:0]    got;
        input [3:0]    exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("MISMATCH inst=%08x field=%0s got=%0d exp=%0d",
                         cur_inst, name, got, exp);
            end
        end
    endtask

    // ---- one vector: drive, settle, compare every output -------------------
    task check_word;
        input [31:0] w;
        input [31:0] e;
        begin
            cur_inst = w;
            inst     = w;
            #1;
            checks = checks + 1;
            cmpf("reg_we",    {3'b0, reg_we},    {3'b0, e[0]});
            cmpf("alu_src_a", {3'b0, alu_src_a}, {3'b0, e[1]});
            cmpf("alu_src_b", {3'b0, alu_src_b}, {3'b0, e[2]});
            cmpf("imm_sel",   {1'b0, imm_sel},   {1'b0, e[5:3]});
            cmpf("alu_class", {2'b0, alu_class}, {2'b0, e[7:6]});
            cmpf("mem_re",    {3'b0, mem_re},    {3'b0, e[8]});
            cmpf("mem_we",    {3'b0, mem_we},    {3'b0, e[9]});
            cmpf("wb_sel",    {2'b0, wb_sel},    {2'b0, e[11:10]});
            cmpf("branch",    {3'b0, branch},    {3'b0, e[12]});
            cmpf("jal",       {3'b0, jal},       {3'b0, e[13]});
            cmpf("jalr",      {3'b0, jalr},      {3'b0, e[14]});
            cmpf("csr_en",    {3'b0, csr_en},    {3'b0, e[15]});
            cmpf("csr_we",    {3'b0, csr_we},    {3'b0, e[16]});
            cmpf("csr_imm",   {3'b0, csr_imm},   {3'b0, e[17]});
            cmpf("mret",      {3'b0, mret},      {3'b0, e[18]});
            cmpf("ecall",     {3'b0, ecall},     {3'b0, e[19]});
            cmpf("ebreak",    {3'b0, ebreak},    {3'b0, e[20]});
            cmpf("illegal",   {3'b0, illegal},   {3'b0, e[21]});
            cmpf("alu_op",    alu_op,            e[25:22]);
        end
    endtask

    // ---- hand-written golden: every field spelled out ----------------------
    task golden;
        input [31:0] w;
        input        g_reg_we;
        input        g_src_a;
        input        g_src_b;
        input [2:0]  g_imm_sel;
        input [1:0]  g_class;
        input [3:0]  g_alu_op;
        input        g_mem_re;
        input        g_mem_we;
        input [1:0]  g_wb_sel;
        input        g_branch;
        input        g_jal;
        input        g_jalr;
        input        g_csr_en;
        input        g_csr_we;
        input        g_csr_imm;
        input        g_mret;
        input        g_ecall;
        input        g_ebreak;
        input        g_illegal;
        begin
            check_word(w, {6'b0, g_alu_op, g_illegal, g_ebreak, g_ecall,
                           g_mret, g_csr_imm, g_csr_we, g_csr_en, g_jalr,
                           g_jal, g_branch, g_wb_sel, g_mem_we, g_mem_re,
                           g_class, g_imm_sel, g_src_b, g_src_a, g_reg_we});
        end
    endtask

    // ALU opcode names (docs/DESIGN.md Section 4.1)
    localparam [3:0] ADD = 4'd0,  SUB = 4'd1,  SLL = 4'd2,  SLT = 4'd3;
    localparam [3:0] SLTU = 4'd4, XOR = 4'd5,  SRL = 4'd6,  SRA = 4'd7;
    localparam [3:0] OR = 4'd8,   AND = 4'd9,  PASSB = 4'd10;

    initial begin
        errors   = 0;
        checks   = 0;
        inst     = 32'h00000013;         // nop
        cur_inst = 32'h00000013;

        //--------------------------------------------------------------------
        // 1. Hand-verified goldens.  Argument order:
        //      inst, reg_we, src_a, src_b, imm_sel, class, alu_op,
        //      mem_re, mem_we, wb_sel, branch, jal, jalr,
        //      csr_en, csr_we, csr_imm, mret, ecall, ebreak, illegal
        //--------------------------------------------------------------------

        // addi x1, x0, -1 -- inst[30] = 1, MUST still be ADD (classic bug)
        golden(32'hfff00093, 1,0,1, 3'd0, 2'd2, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // andi x7, x8, -2048 -- inst[30] = 0 here, but inst[31] = 1
        golden(32'h80047393, 1,0,1, 3'd0, 2'd2, AND,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // srai x1, x2, 5   -- I-type shift, inst[30] = 1 -> SRA
        golden(32'h40515093, 1,0,1, 3'd0, 2'd2, SRA,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // srli x1, x2, 5   -- I-type shift, inst[30] = 0 -> SRL
        golden(32'h00515093, 1,0,1, 3'd0, 2'd2, SRL,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // add x3, x1, x2
        golden(32'h002081b3, 1,0,0, 3'd0, 2'd1, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // sub x3, x1, x2   -- R-type, inst[30] = 1 -> SUB
        golden(32'h402081b3, 1,0,0, 3'd0, 2'd1, SUB,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // lw x1, -8(x15)
        golden(32'hff87a083, 1,0,1, 3'd0, 2'd0, ADD,   1,0, 2'd1, 0,0,0, 0,0,0, 0,0,0, 0);
        // lbu x9, 2047(x10)
        golden(32'h7ff54483, 1,0,1, 3'd0, 2'd0, ADD,   1,0, 2'd1, 0,0,0, 0,0,0, 0,0,0, 0);
        // sw x1, -4(x2)    -- S immediate, no rd write
        golden(32'hfe112e23, 0,0,1, 3'd1, 2'd0, ADD,   0,1, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // beq x1, x2, -4   -- B immediate, ALU B operand = rs2
        golden(32'hfe208ee3, 0,0,0, 3'd2, 2'd0, ADD,   0,0, 2'd0, 1,0,0, 0,0,0, 0,0,0, 0);
        // bgeu x3, x4, 2046
        golden(32'h7e41ff63, 0,0,0, 3'd2, 2'd0, ADD,   0,0, 2'd0, 1,0,0, 0,0,0, 0,0,0, 0);
        // lui x1, 0x12345  -- PASSB
        golden(32'h123450b7, 1,0,1, 3'd3, 2'd3, PASSB, 0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // auipc x1, 0x12345 -- A operand = PC
        golden(32'h12345097, 1,1,1, 3'd3, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 0);
        // jal x1, 16       -- resolves in ID, writes PC+4
        golden(32'h010000ef, 1,0,1, 3'd4, 2'd0, ADD,   0,0, 2'd2, 0,1,0, 0,0,0, 0,0,0, 0);
        // jalr x1, x2, 4   -- resolves in EX, writes PC+4
        golden(32'h004100e7, 1,0,1, 3'd0, 2'd0, ADD,   0,0, 2'd2, 0,0,1, 0,0,0, 0,0,0, 0);
        // ecall / ebreak / mret
        golden(32'h00000073, 0,0,1, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,1,0, 0);
        golden(32'h00100073, 0,0,1, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,1, 0);
        golden(32'h30200073, 0,0,1, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 1,0,0, 0);
        // csrrs x11, mstatus, x0 -- rs1 = x0 => READ ONLY, csr_we = 0
        golden(32'h300025f3, 1,0,1, 3'd0, 2'd0, ADD,   0,0, 2'd3, 0,0,0, 1,0,0, 0,0,0, 0);
        // csrrs x11, mstatus, x1 -- rs1 != 0 => csr_we = 1
        golden(32'h3000a5f3, 1,0,1, 3'd0, 2'd0, ADD,   0,0, 2'd3, 0,0,0, 1,1,0, 0,0,0, 0);
        // csrrsi x11, mstatus, 0 -- zimm = 0 => csr_we = 0, Z immediate
        golden(32'h300065f3, 1,0,1, 3'd5, 2'd0, ADD,   0,0, 2'd3, 0,0,0, 1,0,1, 0,0,0, 0);
        // csrrsi x11, mstatus, 2 -- zimm != 0 => csr_we = 1
        golden(32'h300165f3, 1,0,1, 3'd5, 2'd0, ADD,   0,0, 2'd3, 0,0,0, 1,1,1, 0,0,0, 0);
        // ---- illegal goldens: illegal = 1, every other output 0 ----
        golden(32'h10500073, 0,0,0, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 1); // wfi
        golden(32'h02000033, 0,0,0, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 1); // add, funct7=0x01
        golden(32'h40004033, 0,0,0, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 1); // xor, funct7=0x20
        golden(32'h40001013, 0,0,0, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 1); // slli, inst[31:25]=0x20
        golden(32'h00003003, 0,0,0, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 1); // load funct3=011
        golden(32'h0000000f, 0,0,0, 3'd0, 2'd0, ADD,   0,0, 2'd0, 0,0,0, 0,0,0, 0,0,0, 1); // fence: opcode 0x0f

        //--------------------------------------------------------------------
        // 2. Generated vectors
        //--------------------------------------------------------------------
        for (i = 0; i < VEC_MEM_WORDS; i = i + 1) begin
            vecmem[i] = 32'hxxxxxxxx;
        end

        $readmemh(VEC_FILE, vecmem);

        if (vecmem[0] === 32'hxxxxxxxx) begin
            $display("ERROR: could not read %0s (empty or missing)", VEC_FILE);
            $display("FAIL: tb_control (vector file not loaded)");
            $finish;
        end

        nvec = vecmem[0];
        if (nvec <= 0 || (1 + 2 * nvec) > VEC_MEM_WORDS) begin
            $display("ERROR: bad vector count %0d in %0s", nvec, VEC_FILE);
            $display("FAIL: tb_control (bad vector count)");
            $finish;
        end
        if (nvec < 500) begin
            // the generator emits >= 8 instances of each of the 46 encodings
            // plus >= 40 illegal words; a much smaller file means a truncated
            // or stale vector image, which must not pass quietly.
            $display("ERROR: only %0d vectors in %0s, expected >= 500",
                     nvec, VEC_FILE);
            $display("FAIL: tb_control (vector file too small)");
            $finish;
        end

        for (i = 0; i < nvec; i = i + 1) begin
            base = 1 + 2 * i;
            check_word(vecmem[base], vecmem[base+1]);
        end

        //--------------------------------------------------------------------
        // 3. Verdict -- exactly one PASS/FAIL line
        //--------------------------------------------------------------------
        if (errors == 0) begin
            $display("PASS: tb_control (%0d vectors)", checks);
        end else begin
            $display("FAIL: tb_control (%0d mismatches)", errors);
        end
        $finish;
    end

endmodule
