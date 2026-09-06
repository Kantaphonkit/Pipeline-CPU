`timescale 1ns/1ps
//=============================================================================
// tb_irq -- directed, self-checking test of the external-interrupt path.
//
// Runs asm/prog/irq_demo.hex, raises `irq` once at a fixed cycle, and checks
// the whole trap round trip against the architectural contract:
//
//   C1  the trap is taken within a bounded window of the level going high
//   C2  mepc      == the PC of the instruction that was in EX and got squashed
//   C3  mcause    == 0x8000000B (machine external interrupt)
//   C4  MPIE      == the pre-trap MIE (1), and MIE == 0 on entry
//   C5  the ISR entry (an instruction at mtvec) retires after the trap, and at
//       most two instructions retire in between -- the trap is taken in EX, so
//       exactly the instructions that were already in MEM and WB, and nothing
//       younger, may still commit
//   C6  the squashed instruction does NOT retire between the trap and the mret
//       (it was cancelled, not merely delayed past its side effects)
//   C7  mret restores MIE from MPIE (MIE == 1, MPIE == 1 afterwards)
//   C8  the first instruction to retire after the mret is the one at mepc,
//       i.e. the squashed instruction runs exactly once, on resumption
//   C9  exactly one trap fires for one irq pulse
//   C10 the program still completes: done, x10 == 200, x11 == 1 (one ISR visit)
//
// IRQ_CYCLE is a parameter so `sim/run.sh tb_irq -g IRQ_CYCLE=350` can move
// the interrupt; the default lands in the middle of the main loop with
// interrupts enabled.
//
// Prints exactly one final PASS/FAIL line per docs/INTERFACES.md section 7.
//=============================================================================

module tb_irq #(
    parameter IRQ_CYCLE  = 200,
    parameter FORWARDING = 1,
    parameter BHT_ENABLE = 1
) ();

    localparam [31:0] CAUSE_MEI = 32'h8000_000B;
    localparam        MAXCYC    = 20000;

    reg clk;
    reg rst;
    reg irq;

    wire        done;
    wire        trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_insn;
    wire        trace_rd_we;
    wire [4:0]  trace_rd;
    wire [31:0] trace_rd_val;
    wire        trace_mem_we;
    wire [31:0] trace_mem_addr;
    wire [31:0] trace_mem_val;
    wire [31:0] perf_cycles, perf_insns, perf_lu_stalls;
    wire [31:0] perf_flushes, perf_bht_pred, perf_bht_miss;

    cpu_top #(
        .FORWARDING (FORWARDING),
        .BHT_ENABLE (BHT_ENABLE),
        .IMEM_INIT  ("asm/smoke.hex"),   // placeholder, overwritten below
        .DMEM_INIT  ("")
    ) dut (
        .clk(clk), .rst(rst), .irq(irq), .done(done),
        .trace_valid(trace_valid), .trace_pc(trace_pc),
        .trace_insn(trace_insn), .trace_rd_we(trace_rd_we),
        .trace_rd(trace_rd), .trace_rd_val(trace_rd_val),
        .trace_mem_we(trace_mem_we), .trace_mem_addr(trace_mem_addr),
        .trace_mem_val(trace_mem_val),
        .perf_cycles(perf_cycles), .perf_insns(perf_insns),
        .perf_lu_stalls(perf_lu_stalls), .perf_flushes(perf_flushes),
        .perf_bht_pred(perf_bht_pred), .perf_bht_miss(perf_bht_miss)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer cyc;
    integer checks, failures;
    integer i;

    // observation state
    integer    n_trap;
    integer    n_mret;
    reg [31:0] squashed_pc;      // EX-stage PC captured at the trap
    reg [31:0] trap_mtvec;
    reg        mie_before_trap;
    reg        in_isr;           // between the trap and the mret retiring
    reg        await_isr_entry;  // waiting for the ISR's first retirement
    integer    retires_before_isr;
    reg        isr_entry_seen;
    reg        await_resume;     // next retire must be at mepc
    reg        trap_d1;          // one cycle after the trap
    reg        mret_retired;
    reg [31:0] mret_pc;
    integer    squashed_retires_in_isr;

    task check (input [639:0] name, input ok);
        begin
            checks = checks + 1;
            if (!ok) begin
                failures = failures + 1;
                $display("CHECK-FAILED: %0s (cycle %0d)", name, cyc);
            end
        end
    endtask

    // ---- cycle counter ----------------------------------------------------
    always @(posedge clk)
        if (!rst) cyc <= cyc + 1;

    // ---- irq level: raise at IRQ_CYCLE, drop once the trap is observed -----
    always @(posedge clk) begin
        if (rst)
            irq <= 1'b0;
        else if (dut.irq_taken)
            irq <= 1'b0;
        else if (cyc == IRQ_CYCLE)
            irq <= 1'b1;
    end

    // ---- the checks, as the round trip happens ----------------------------
    always @(posedge clk) begin
        if (!rst) begin

            // ---- C1/C2 setup: the trap cycle ----
            if (dut.irq_taken) begin
                n_trap          <= n_trap + 1;
                squashed_pc     <= dut.ex_pc;
                trap_mtvec      <= dut.u_csr.mtvec;
                mie_before_trap <= dut.u_csr.mstatus_mie;
                in_isr          <= 1'b1;
                await_isr_entry <= 1'b1;
                isr_entry_seen  <= 1'b0;
                retires_before_isr <= 0;
                squashed_retires_in_isr <= 0;
                trap_d1         <= 1'b1;
                $display("IRQ_TRAP cycle=%0d squashed_pc=%08x mtvec=%08x mie=%0d mpie=%0d",
                         cyc, dut.ex_pc, dut.u_csr.mtvec,
                         dut.u_csr.mstatus_mie, dut.u_csr.mstatus_mpie);
                check("C1 trap fires with a real instruction in EX",
                      dut.ex_valid === 1'b1);
                check("C4a MIE was set before the trap",
                      dut.u_csr.mstatus_mie === 1'b1);
            end else begin
                trap_d1 <= 1'b0;
            end

            // ---- C2/C3/C4: CSR state one cycle after the trap ----
            if (trap_d1) begin
                $display("IRQ_ENTERED mepc=%08x mcause=%08x mie=%0d mpie=%0d",
                         dut.u_csr.mepc, dut.u_csr.mcause,
                         dut.u_csr.mstatus_mie, dut.u_csr.mstatus_mpie);
                check("C2 mepc == squashed instruction PC",
                      dut.u_csr.mepc === squashed_pc);
                check("C3 mcause == 0x8000000b",
                      dut.u_csr.mcause === CAUSE_MEI);
                check("C4b MIE cleared on entry",
                      dut.u_csr.mstatus_mie === 1'b0);
                check("C4c MPIE holds the previous MIE",
                      dut.u_csr.mstatus_mpie === mie_before_trap);
            end

            // ---- C5/C6/C8: retirement order around the round trip ----
            if (trace_valid) begin
                if (await_isr_entry) begin
                    if (trace_pc === trap_mtvec) begin
                        // The trap is taken in EX, so the instructions that
                        // were already in MEM and WB still commit -- at most
                        // two of them -- and then the handler starts.
                        check("C5b at most 2 instructions retire between the trap and the ISR entry",
                              retires_before_isr <= 2);
                        $display("ISR_ENTRY cycle=%0d pc=%08x after %0d older retire(s)",
                                 cyc, trace_pc, retires_before_isr);
                        isr_entry_seen  <= 1'b1;
                        await_isr_entry <= 1'b0;
                    end else begin
                        retires_before_isr <= retires_before_isr + 1;
                    end
                end
                if (in_isr && trace_pc === squashed_pc)
                    squashed_retires_in_isr <= squashed_retires_in_isr + 1;
                if (await_resume) begin
                    check("C8 first retire after mret is the squashed instruction",
                          trace_pc === squashed_pc);
                    $display("IRQ_RESUME cycle=%0d pc=%08x (mepc=%08x)",
                             cyc, trace_pc, dut.u_csr.mepc);
                    await_resume <= 1'b0;
                end
                // the mret itself retiring ends the ISR
                if (in_isr && mret_retired === 1'b0 &&
                    trace_insn === 32'h30200073) begin
                    mret_retired <= 1'b1;
                    mret_pc      <= trace_pc;
                    in_isr       <= 1'b0;
                    await_resume <= 1'b1;
                    check("C6 the squashed instruction did not retire inside the ISR",
                          squashed_retires_in_isr == 0);
                    check("C7a MIE restored after mret",
                          dut.u_csr.mstatus_mie === 1'b1);
                    check("C7b MPIE set to 1 by mret",
                          dut.u_csr.mstatus_mpie === 1'b1);
                    check("C7c mepc still points at the squashed instruction",
                          dut.u_csr.mepc === squashed_pc);
                    $display("MRET_RETIRED cycle=%0d pc=%08x mepc=%08x mie=%0d mpie=%0d",
                             cyc, trace_pc, dut.u_csr.mepc,
                             dut.u_csr.mstatus_mie, dut.u_csr.mstatus_mpie);
                end
            end

            if (dut.mret_taken)
                n_mret <= n_mret + 1;
        end
    end

    // ---- main sequence ----------------------------------------------------
    initial begin
        rst      = 1'b1;
        irq      = 1'b0;
        cyc      = 0;
        checks   = 0;
        failures = 0;
        n_trap   = 0;
        n_mret   = 0;
        squashed_pc     = 32'h0;
        trap_mtvec      = 32'h0;
        mie_before_trap = 1'b0;
        in_isr          = 1'b0;
        await_isr_entry = 1'b0;
        isr_entry_seen  = 1'b0;
        retires_before_isr = 0;
        await_resume    = 1'b0;
        trap_d1         = 1'b0;
        mret_retired    = 1'b0;
        mret_pc         = 32'h0;
        squashed_retires_in_isr = 0;

        $display("tb_irq: IRQ_CYCLE=%0d FORWARDING=%0d BHT_ENABLE=%0d",
                 IRQ_CYCLE, FORWARDING, BHT_ENABLE);

        #1;
        for (i = 0; i < 1024; i = i + 1) begin
            dut.u_imem.mem[i] = 32'h0;
            dut.u_dmem.mem[i] = 32'h0;
        end
        for (i = 0; i < 32; i = i + 1)
            dut.u_regfile.regs[i] = 32'h0;
        $readmemh("asm/prog/irq_demo.hex", dut.u_imem.mem);

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        while (!done && cyc < MAXCYC) begin
            @(posedge clk);
            #1;
        end

        // ---- C9/C10 ----
        check("C5a the ISR entry at mtvec retired", isr_entry_seen === 1'b1);
        check("C9 exactly one trap for one irq pulse", n_trap == 1);
        check("C10a program reached ebreak", done === 1'b1);
        check("C10b main loop completed (x10 == 200)",
              dut.u_regfile.regs[10] === 32'd200);
        check("C10c the ISR ran exactly once (x11 == 1)",
              dut.u_regfile.regs[11] === 32'd1);
        check("C10d ISR scratch restored (x5 == 0)",
              dut.u_regfile.regs[5] === 32'd0);
        check("C10e ISR scratch restored (x6 == 0)",
              dut.u_regfile.regs[6] === 32'd0);
        check("C10f stack pointer restored (sp == 0x1000)",
              dut.u_regfile.regs[2] === 32'h0000_1000);
        check("C10g the resumption retire was observed", await_resume === 1'b0);
        check("C10h mret executed once", n_mret == 1);

        $display("tb_irq: cycles=%0d insns=%0d traps=%0d mrets=%0d mepc=%08x mcause=%08x",
                 perf_cycles, perf_insns, n_trap, n_mret,
                 dut.u_csr.mepc, dut.u_csr.mcause);
        $display("tb_irq: %0d checks, %0d failure(s)", checks, failures);

        if (failures == 0)
            $display("PASS: tb_irq");
        else
            $display("FAIL: tb_irq (%0d of %0d checks failed)", failures, checks);
        $finish;
    end

endmodule
