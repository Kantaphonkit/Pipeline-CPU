`timescale 1ns/1ps
//=============================================================================
// csr.v -- machine-mode CSR file, trap entry and mret.
//
// Lives in the EX stage.  Everything is single-cycle: the read value presented
// on csr_rdata is the PRE-write architectural value, and the modified value is
// committed on the same posedge.  A CSR instruction and the instruction behind
// it are therefore never in conflict -- the younger one reaches EX a cycle
// later and reads the already-updated register, so no CSR interlock is needed
// (this is why `csrw mepc, t0` immediately followed by `mret` works).
//
// Implemented CSRs (everything else reads 0 and ignores writes):
//
//   name     addr    implemented bits
//   mstatus  0x300   MIE = bit 3, MPIE = bit 7 ; all other bits read 0
//   mie      0x304   MEIE = bit 11 only
//   mtvec    0x305   BASE = bits [31:2]; bits [1:0] always 00 (direct mode)
//   mepc     0x341   bits [31:2]; bits [1:0] always 00
//   mcause   0x342   all 32 bits, hardware- and software-writable
//
// CSR instruction semantics (csr_op = funct3[1:0]):
//   2'b01 RW  new = src                (csrrw / csrrwi -- always writes)
//   2'b10 RS  new = old |  src         (csrrs / csrrsi)
//   2'b11 RC  new = old & ~src         (csrrc / csrrci)
// `src` is the rs1 value or the zero-extended zimm; control.v already decides
// whether the write side happens at all (csr_we = 0 for csrrs/csrrc with
// rs1 = x0 or zimm = 0), and rd = x0 does not suppress the write side.
//
// Trap entry (`trap`, raised by cpu_top for the instruction in EX):
//   mepc   <- trap_pc (the faulting / interrupted PC, low 2 bits forced 0)
//   mcause <- trap_cause      (11 for ecall from M-mode, 0x8000000B for an
//                              external interrupt)
//   MPIE   <- MIE ; MIE <- 0
//   cpu_top redirects the PC to mtvec.
// The trapping instruction does NOT retire; a synchronous trap leaves mepc
// pointing AT the ecall, so the handler must add 4 before mret or it re-traps
// forever.  An external interrupt leaves mepc at the not-yet-executed
// instruction, and the handler must NOT add 4.
//
// mret:  MIE <- MPIE ; MPIE <- 1 ; cpu_top redirects the PC to mepc.
//
// STEP 7 TODO (external interrupts): the `irq` input and the `irq_pending`
// qualification below are already correct, but cpu_top deliberately does NOT
// use irq_pending yet -- it raises `trap` only for ecall.  Step 7 turns the
// interrupt on by ORing irq_pending into cpu_top's trap condition (with
// trap_cause = 32'h8000000B and trap_pc = the EX-stage PC) and by squashing the
// interrupted instruction the same way ecall is squashed today.  Nothing in
// this file has to change.
//
// Verilog-2001, synthesizable.
//=============================================================================

module csr (
    input  wire        clk,
    input  wire        rst,

    // ---- CSR instruction port (EX stage) ----
    input  wire        csr_en,        // a CSR instruction is in EX (read side)
    input  wire        csr_we,        // its write side actually happens
    input  wire [11:0] csr_addr,
    input  wire [1:0]  csr_op,        // funct3[1:0]: 01 RW, 10 RS, 11 RC
    input  wire [31:0] csr_wsrc,      // rs1 value (forwarded) or zimm
    output wire [31:0] csr_rdata,     // pre-write value, 0 for unimplemented

    // ---- trap / mret port (EX stage) ----
    input  wire        trap,          // take a trap this cycle
    input  wire [31:0] trap_pc,       // EX-stage PC of the faulting instruction
    input  wire [31:0] trap_cause,
    input  wire        mret,          // an mret is retiring in EX

    // ---- exported state for the PC-select mux ----
    output wire [31:0] mtvec_o,
    output wire [31:0] mepc_o,

    // ---- external interrupt (wired now, used from step 7) ----
    input  wire        irq,
    output wire        irq_pending
);

    // ---- CSR addresses ----------------------------------------------------
    localparam [11:0] CSR_MSTATUS = 12'h300;
    localparam [11:0] CSR_MIE     = 12'h304;
    localparam [11:0] CSR_MTVEC   = 12'h305;
    localparam [11:0] CSR_MEPC    = 12'h341;
    localparam [11:0] CSR_MCAUSE  = 12'h342;

    localparam [1:0] OP_RW = 2'b01;
    localparam [1:0] OP_RS = 2'b10;
    localparam [1:0] OP_RC = 2'b11;

    // ---- architectural state (names are the testbench contract) -----------
    reg        mstatus_mie;
    reg        mstatus_mpie;
    reg        mie_meie;
    reg [31:0] mtvec;
    reg [31:0] mepc;
    reg [31:0] mcause;

    assign mtvec_o = mtvec;
    assign mepc_o  = mepc;

    // ---- read: assembled architectural view -------------------------------
    reg [31:0] rdata_r;
    always @(*) begin
        case (csr_addr)
            CSR_MSTATUS: rdata_r = {24'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
            CSR_MIE:     rdata_r = {20'b0, mie_meie, 11'b0};
            CSR_MTVEC:   rdata_r = {mtvec[31:2], 2'b00};
            CSR_MEPC:    rdata_r = {mepc[31:2], 2'b00};
            CSR_MCAUSE:  rdata_r = mcause;
            default:     rdata_r = 32'b0;      // unimplemented: reads 0
        endcase
    end

    assign csr_rdata = csr_en ? rdata_r : 32'b0;

    // ---- read-modify-write value ------------------------------------------
    reg [31:0] wval;
    always @(*) begin
        case (csr_op)
            OP_RW:   wval = csr_wsrc;
            OP_RS:   wval = rdata_r |  csr_wsrc;
            OP_RC:   wval = rdata_r & ~csr_wsrc;
            default: wval = rdata_r;           // csr_op = 00 never reaches here
        endcase
    end

    // ---- external interrupt qualification (used from step 7) --------------
    assign irq_pending = irq & mstatus_mie & mie_meie;

    // ---- write side -------------------------------------------------------
    // Priority: trap > mret > CSR instruction.  They are mutually exclusive in
    // practice (one instruction occupies EX, and cpu_top suppresses csr_we for
    // a squashed instruction), but the priority makes the intent explicit and
    // keeps step 7 safe when an interrupt squashes a CSR instruction in EX.
    always @(posedge clk) begin
        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_meie     <= 1'b0;
            mtvec        <= 32'b0;
            mepc         <= 32'b0;
            mcause       <= 32'b0;
        end else if (trap) begin
            mepc         <= {trap_pc[31:2], 2'b00};
            mcause       <= trap_cause;
            mstatus_mpie <= mstatus_mie;
            mstatus_mie  <= 1'b0;
        end else if (mret) begin
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
        end else if (csr_we) begin
            case (csr_addr)
                CSR_MSTATUS: begin
                    mstatus_mie  <= wval[3];
                    mstatus_mpie <= wval[7];
                end
                CSR_MIE:    mie_meie <= wval[11];
                CSR_MTVEC:  mtvec    <= {wval[31:2], 2'b00};
                CSR_MEPC:   mepc     <= {wval[31:2], 2'b00};
                CSR_MCAUSE: mcause   <= wval;
                default:    ;                  // unimplemented: write ignored
            endcase
        end
    end

endmodule
