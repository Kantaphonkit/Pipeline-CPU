`timescale 1ns/1ps
//=============================================================================
// cpu_top.v -- RV32I 5-stage in-order pipeline (IF -> ID -> EX -> MEM -> WB).
//
// The complete datapath, PC-select mux, CSR/trap/mret path, hazard logic,
// external-interrupt path, branch predictor and commit-trace/perf ports are
// wired.  forward_unit.v supplies the three EX operand bypasses,
// hazard_unit.v the load-use interlock (or, with FORWARDING=0, the
// stall-on-any-RAW rule used for the CPI comparison) and the flush signals for
// every control-flow redirect, and bht.v predicts conditional-branch
// direction.
//
// Stage summary
//   IF   pc.v + PC-select mux + imem.v (synchronous read; the instruction word
//        appears in ID) + bht.v lookup.  if_id.v carries pc, valid and the
//        BHT counter state alongside it.
//   ID   control.v / alu_ctrl.v / imm_gen.v decode, regfile read (with the
//        WB->ID internal bypass), jal target and redirect, and the
//        BHT-predicted-taken branch redirect.
//   EX   forwarding muxes, alu.v, branch_unit.v, branch/jalr resolution and
//        BHT update, csr.v read-modify-write, ecall / external-interrupt trap
//        entry and mret redirect.
//   MEM  dmem.v (synchronous write / synchronous read).
//   WB   write-back mux (ALU|PC+4|CSR result vs. load data) -> regfile,
//        commit-trace port, retire pulse for the performance counters.
//
// PC-select priority (highest first)
//   reset -> trap (EX, mtvec) -> mret (EX, mepc) -> mispredicted branch / jalr
//         (EX) -> jal (ID) -> BHT-predicted-taken branch (ID) -> PC+4
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

    localparam [31:0] CAUSE_ECALL_M     = 32'd11;          // ecall from M-mode
    localparam [31:0] CAUSE_MACHINE_EXT = 32'h8000_000B;  // external interrupt

    //=========================================================================
    // forward declarations (Verilog-2001 has no implicit nets for these)
    //=========================================================================
    wire        stall, flush_if, flush_id;
    wire        halt;
    wire        redirect, redirect_ex, redirect_id;
    wire [31:0] wb_data;
    wire [31:0] mtvec_val, mepc_val;
    wire [31:0] dmem_rdata, dmem_wmask_data;
    wire        trap_taken, mret_taken, br_redirect, jalr_taken, jal_taken;
    wire        irq_taken, bht_taken;
    wire        ebreak_pending;
    wire        branch_cond;
    wire [31:0] trap_cause;
    wire [1:0]  bht_pred_state_if;
    wire        bht_pred_taken_if;   // == bht_pred_state_if[1]; observation only
                                     // (ID reads the state carried in IF/ID)
    wire [31:0] ex_pc;

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

    // Branch history table: looked up in IF with the same PC the instruction
    // memory is reading, so the counter state is available at the IF/ID
    // boundary and travels with the instruction.  Updated from EX with the
    // resolved outcome.
    wire        bht_update_en;
    bht #(.ENABLE(BHT_ENABLE)) u_bht (
        .clk          (clk),
        .rst          (rst),
        .lookup_pc    (pc_q),
        .pred_taken   (bht_pred_taken_if),
        .pred_state   (bht_pred_state_if),
        .update_en    (bht_update_en),
        .update_pc    (ex_pc),
        .update_taken (branch_cond)
    );

    // IF/ID: pc + valid + the BHT counter state.  The instruction word itself
    // is held in imem's own output register (see if_id.v header), which is
    // clocked by the same `fetch_en`, so the halves stay in step.
    wire [31:0] if_id_pc;
    wire        if_id_valid;
    wire [1:0]  if_id_pred_state;

    if_id u_if_id (
        .clk          (clk),
        .rst          (rst),
        .stall        (~fetch_en),
        .flush        (flush_if & ~halt),
        .pc_d         (pc_q),
        .valid_d      (1'b1),
        .pred_state_d (bht_pred_state_if),
        .pc_q         (if_id_pc),
        .valid_q      (if_id_valid),
        .pred_state_q (if_id_pred_state)
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

    // ---- ID-stage redirects: jal, and a BHT-predicted-taken branch --------
    //
    // Both use the same adder: for a `jal` the decoder selected the J
    // immediate, for a conditional branch the B immediate, and both targets
    // are PC + that immediate.  Both cost a single bubble.
    //
    // Both are gated with `~stall`.  An ID redirect forces the fetch enable
    // high, so IF/ID reloads and is then cleared by `flush_if`; if the ID
    // instruction were simultaneously stalled it would also be bubbled out of
    // ID/EX and would exist nowhere -- its register write silently lost.  The
    // rule is "an ID redirect only fires in the cycle the ID instruction
    // actually advances".  A stalled jal or predicted branch simply redirects
    // one cycle later, which costs a cycle and loses nothing.
    //
    // Both are also suppressed inside an ebreak's shadow: the instruction is
    // being flushed anyway, so letting it move the PC would only add a phantom
    // flush event to the performance counters.
    wire [31:0] id_redirect_target = if_id_pc + id_imm;

    wire id_pred_taken = if_id_valid & id_branch & if_id_pred_state[1];

    assign jal_taken   = if_id_valid & id_jal & ~stall & ~ebreak_pending;
    assign bht_taken   = id_pred_taken        & ~stall & ~ebreak_pending;
    assign redirect_id = jal_taken | bht_taken;

    //=========================================================================
    // ID/EX
    //=========================================================================
    wire        ex_valid, ex_illegal;
    wire [31:0] ex_inst;
    wire [4:0]  ex_rs1_addr, ex_rs2_addr, ex_rd_addr;
    wire [31:0] ex_rs1_val, ex_rs2_val, ex_imm;
    wire [3:0]  ex_alu_op;
    wire        ex_alu_src_a, ex_alu_src_b;
    wire [2:0]  ex_funct3;
    wire        ex_branch, ex_jalr, ex_pred_taken;
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
        .pred_taken_d(id_pred_taken),
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
        .pred_taken_q(ex_pred_taken),
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
        .trap_cause  (trap_cause),
        .mret        (mret_taken & ~trap_taken & ~halt),
        .mtvec_o     (mtvec_val),
        .mepc_o      (mepc_val),
        .irq         (irq),
        .irq_pending (csr_irq_pending)
    );

    // ---- traps: external interrupt and ecall ------------------------------
    //
    // Both attach to the instruction in EX, which is squashed rather than
    // retired, with mepc = its PC.  An external interrupt is level-sensitive
    // and qualified inside csr.v by mstatus.MIE and mie.MEIE, so a program
    // that has not enabled interrupts is completely unaffected by `irq` --
    // no trap, no mcause change, no cycle cost.
    //
    // The interrupt is taken only when the EX slot holds a real instruction:
    // mepc must be a genuine PC, never a bubble's zero.  EX is never stalled
    // in this design (the interlock holds PC and IF/ID and bubbles ID/EX), so
    // `ex_valid` is the whole condition.  It is also suppressed inside an
    // ebreak's shadow, where the machine is already draining to a halt.
    //
    // The interrupt OUTRANKS an ecall occupying the same EX slot: mepc points
    // at the ecall, which re-executes after the handler returns.  That matches
    // the reference model, which samples irq at the instruction boundary
    // before decoding, and it is the standard RISC-V ordering.
    assign irq_taken  = ex_valid & csr_irq_pending & ~ebreak_pending;
    assign trap_taken = irq_taken | (ex_valid & ex_ecall);

    assign trap_cause = irq_taken ? CAUSE_MACHINE_EXT : CAUSE_ECALL_M;

    // ---- control-flow resolution in EX ------------------------------------
    assign mret_taken = ex_valid & ex_mret;
    assign jalr_taken = ex_valid & ex_jalr;

    // A conditional branch only redirects when the prediction was WRONG.  With
    // BHT_ENABLE=0 the carried prediction is always 0, so this degenerates to
    // "redirect whenever the branch is taken" -- the static not-taken machine,
    // cycle for cycle.
    wire        ex_branch_valid = ex_valid & ex_branch & ~trap_taken;
    assign      br_redirect     = ex_branch_valid & (ex_pred_taken != branch_cond);

    assign redirect_ex = trap_taken | mret_taken | br_redirect | jalr_taken;
    assign redirect    = redirect_ex | redirect_id;

    // BHT update: the resolved outcome of every conditional branch that
    // actually executes.  A branch squashed by a trap is excluded -- it will
    // re-execute after the handler returns and would otherwise be trained (and
    // counted) twice.
    assign bht_update_en = ex_branch_valid & ~halt;

    // `ebreak` does not redirect the PC, but nothing behind it may commit, so
    // IF/ID and ID/EX are held empty from the moment it reaches EX until the
    // sticky `done` flag freezes the machine three cycles later.  Tracking it
    // through MEM and WB as well (rather than only in EX) keeps the shadow
    // continuous instead of letting a fresh fetch slip in behind it.
    assign ebreak_pending = (ex_valid  & ex_ebreak)  |
                            (mem_valid & mem_ebreak) |
                            (wbs_valid & wbs_ebreak);

    wire [31:0] ex_branch_target = ex_pc + ex_imm;              // PC + B-imm
    wire [31:0] ex_jalr_target   = alu_y & ~32'h0000_0001;      // (rs1+imm) & ~1

    // Where a mispredicted branch has to go: to its target if it turned out to
    // be taken, back to the fall-through if the BHT predicted taken and it was
    // not.  The predicted target is not carried down from ID -- it is exactly
    // this expression, recomputed from the pc and immediate ID/EX already
    // holds, so carrying it would only duplicate 32 flops.
    wire [31:0] ex_correct_target = branch_cond ? ex_branch_target
                                                : (ex_pc + 32'd4);

    // ---- PC-select mux (priority order documented in the header) ----------
    always @(*) begin
        if (trap_taken)       pc_next = mtvec_val;
        else if (mret_taken)  pc_next = mepc_val;
        else if (br_redirect) pc_next = ex_correct_target;
        else if (jalr_taken)  pc_next = ex_jalr_target;
        else if (jal_taken)   pc_next = id_redirect_target;
        else if (bht_taken)   pc_next = id_redirect_target;
        else                  pc_next = pc_q + 32'd4;
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
    // not see it).  Everything younger is killed by hazard_unit.v's flush_if /
    // flush_id, which fire on the same redirect.
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
    // `lu_stall` counts interlock cycles: load-use cycles when FORWARDING=1,
    // and every RAW stall cycle when FORWARDING=0 (that difference is the CPI
    // experiment).  `flush` counts control-flow redirect events -- a taken
    // branch, jalr, jal, ecall trap or mret -- one per event, not per killed
    // slot; the `ebreak` shadow is deliberately not counted, it is not a
    // control-flow misprediction.
    // `bht_pred` counts every conditional branch resolved in EX and `bht_miss`
    // the mispredicted subset, at either BHT_ENABLE setting -- with the
    // predictor off, every taken branch is a "miss", which is exactly the
    // static not-taken baseline the comparison needs.
    perf_counters u_perf (
        .clk        (clk),
        .rst        (rst),
        .retire     (wb_retire),
        .lu_stall   (stall & ~halt),
        .flush      (redirect & ~halt),
        .bht_pred   (ex_branch_valid & ~halt),
        .bht_miss   (br_redirect     & ~halt),
        .cycles     (perf_cycles),
        .insns      (perf_insns),
        .lu_stalls  (perf_lu_stalls),
        .flushes    (perf_flushes),
        .bht_preds  (perf_bht_pred),
        .bht_misses (perf_bht_miss)
    );

    //=========================================================================
    // Hazard unit -- load-use interlock (or the FORWARDING=0 stall-on-any-RAW
    // rule) plus the flush signals for every control-flow redirect.
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
        .ebreak_pending (ebreak_pending),
        .stall       (stall),
        .flush_if    (flush_if),
        .flush_id    (flush_id)
    );

endmodule
