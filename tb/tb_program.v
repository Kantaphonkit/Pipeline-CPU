`timescale 1ns/1ps
//=============================================================================
// tb_program -- the generic, self-checking program-level testbench.
//
// One testbench for build steps 4..7.  It loads an assembled program image
// into the CPU, runs it to its ebreak, writes the WB commit trace in the exact
// format tools/iss.py emits, and then checks the architectural result two ways:
//
//   (a) all 32 architectural registers against <PROG>.regs
//   (b) the commit trace, line by line, against <PROG>.trace
//
// Plusargs
//   +PROG=<base>     REQUIRED.  Path without extension, relative to the repo
//                    root, e.g. asm/insn/add.  Reads <base>.hex (mandatory),
//                    <base>.data.hex (optional), <base>.regs (mandatory) and
//                    <base>.trace (mandatory unless +NOTRACE).
//   +MAXCYC=<n>      cycle budget, default 200000.  Exceeding it is a FAIL.
//   +NOTRACE         skip check (b).  Build step 4 needs this: without the
//                    flush logic the RTL also retires the wrong-path
//                    instructions that follow a taken branch / jump / trap, so
//                    the trace legitimately differs even when the NOP-padded
//                    program reaches the correct architectural state.
//   +IRQ_AT=<cycle>  parsed now, used from step 7 (external interrupt demo).
//
// The program image is loaded hierarchically (dut.u_imem.mem) rather than
// through the IMEM_INIT parameter, because a plusarg cannot reach a parameter.
// The instance is elaborated with a known-good placeholder init file and the
// real image is written over it at t = 1 ns, well before reset is released.
//
// Output contract (docs/INTERFACES.md section 7): exactly one final line
// "PASS: tb_program <PROG>" or "FAIL: tb_program <PROG> (<reason>)".  Nothing
// else in this file may start a line with PASS or FAIL.
//
// The trace is written to ./rtl.trace, i.e. into the simulator's working
// directory; sim/run.sh and sim/run.ps1 copy *.trace back into
// sim/work/tb_program/ after the run.
//=============================================================================

module tb_program #(
    parameter FORWARDING = 1,
    parameter BHT_ENABLE = 1
) ();

    // ---- clock / reset ----------------------------------------------------
    reg clk;
    reg rst;
    reg irq;

    // ---- DUT ports --------------------------------------------------------
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
    wire [31:0] perf_cycles;
    wire [31:0] perf_insns;
    wire [31:0] perf_lu_stalls;
    wire [31:0] perf_flushes;
    wire [31:0] perf_bht_pred;
    wire [31:0] perf_bht_miss;

    cpu_top #(
        .FORWARDING (FORWARDING),
        .BHT_ENABLE (BHT_ENABLE),
        .IMEM_INIT  ("asm/smoke.hex"),   // placeholder, overwritten below
        .DMEM_INIT  ("")
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .irq            (irq),
        .done           (done),
        .trace_valid    (trace_valid),
        .trace_pc       (trace_pc),
        .trace_insn     (trace_insn),
        .trace_rd_we    (trace_rd_we),
        .trace_rd       (trace_rd),
        .trace_rd_val   (trace_rd_val),
        .trace_mem_we   (trace_mem_we),
        .trace_mem_addr (trace_mem_addr),
        .trace_mem_val  (trace_mem_val),
        .perf_cycles    (perf_cycles),
        .perf_insns     (perf_insns),
        .perf_lu_stalls (perf_lu_stalls),
        .perf_flushes   (perf_flushes),
        .perf_bht_pred  (perf_bht_pred),
        .perf_bht_miss  (perf_bht_miss)
    );

    // ---- 10 ns clock ------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- plusarg / filename state ----------------------------------------
    reg [1023:0] prog;
    reg [1023:0] f_hex;
    reg [1023:0] f_data;
    reg [1023:0] f_regs;
    reg [1023:0] f_trace;
    integer      maxcyc;
    integer      irq_at;
    reg          notrace;

    integer      cyc;
    integer      trace_fd;
    integer      probe;
    integer      i;

    reg [31:0]   exp_regs [0:31];
    reg [31:0]   got;
    integer      reg_diffs;

    // trace comparison state
    integer      f_rtl, f_iss;
    reg [2047:0] s_rtl, s_iss;
    integer      r_rtl, r_iss;
    integer      line_no, trace_diffs;

    reg [1023:0] fail_reason;
    reg          failed;

    integer      cpi_x1000;

    // ---- cycle counter ----------------------------------------------------
    always @(posedge clk) begin
        if (!rst)
            cyc <= cyc + 1;
    end

    // ---- commit trace (docs/INTERFACES.md section 5 format) ---------------
    always @(posedge clk) begin
        if (!rst && trace_valid && trace_fd != 0) begin
            if (trace_rd_we && trace_mem_we)
                $fwrite(trace_fd, "%08x %08x x%0d=%08x mem[%08x]=%08x\n",
                        trace_pc, trace_insn, trace_rd, trace_rd_val,
                        trace_mem_addr, trace_mem_val);
            else if (trace_rd_we)
                $fwrite(trace_fd, "%08x %08x x%0d=%08x\n",
                        trace_pc, trace_insn, trace_rd, trace_rd_val);
            else if (trace_mem_we)
                $fwrite(trace_fd, "%08x %08x mem[%08x]=%08x\n",
                        trace_pc, trace_insn, trace_mem_addr, trace_mem_val);
            else
                $fwrite(trace_fd, "%08x %08x\n", trace_pc, trace_insn);
        end
    end

    // ---- main sequence ----------------------------------------------------
    initial begin
        rst         = 1'b1;
        irq         = 1'b0;
        cyc         = 0;
        failed      = 1'b0;
        fail_reason = "";
        reg_diffs   = 0;
        trace_diffs = 0;
        trace_fd    = 0;

        // -------- plusargs --------
        prog = "";
        if (!$value$plusargs("PROG=%s", prog)) begin
            $display("ERROR: +PROG=<base> is required");
            $display("FAIL: tb_program <none> (missing +PROG)");
            $finish;
        end
        maxcyc = 200000;
        if (!$value$plusargs("MAXCYC=%d", maxcyc))
            maxcyc = 200000;
        irq_at = -1;
        if (!$value$plusargs("IRQ_AT=%d", irq_at))   // parsed now, used in step 7
            irq_at = -1;
        notrace = $test$plusargs("NOTRACE");

        $sformat(f_hex,   "%0s.hex",      prog);
        $sformat(f_data,  "%0s.data.hex", prog);
        $sformat(f_regs,  "%0s.regs",     prog);
        $sformat(f_trace, "%0s.trace",    prog);

        $display("tb_program: PROG=%0s FORWARDING=%0d BHT_ENABLE=%0d MAXCYC=%0d NOTRACE=%0d",
                 prog, FORWARDING, BHT_ENABLE, maxcyc, notrace);

        // -------- required inputs must exist --------
        probe = $fopen(f_hex, "r");
        if (probe == 0) begin
            $display("ERROR: cannot open %0s", f_hex);
            $display("FAIL: tb_program %0s (missing .hex)", prog);
            $finish;
        end
        $fclose(probe);

        probe = $fopen(f_regs, "r");
        if (probe == 0) begin
            $display("ERROR: cannot open %0s", f_regs);
            $display("FAIL: tb_program %0s (missing .regs)", prog);
            $finish;
        end
        $fclose(probe);

        if (!notrace) begin
            probe = $fopen(f_trace, "r");
            if (probe == 0) begin
                $display("ERROR: cannot open %0s", f_trace);
                $display("FAIL: tb_program %0s (missing .trace)", prog);
                $finish;
            end
            $fclose(probe);
        end

        // -------- load memories (after the modules' own initial blocks) -----
        // The register file has no reset (PROJECT-REQUIREMENTS section 3.3:
        // x1..x31 are architecturally uninitialised), but the golden ISS starts
        // from an all-zero register state, so the testbench establishes that
        // same defined starting state here.  This is a testbench-side
        // initialisation only -- no RTL reset is implied.
        #1;
        for (i = 0; i < 1024; i = i + 1) begin
            dut.u_imem.mem[i] = 32'h0;
            dut.u_dmem.mem[i] = 32'h0;
        end
        for (i = 0; i < 32; i = i + 1)
            dut.u_regfile.regs[i] = 32'h0;
        $readmemh(f_hex, dut.u_imem.mem);

        probe = $fopen(f_data, "r");
        if (probe != 0) begin
            $fclose(probe);
            $readmemh(f_data, dut.u_dmem.mem);
            $display("tb_program: loaded data image %0s", f_data);
        end

        $readmemh(f_regs, exp_regs);

        trace_fd = $fopen("rtl.trace", "w");
        if (trace_fd == 0)
            $display("WARNING: cannot open rtl.trace for writing");

        // -------- synchronous reset, 3 cycles --------
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // -------- run --------
        while (!done && cyc < maxcyc) begin
            @(posedge clk);
            #1;
        end

        if (trace_fd != 0)
            $fclose(trace_fd);

        if (!done) begin
            $display("ERROR: timeout after %0d cycles without ebreak", cyc);
            failed = 1'b1;
            $sformat(fail_reason, "timeout after %0d cycles", cyc);
        end

        // -------- (a) architectural register compare --------
        for (i = 0; i < 32; i = i + 1) begin
            got = (i == 0) ? 32'h0 : dut.u_regfile.regs[i];
            if (got !== exp_regs[i]) begin
                reg_diffs = reg_diffs + 1;
                if (reg_diffs <= 32)
                    $display("REGDIFF x%0d: rtl=%08x expected=%08x",
                             i, got, exp_regs[i]);
            end
        end
        if (reg_diffs != 0 && !failed) begin
            failed = 1'b1;
            $sformat(fail_reason, "%0d register mismatch(es)", reg_diffs);
        end

        // -------- (b) commit-trace compare --------
        if (!notrace) begin
            f_rtl = $fopen("rtl.trace", "r");
            f_iss = $fopen(f_trace, "r");
            if (f_rtl == 0 || f_iss == 0) begin
                $display("ERROR: cannot reopen trace files for comparison");
                if (!failed) begin
                    failed = 1'b1;
                    fail_reason = "trace files unreadable";
                end
            end else begin
                line_no = 0;
                s_rtl = 0; s_iss = 0;
                r_rtl = $fgets(s_rtl, f_rtl);
                r_iss = $fgets(s_iss, f_iss);
                while (r_rtl != 0 || r_iss != 0) begin
                    line_no = line_no + 1;
                    if (r_rtl == 0) begin
                        trace_diffs = trace_diffs + 1;
                        if (trace_diffs <= 10)
                            $display("TRACEDIFF line %0d: rtl=<eof> iss=%0s",
                                     line_no, s_iss);
                    end else if (r_iss == 0) begin
                        trace_diffs = trace_diffs + 1;
                        if (trace_diffs <= 10)
                            $display("TRACEDIFF line %0d: rtl=%0s iss=<eof>",
                                     line_no, s_rtl);
                    end else if (s_rtl !== s_iss) begin
                        trace_diffs = trace_diffs + 1;
                        if (trace_diffs <= 10) begin
                            $display("TRACEDIFF line %0d:", line_no);
                            $display("    rtl = %0s", s_rtl);
                            $display("    iss = %0s", s_iss);
                        end
                    end
                    s_rtl = 0; s_iss = 0;
                    r_rtl = $fgets(s_rtl, f_rtl);
                    r_iss = $fgets(s_iss, f_iss);
                end
                $fclose(f_rtl);
                $fclose(f_iss);
                if (trace_diffs != 0) begin
                    $display("TRACE: %0d differing line(s) over %0d compared lines",
                             trace_diffs, line_no);
                    if (!failed) begin
                        failed = 1'b1;
                        $sformat(fail_reason, "%0d trace line mismatch(es)",
                                 trace_diffs);
                    end
                end
            end
        end

        // -------- performance summary --------
        if (perf_insns == 0)
            cpi_x1000 = 0;
        else
            cpi_x1000 = (perf_cycles * 1000) / perf_insns;

        $display("PERF cycles=%0d insns=%0d lu_stalls=%0d flushes=%0d bht_pred=%0d bht_miss=%0d",
                 perf_cycles, perf_insns, perf_lu_stalls, perf_flushes,
                 perf_bht_pred, perf_bht_miss);
        $display("CPI_x1000=%0d", cpi_x1000);

        // -------- verdict --------
        if (failed)
            $display("FAIL: tb_program %0s (%0s)", prog, fail_reason);
        else
            $display("PASS: tb_program %0s", prog);

        $finish;
    end

endmodule
