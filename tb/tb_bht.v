`timescale 1ns/1ps
//=============================================================================
// tb_bht -- self-checking unit test for rtl/bht.v.
//
// Two instances: dut_on (ENABLE=1) is the real predictor, dut_off (ENABLE=0)
// must answer "not taken" no matter what it is trained with.
//
// Covered:
//   1. reset state          -- every one of the 64 entries reads 2'b01
//   2. saturation up        -- 01 -> 10 -> 11 -> 11 (stays)
//   3. saturation down      -- 11 -> 10 -> 01 -> 00 -> 00 (stays)
//   4. prediction boundary  -- state[1] is the prediction (00,01 -> 0; 10,11 -> 1)
//   5. index aliasing       -- pc and pc+256 share one counter, pc+4 does not
//   6. same-cycle read/write-- a lookup concurrent with an update of the same
//                              index returns the OLD state (documented behaviour)
//   7. ENABLE=0             -- always predicts 0, and training changes nothing
//   8. 600 randomised update/lookup steps against a behavioural model
//
// Prints exactly one final PASS/FAIL line per docs/INTERFACES.md section 7.
//=============================================================================

module tb_bht;

    reg         clk;
    reg         rst;
    reg  [31:0] lookup_pc;
    reg         update_en;
    reg  [31:0] update_pc;
    reg         update_taken;

    wire        pred_taken_on,  pred_taken_off;
    wire [1:0]  pred_state_on,  pred_state_off;

    bht #(.ENABLE(1)) dut_on (
        .clk(clk), .rst(rst),
        .lookup_pc(lookup_pc),
        .pred_taken(pred_taken_on), .pred_state(pred_state_on),
        .update_en(update_en), .update_pc(update_pc),
        .update_taken(update_taken)
    );

    bht #(.ENABLE(0)) dut_off (
        .clk(clk), .rst(rst),
        .lookup_pc(lookup_pc),
        .pred_taken(pred_taken_off), .pred_state(pred_state_off),
        .update_en(update_en), .update_pc(update_pc),
        .update_taken(update_taken)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- behavioural model ------------------------------------------------
    reg [1:0] model [0:63];

    integer checks;
    integer failures;
    integer i;
    integer seed;
    integer step;

    reg [31:0] rpc;
    reg        rtaken;
    reg [5:0]  idx;
    reg [1:0]  expect_state;

    task check_state (input [127:0] name, input [1:0] got, input [1:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("MISMATCH %0s: got %b expected %b", name, got, want);
            end
        end
    endtask

    task check_bit (input [127:0] name, input got, input want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("MISMATCH %0s: got %b expected %b", name, got, want);
            end
        end
    endtask

    // One clocked update; the model is advanced to match.
    task do_update (input [31:0] pc, input taken);
        begin
            update_pc    = pc;
            update_taken = taken;
            update_en    = 1'b1;
            @(posedge clk);
            #1;
            update_en    = 1'b0;
            idx = pc[7:2];
            if (taken)
                model[idx] = (model[idx] == 2'b11) ? 2'b11 : (model[idx] + 2'b01);
            else
                model[idx] = (model[idx] == 2'b00) ? 2'b00 : (model[idx] - 2'b01);
        end
    endtask

    // Combinational lookup: settle, then compare.
    task do_lookup (input [31:0] pc);
        begin
            lookup_pc = pc;
            #1;
            idx = pc[7:2];
            check_state("lookup state", pred_state_on, model[idx]);
            check_bit("lookup pred",  pred_taken_on, model[idx][1]);
            check_state("ENABLE=0 state", pred_state_off, 2'b01);
            check_bit("ENABLE=0 pred",  pred_taken_off, 1'b0);
        end
    endtask

    initial begin
        checks       = 0;
        failures     = 0;
        rst          = 1'b1;
        lookup_pc    = 32'h0;
        update_en    = 1'b0;
        update_pc    = 32'h0;
        update_taken = 1'b0;
        seed         = 32'h1234_5678;

        // -------- 1. reset --------
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        #1;

        for (i = 0; i < 64; i = i + 1)
            model[i] = 2'b01;

        for (i = 0; i < 64; i = i + 1) begin
            lookup_pc = i * 4;
            #1;
            check_state("reset state", pred_state_on, 2'b01);
            check_bit("reset pred",  pred_taken_on, 1'b0);
        end

        // -------- 2. saturation up (index 5, pc = 0x14) --------
        do_lookup(32'h14);                       // 01
        do_update(32'h14, 1'b1); do_lookup(32'h14);   // 10, predicts taken
        check_bit("weakly taken predicts 1", pred_taken_on, 1'b1);
        do_update(32'h14, 1'b1); do_lookup(32'h14);   // 11
        check_state("strongly taken", pred_state_on, 2'b11);
        do_update(32'h14, 1'b1); do_lookup(32'h14);   // saturates at 11
        check_state("saturates up", pred_state_on, 2'b11);
        do_update(32'h14, 1'b1); do_lookup(32'h14);
        check_state("still saturated up", pred_state_on, 2'b11);

        // -------- 3. saturation down, same entry --------
        do_update(32'h14, 1'b0); do_lookup(32'h14);   // 10
        check_bit("10 predicts 1", pred_taken_on, 1'b1);
        do_update(32'h14, 1'b0); do_lookup(32'h14);   // 01
        check_bit("01 predicts 0", pred_taken_on, 1'b0);
        do_update(32'h14, 1'b0); do_lookup(32'h14);   // 00
        check_state("strongly not taken", pred_state_on, 2'b00);
        do_update(32'h14, 1'b0); do_lookup(32'h14);   // saturates at 00
        check_state("saturates down", pred_state_on, 2'b00);
        do_update(32'h14, 1'b0); do_lookup(32'h14);
        check_state("still saturated down", pred_state_on, 2'b00);

        // -------- 5. index aliasing --------
        // pc 0x14 and 0x114 differ by 256 -> same index; 0x18 -> next index.
        do_lookup(32'h114);
        check_state("alias +256 shares the entry", pred_state_on, model[6'h05]);
        do_update(32'h114, 1'b1);                     // trains index 5
        do_lookup(32'h014);
        check_state("alias trained through the other pc", pred_state_on, model[6'h05]);
        do_lookup(32'h018);
        check_state("neighbouring index untouched", pred_state_on, 2'b01);

        // -------- 6. same-cycle lookup and update of one index --------
        // Point the lookup at index 5 while index 5 is being written; the
        // read must return the pre-update value.
        lookup_pc    = 32'h014;
        update_pc    = 32'h014;
        update_taken = 1'b1;
        update_en    = 1'b1;
        #1;
        expect_state = model[6'h05];
        check_state("same-cycle read sees old state", pred_state_on, expect_state);
        @(posedge clk);
        #1;
        update_en = 1'b0;
        model[6'h05] = (expect_state == 2'b11) ? 2'b11 : (expect_state + 2'b01);
        do_lookup(32'h014);

        // -------- 7. ENABLE=0 stays inert after heavy training --------
        for (i = 0; i < 8; i = i + 1)
            do_update(32'h20, 1'b1);
        lookup_pc = 32'h20;
        #1;
        check_bit("ENABLE=0 never predicts taken", pred_taken_off, 1'b0);
        check_state("ENABLE=0 state constant", pred_state_off, 2'b01);
        check_state("ENABLE=1 was trained", pred_state_on, 2'b11);

        // -------- 8. randomised cross-check --------
        for (step = 0; step < 600; step = step + 1) begin
            rpc    = {$random(seed)} % 32'h400;   // 1 KB of PC space, aliases
            rpc    = rpc & ~32'h3;                // word aligned
            rtaken = {$random(seed)} % 2;
            do_update(rpc, rtaken);
            rpc = {$random(seed)} % 32'h400;
            rpc = rpc & ~32'h3;
            do_lookup(rpc);
        end

        // -------- verdict --------
        $display("tb_bht: %0d checks, %0d failure(s)", checks, failures);
        if (failures == 0)
            $display("PASS: tb_bht");
        else
            $display("FAIL: tb_bht (%0d of %0d checks failed)", failures, checks);
        $finish;
    end

endmodule
