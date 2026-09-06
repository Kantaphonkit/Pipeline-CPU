`timescale 1ns/1ps
//=============================================================================
// cpu_top.v -- RV32I 5-stage in-order pipeline (IF -> ID -> EX -> MEM -> WB).
//
// Build step 4: the complete datapath, PC-select mux, CSR/trap/mret path and
// commit-trace/perf ports are wired.  The hazard logic is NOT: forward_unit.v
// and hazard_unit.v are stubs that drive their outputs inactive, so there is no
// forwarding, no load-use interlock and no flushing of wrong-path instructions.
// Step 5 fills those two modules in; every signal they need is already routed
// here and this file changes only to connect the perf pulses.
//
// Stage summary
//   IF   pc.v + PC-select mux + imem.v (synchronous read; the instruction word
//        appears in ID).  if_id.v carries pc and valid alongside it.
//   ID   control.v / alu_ctrl.v / imm_gen.v decode, regfile read (with the
//        WB->ID internal bypass), jal target and redirect.
//   EX   forwarding muxes, alu.v, branch_unit.v, branch/jalr resolution,
//        csr.v read-modify-write, ecall trap entry and mret redirect.
//   MEM  dmem.v (synchronous write / synchronous read).
//   WB   write-back mux (ALU|PC+4|CSR result vs. load data) -> regfile,
//        commit-trace port, retire pulse for the performance counters.
//
// PC-select priority (highest first)
//   reset -> trap (EX, mtvec) -> mret (EX, mepc) -> taken branch / jalr (EX)
//         -> jal (ID) -> BHT prediction (IF, step 7) -> PC+4
// A redirect overrides a stall: the instruction that raised the stall is being
// killed anyway, so `fetch_en` uses (redirect | ~stall) and every pipeline
// register gives flush priority over stall.
//
// Result-mux note: the ALU / PC+4 / CSR choice is made in EX and travels down
// as EX/MEM.res, so that the EX/MEM forwarding source is the value the
// instruction actually writes back (the link address for jal/jalr, the old CSR
// value for csrr*) and not the raw ALU output.  WB then only selects between
// EX/MEM.res and the load data.
//
// Illegal instructions execute as NOPs (control.v zeroes the whole control
// word).  They stay `valid` but carry an `illegal` flag, and retire/trace are
// qualified with `valid && !illegal`, so they are neither counted nor traced.
//
// Halt: `ebreak` retires normally (traced and counted) and then sets the sticky
// `done` flag, which freezes the whole pipeline so nothing behind it commits and
// the trace ends exactly at the ebreak line.
//=============================================================================

module cpu_top #(
    parameter FORWARDING = 1,          // 0 = disable forwarding (stall instead)
    parameter BHT_ENABLE = 1,          // 0 = always predict not-taken (step 7)
    parameter IMEM_INIT  = "prog.hex", // $readmemh file
    parameter DMEM_INIT  = ""          // "" = leave DMEM zero
) (
    input  wire        clk,
    input  wire        rst,            // synchronous, active-high
    input  wire        irq,            // external interrupt, level (step 7)
    output wire        done,           // ebreak retired (sticky)
    // commit-trace port (WB stage)
    output wire        trace_valid,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_insn,
    output wire        trace_rd_we,
    output wire [4:0]  trace_rd,
    output wire [31:0] trace_rd_val,
    output wire        trace_mem_we,
    output wire [31:0] trace_mem_addr,
    output wire [31:0] trace_mem_val,
    // performance counters (free-running from reset)
    output wire [31:0] perf_cycles,
    output wire [31:0] perf_insns,
    output wire [31:0] perf_lu_stalls,
    output wire [31:0] perf_flushes,
    output wire [31:0] perf_bht_pred,
    output wire [31:0] perf_bht_miss
);

    // ---- opcode constants (only needed for the rs1/rs2 usage decode) -------
    localparam [6:0] OP_R      = 7'h33;
    localparam [6:0] OP_IARITH = 7'h13;
    localparam [6:0] OP_LOAD   = 7'h03;
    localparam [6:0] OP_STORE  = 7'h23;
    localparam [6:0] OP_BRANCH = 7'h63;
    localparam [6:0] OP_JALR   = 7'h67;

    localparam [1:0] WB_ALU = 2'd0;
    localparam [1:0] WB_MEM = 2'd1;
    localparam [1:0] WB_PC4 = 2'd2;
    localparam [1:0] WB_CSR = 2'd3;

    localparam [31:0] NOP_INST = 32'h00000013;   // addi x0, x0, 0

    localparam [31:0] CAUSE_ECALL_M = 32'd11;    // ecall from machine mode

    //=========================================================================
    // forward declarations (Verilog-2001 has no implicit nets for these)
    //=========================================================================
    wire        stall, flush_if, flush_id;
    wire        halt;
    wire        redirect, redirect_ex, redirect_id;
    wire [31:0] wb_data;
    wire [31:0] mtvec_val, mepc_val;
    wire [31:0] dmem_rdata, dmem_wmask_data;
    wire        trap_taken, mret_taken, br_taken, jalr_taken, jal_taken;

    //=========================================================================
    // IF stage
    //=========================================================================
    wire [31:0] pc_q;
    reg  [31:0] pc_next;
    wire [31:0] if_inst;

    // A redirect overrides a stall; `halt` freezes the machine after ebreak.
    wire fetch_en = ~halt & (redirect | ~stall);

    pc u_pc (
        .clk     (clk),
        .rst     (rst),
        .en      (fetch_en),
        .pc_next (pc_next),
        .pc_q    (pc_q)
    );

    imem #(.INIT(IMEM_INIT)) u_imem (
        .clk  (clk),
        .en   (fetch_en),
        .addr (pc_q),
        .inst (if_inst)
    );

    // IF/ID: pc + valid.  The instruction word itself is held in imem's own
    // output register (see if_id.v header), which is clocked by the same
    // `fetch_en`, so the two halves stay in step.
    wire [31:0] if_id_pc;
    wire        if_id_valid;

    if_id u_if_id (
        .clk     (clk),
        .rst     (rst),
        .stall   (~fetch_en),
        .flush   (flush_if & ~halt),
        .pc_d    (pc_q),
        .valid_d (1'b1),
        .pc_q    (if_id_pc),
        .valid_q (if_id_valid)
    );

    //=========================================================================
    // ID stage
    //=========================================================================
    // A flushed / not-yet-filled IF/ID slot decodes as a NOP regardless of what
    // imem's output register happens to hold.
    wire [31:0] id_inst = if_id_valid ? if_inst : NOP_INST;

    wire [6:0]  id_opcode   = id_inst[6:0];
    wire [2:0]  id_funct3   = id_inst[14:12];
    wire [6:0]  id_funct7   = id_inst[31:25];
    wire [4:0]  id_rs1      = id_inst[19:15];
    wire [4:0]  id_rs2      = id_inst[24:20];
    wire [4:0]  id_rd       = id_inst[11:7];
    wire [11:0] id_csr_addr = id_inst[31:20];

    wire        id_reg_we, id_alu_src_a, id_alu_src_b;
    wire [2:0]  id_imm_sel;
    wire [1:0]  id_alu_class;
    wire        id_mem_re, id_mem_we;
    wire [1:0]  id_wb_sel;
    wire        id_branch, id_jal, id_jalr;
    wire        id_csr_en, id_csr_we, id_csr_imm;
    wire        id_mret, id_ecall, id_ebreak, id_illegal;

    control u_control (
        .opcode    (id_opcode),
        .funct3    (id_funct3),
        .funct7    (id_funct7),
        .rs1       (id_rs1),
        .csr_addr  (id_csr_addr),
        .reg_we    (id_reg_we),
        .alu_src_a (id_alu_src_a),
        .alu_src_b (id_alu_src_b),
        .imm_sel   (id_imm_sel),
        .alu_class (id_alu_class),
        .mem_re    (id_mem_re),
        .mem_we    (id_mem_we),
        .wb_sel    (id_wb_sel),
        .branch    (id_branch),
        .jal       (id_jal),
        .jalr      (id_jalr),
        .csr_en    (id_csr_en),
        .csr_we    (id_csr_we),
        .csr_imm   (id_csr_imm),
        .mret      (id_mret),
        .ecall     (id_ecall),
        .ebreak    (id_ebreak),
        .illegal   (id_illegal)
    );

    wire [31:0] id_imm;
    imm_gen u_imm_gen (
        .inst    (id_inst),
        .imm_sel (id_imm_sel),
        .imm     (id_imm)
    );

    wire [3:0] id_alu_op;
    alu_ctrl u_alu_ctrl (
        .alu_class  (id_alu_class),
        .funct3     (id_funct3),
        .funct7_b30 (id_inst[30]),
        .alu_op     (id_alu_op)
    );

    // Register file: asynchronous read with the mandatory WB->ID bypass; the
    // write port is driven by the WB stage below.
    wire [31:0] id_rs1_val, id_rs2_val;
    wire        wb_reg_we;
    wire [4:0]  wb_rd_addr;

    regfile u_regfile (
        .clk    (clk),
        .we     (wb_reg_we),
        .waddr  (wb_rd_addr),
        .wdata  (wb_data),
        .raddr1 (id_rs1),
        .raddr2 (id_rs2),
        .rdata1 (id_rs1_val),
        .rdata2 (id_rs2_val)
    );

    // Does this instruction really read rs1 / rs2?  Only used by the hazard
    // unit (stubbed in step 4) -- lui/auipc/jal/csr*i/ecall/ebreak/mret must not
    // be treated as consumers or they would stall on stale register numbers.
    wire id_uses_rs1 = (id_opcode == OP_R)      || (id_opcode == OP_IARITH) ||
                       (id_opcode == OP_LOAD)   || (id_opcode == OP_STORE)  ||
                       (id_opcode == OP_BRANCH) || (id_opcode == OP_JALR)   ||
                       (id_csr_en && !id_csr_imm);
    wire id_uses_rs2 = (id_opcode == OP_R)      || (id_opcode == OP_STORE)  ||
                       (id_opcode == OP_BRANCH);

    // jal resolves here: target = PC + J-immediate (1-bubble redirect).
    wire [31:0] id_jal_target = if_id_pc + id_imm;
    assign jal_taken   = if_id_valid & id_jal;
    assign redirect_id = jal_taken;

    //=========================================================================
    // ID/EX
    //=========================================================================
    wire        ex_valid, ex_illegal;
    wire [31:0] ex_pc, ex_inst;
    wire [4:0]  ex_rs1_addr, ex_rs2_addr, ex_rd_addr;
    wire [31:0] ex_rs1_val, ex_rs2_val, ex_imm;
    wire [3:0]  ex_alu_op;
    wire        ex_alu_src_a, ex_alu_src_b;
    wire [2:0]  ex_funct3;
    wire        ex_branch, ex_jalr;
    wire        ex_mem_re, ex_mem_we;
    wire        ex_reg_we;
    wire [1:0]  ex_wb_sel;
    wire        ex_csr_en, ex_csr_we, ex_csr_imm;
    wire [11:0] ex_csr_addr;
    wire        ex_mret, ex_ecall, ex_ebreak;

    id_ex u_id_ex (
        .clk         (clk),
        .rst         (rst),
        .stall       (halt),
        .flush       (~halt & (stall | flush_id)),

        .valid_d     (if_id_valid),
        .illegal_d   (id_illegal),
        .pc_d        (if_id_pc),
        .inst_d      (id_inst),
        .rs1_addr_d  (id_rs1),
        .rs2_addr_d  (id_rs2),
        .rd_addr_d   (id_rd),
        .rs1_val_d   (id_rs1_val),
        .rs2_val_d   (id_rs2_val),
        .imm_d       (id_imm),
        .alu_op_d    (id_alu_op),
        .alu_src_a_d (id_alu_src_a),
        .alu_src_b_d (id_alu_src_b),
        .funct3_d    (id_funct3),
        .branch_d    (id_branch),
        .jalr_d      (id_jalr),
        .mem_re_d    (id_mem_re),
        .mem_we_d    (id_mem_we),
        .reg_we_d    (id_reg_we),
        .wb_sel_d    (id_wb_sel),
        .csr_en_d    (id_csr_en),
        .csr_we_d    (id_csr_we),
        .csr_imm_d   (id_csr_imm),
        .csr_addr_d  (id_csr_addr),
        .mret_d      (id_mret),
        .ecall_d     (id_ecall),
        .ebreak_d    (id_ebreak),

        .valid_q     (ex_valid),
        .illegal_q   (ex_illegal),
        .pc_q        (ex_pc),
        .inst_q      (ex_inst),
        .rs1_addr_q  (ex_rs1_addr),
        .rs2_addr_q  (ex_rs2_addr),
        .rd_addr_q   (ex_rd_addr),
        .rs1_val_q   (ex_rs1_val),
        .rs2_val_q   (ex_rs2_val),
        .imm_q       (ex_imm),
        .alu_op_q    (ex_alu_op),
        .alu_src_a_q (ex_alu_src_a),
        .alu_src_b_q (ex_alu_src_b),
        .funct3_q    (ex_funct3),
        .branch_q    (ex_branch),
        .jalr_q      (ex_jalr),
        .mem_re_q    (ex_mem_re),
        .mem_we_q    (ex_mem_we),
        .reg_we_q    (ex_reg_we),
        .wb_sel_q    (ex_wb_sel),
        .csr_en_q    (ex_csr_en),
        .csr_we_q    (ex_csr_we),
        .csr_imm_q   (ex_csr_imm),
        .csr_addr_q  (ex_csr_addr),
        .mret_q      (ex_mret),
        .ecall_q     (ex_ecall),
        .ebreak_q    (ex_ebreak)
    );

    //=========================================================================
    // EX stage
    //=========================================================================
    wire        mem_valid, mem_illegal;
    wire [31:0] mem_pc, mem_inst;
    wire [4:0]  mem_rd_addr;
    wire        mem_reg_we;
    wire [1:0]  mem_wb_sel;
    wire [31:0] mem_res, mem_store_data;
    wire [2:0]  mem_funct3;
    wire        mem_mem_re, mem_mem_we, mem_ebreak;

    wire        wbs_valid, wbs_illegal;
    wire [31:0] wbs_pc, wbs_inst;
    wire [4:0]  wbs_rd_addr;
    wire        wbs_reg_we;
    wire [1:0]  wbs_wb_sel;
    wire [31:0] wbs_res, wbs_mem_val;
    wire        wbs_mem_we, wbs_ebreak;

    wire [1:0] fwd_a, fwd_b, fwd_c;

    forward_unit #(.FORWARDING(FORWARDING)) u_forward (
        .ex_rs1     (ex_rs1_addr),
        .ex_rs2     (ex_rs2_addr),
        .mem_reg_we (mem_reg_we),
        .mem_rd     (mem_rd_addr),
        .wb_reg_we  (wbs_reg_we),
        .wb_rd      (wbs_rd_addr),
        .fwd_a      (fwd_a),
        .fwd_b      (fwd_b),
        .fwd_c      (fwd_c)
    );

    // Forwarding sources: EX/MEM.res (already the written-back value) and the
    // WB-stage write data (covers loads, whose data only exists in WB).
    wire [31:0] fwd_src_mem = mem_res;
    wire [31:0] fwd_src_wb  = wb_data;

    wire [31:0] ex_a_val = (fwd_a == 2'b10) ? fwd_src_mem :
                           (fwd_a == 2'b01) ? fwd_src_wb  : ex_rs1_val;
    wire [31:0] ex_b_val = (fwd_b == 2'b10) ? fwd_src_mem :
                           (fwd_b == 2'b01) ? fwd_src_wb  : ex_rs2_val;
    // store data takes its own select so the sb/sh/sw path is explicit
    wire [31:0] ex_store_data = (fwd_c == 2'b10) ? fwd_src_mem :
                                (fwd_c == 2'b01) ? fwd_src_wb  : ex_rs2_val;

    wire [31:0] alu_a = ex_alu_src_a ? ex_pc  : ex_a_val;   // PC only for auipc
    wire [31:0] alu_b = ex_alu_src_b ? ex_imm : ex_b_val;
    wire [31:0] alu_y;

    alu u_alu (
        .a      (alu_a),
        .b      (alu_b),
        .alu_op (ex_alu_op),
        .y      (alu_y)
    );

    // Branch condition uses the forwarded register values, not the ALU.
    wire branch_cond;
    branch_unit u_branch_unit (
        .rs1    (ex_a_val),
        .rs2    (ex_b_val),
        .funct3 (ex_funct3),
        .taken  (branch_cond)
    );

    // ---- CSR file (read-modify-write in EX) -------------------------------
    wire [31:0] csr_rdata;
    wire [31:0] csr_wsrc = ex_csr_imm ? ex_imm : ex_a_val;
    wire        csr_irq_pending;   // step 7: OR into trap_taken

    csr u_csr (
        .clk         (clk),
        .rst         (rst),
        .csr_en      (ex_valid & ex_csr_en),
        .csr_we      (ex_valid & ex_csr_we & ~trap_taken & ~halt),
        .csr_addr    (ex_csr_addr),
        .csr_op      (ex_funct3[1:0]),
        .csr_wsrc    (csr_wsrc),
        .csr_rdata   (csr_rdata),
        .trap        (trap_taken & ~halt),
        .trap_pc     (ex_pc),
        .trap_cause  (CAUSE_ECALL_M),
        .mret        (mret_taken & ~halt),
        .mtvec_o     (mtvec_val),
        .mepc_o      (mepc_val),
        .irq         (irq),
        .irq_pending (csr_irq_pending)
    );

    // ---- control-flow resolution in EX ------------------------------------
    // TODO(step 7): trap_taken = ex_valid & (ex_ecall | csr_irq_pending), with
    // trap_cause = 32'h8000000B and the interrupted instruction squashed the
    // same way ecall is squashed here.
    assign trap_taken = ex_valid & ex_ecall;
    assign mret_taken = ex_valid & ex_mret;
    assign br_taken   = ex_valid & ex_branch & branch_cond;
    assign jalr_taken = ex_valid & ex_jalr;

    assign redirect_ex = trap_taken | mret_taken | br_taken | jalr_taken;
    assign redirect    = redirect_ex | redirect_id;

    wire [31:0] ex_branch_target = ex_pc + ex_imm;              // PC + B-imm
    wire [31:0] ex_jalr_target   = alu_y & ~32'h0000_0001;      // (rs1+imm) & ~1

    // ---- PC-select mux (priority order documented in the header) ----------
    always @(*) begin
        if (trap_taken)      pc_next = mtvec_val;
        else if (mret_taken) pc_next = mepc_val;
        else if (br_taken)   pc_next = ex_branch_target;
        else if (jalr_taken) pc_next = ex_jalr_target;
        else if (jal_taken)  pc_next = id_jal_target;
        // TODO(step 7): else if (bht_predict_taken) pc_next = bht_target;
        else                 pc_next = pc_q + 32'd4;
    end

    // ---- EX result select (ALU / PC+4 / CSR); see header note -------------
    reg [31:0] ex_res;
    always @(*) begin
        case (ex_wb_sel)
            WB_PC4:  ex_res = ex_pc + 32'd4;     // jal / jalr link
            WB_CSR:  ex_res = csr_rdata;         // csrr* old value
            default: ex_res = alu_y;             // WB_ALU, and the load address
        endcase
    end

    // The trapping instruction is squashed, not retired (trace and perf must
    // not see it).  Everything younger is killed by the flush logic in step 5.
    wire flush_ex = trap_taken & ~halt;

    //=========================================================================
    // EX/MEM
    //=========================================================================
    ex_mem u_ex_mem (
        .clk          (clk),
        .rst          (rst),
        .stall        (halt),
        .flush        (flush_ex),

        .valid_d      (ex_valid),
        .illegal_d    (ex_illegal),
        .pc_d         (ex_pc),
        .inst_d       (ex_inst),
        .rd_addr_d    (ex_rd_addr),
        .reg_we_d     (ex_valid & ex_reg_we),
        .wb_sel_d     (ex_wb_sel),
        .res_d        (ex_res),
        .store_data_d (ex_store_data),
        .funct3_d     (ex_funct3),
        .mem_re_d     (ex_valid & ex_mem_re),
        .mem_we_d     (ex_valid & ex_mem_we),
        .ebreak_d     (ex_ebreak),

        .valid_q      (mem_valid),
        .illegal_q    (mem_illegal),
        .pc_q         (mem_pc),
        .inst_q       (mem_inst),
        .rd_addr_q    (mem_rd_addr),
        .reg_we_q     (mem_reg_we),
        .wb_sel_q     (mem_wb_sel),
        .res_q        (mem_res),
        .store_data_q (mem_store_data),
        .funct3_q     (mem_funct3),
        .mem_re_q     (mem_mem_re),
        .mem_we_q     (mem_mem_we),
        .ebreak_q     (mem_ebreak)
    );

    //=========================================================================
    // MEM stage
    //=========================================================================
    dmem #(.INIT(DMEM_INIT)) u_dmem (
        .clk        (clk),
        .we         (mem_mem_we & ~halt),
        .re         (mem_mem_re & ~halt),
        .addr       (mem_res),
        .funct3     (mem_funct3),
        .wdata      (mem_store_data),
        .rdata      (dmem_rdata),
        .wmask_data (dmem_wmask_data)
    );

    //=========================================================================
    // MEM/WB
    //=========================================================================
    mem_wb u_mem_wb (
        .clk       (clk),
        .rst       (rst),
        .stall     (halt),
        .flush     (1'b0),

        .valid_d   (mem_valid),
        .illegal_d (mem_illegal),
        .pc_d      (mem_pc),
        .inst_d    (mem_inst),
        .rd_addr_d (mem_rd_addr),
        .reg_we_d  (mem_reg_we),
        .wb_sel_d  (mem_wb_sel),
        .res_d     (mem_res),
        .mem_we_d  (mem_mem_we),
        .mem_val_d (dmem_wmask_data),
        .ebreak_d  (mem_ebreak),

        .valid_q   (wbs_valid),
        .illegal_q (wbs_illegal),
        .pc_q      (wbs_pc),
        .inst_q    (wbs_inst),
        .rd_addr_q (wbs_rd_addr),
        .reg_we_q  (wbs_reg_we),
        .wb_sel_q  (wbs_wb_sel),
        .res_q     (wbs_res),
        .mem_we_q  (wbs_mem_we),
        .mem_val_q (wbs_mem_val),
        .ebreak_q  (wbs_ebreak)
    );

    //=========================================================================
    // WB stage
    //=========================================================================
    assign wb_data    = (wbs_wb_sel == WB_MEM) ? dmem_rdata : wbs_res;
    assign wb_rd_addr = wbs_rd_addr;
    assign wb_reg_we  = wbs_valid & wbs_reg_we & (wbs_rd_addr != 5'd0) & ~halt;

    // Retirement: a valid, non-illegal instruction leaving WB while running.
    wire wb_retire = wbs_valid & ~wbs_illegal & ~halt;

    // ---- sticky halt on ebreak --------------------------------------------
    reg done_r;
    always @(posedge clk) begin
        if (rst)
            done_r <= 1'b0;
        else if (wbs_valid & wbs_ebreak)
            done_r <= 1'b1;
    end

    assign halt = done_r;
    assign done = done_r;

    //=========================================================================
    // Commit-trace port (driven from the MEM/WB register outputs)
    //=========================================================================
    assign trace_valid    = wb_retire;
    assign trace_pc       = wbs_pc;
    assign trace_insn     = wbs_inst;
    assign trace_rd_we    = wb_retire & wbs_reg_we & (wbs_rd_addr != 5'd0);
    assign trace_rd       = wbs_rd_addr;
    assign trace_rd_val   = wb_data;
    assign trace_mem_we   = wb_retire & wbs_mem_we;
    assign trace_mem_addr = wbs_res;                 // effective byte address
    assign trace_mem_val  = wbs_mem_val;             // masked to width

    //=========================================================================
    // Performance counters
    //=========================================================================
    // TODO(step 5): .lu_stall(stall & ~halt) and
    //               .flush(redirect & ~halt) once hazard_unit.v is real.
    // TODO(step 7): .bht_pred / .bht_miss from bht.v.
    perf_counters u_perf (
        .clk        (clk),
        .rst        (rst),
        .retire     (wb_retire),
        .lu_stall   (1'b0),
        .flush      (1'b0),
        .bht_pred   (1'b0),
        .bht_miss   (1'b0),
        .cycles     (perf_cycles),
        .insns      (perf_insns),
        .lu_stalls  (perf_lu_stalls),
        .flushes    (perf_flushes),
        .bht_preds  (perf_bht_pred),
        .bht_misses (perf_bht_miss)
    );

    //=========================================================================
    // Hazard unit (STEP 4 STUB -- drives stall / flush_if / flush_id to 0)
    //=========================================================================
    hazard_unit #(.FORWARDING(FORWARDING)) u_hazard (
        .id_valid    (if_id_valid),
        .id_rs1      (id_rs1),
        .id_rs2      (id_rs2),
        .id_uses_rs1 (id_uses_rs1),
        .id_uses_rs2 (id_uses_rs2),
        .ex_valid    (ex_valid),
        .ex_mem_re   (ex_mem_re),
        .ex_reg_we   (ex_reg_we),
        .ex_rd       (ex_rd_addr),
        .mem_valid   (mem_valid),
        .mem_reg_we  (mem_reg_we),
        .mem_rd      (mem_rd_addr),
        .redirect_ex (redirect_ex),
        .redirect_id (redirect_id),
        .stall       (stall),
        .flush_if    (flush_if),
        .flush_id    (flush_id)
    );

    // Signals that only step 7 consumes; referenced here so elaboration keeps
    // them and so the BHT_ENABLE parameter is not flagged as unused.
    // verilator lint_off UNUSED
    wire _unused_step7 = csr_irq_pending & (BHT_ENABLE != 0) &
                         mem_illegal & (|ex_rs2_addr);
    // verilator lint_on UNUSED

endmodule
