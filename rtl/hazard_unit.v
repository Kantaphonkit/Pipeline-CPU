`timescale 1ns/1ps
//=============================================================================
// hazard_unit.v -- pipeline interlock and control-flow flush generation.
//
// Purely combinational.  Produces three signals:
//
//   stall     hold PC and IF/ID for one cycle and bubble ID/EX
//   flush_if  clear IF/ID to a bubble (kills the instruction being fetched)
//   flush_id  clear ID/EX to a bubble (kills the instruction in ID)
//
// ---------------------------------------------------------------- interlock
//
// FORWARDING = 1 -- the only unavoidable data hazard is **load-use**.  Every
// other RAW is covered by a bypass: a producer in MEM forwards its EX/MEM
// result, a producer in WB forwards its write-back data, and a producer three
// slots ahead is caught by the register file's WB->ID internal bypass.  A load
// is different because its data does not exist until the end of MEM, so a
// consumer one slot behind it must wait:
//
//     stall = ID/EX is a valid load && ID/EX.rd != 0 &&
//             ( (ID reads rs1 && ID.rs1 == ID/EX.rd) ||
//               (ID reads rs2 && ID.rs2 == ID/EX.rd) )
//
// One cycle is enough: after it the load has reached WB and the MEM/WB bypass
// supplies the data.  `rd != 0` matters because `lw x0, 0(rs1)` writes nothing.
//
// The `ID reads rsN` qualifiers come from the decoder rather than from the raw
// instruction bits.  Without them, `lui`/`auipc`/`jal`/`csrr*i`/`ecall` would
// appear to read whatever their immediate happens to place in the rs1/rs2 field
// and could raise a stall no real dependency justifies.  That would only cost
// cycles, not correctness, but the counters exist to measure CPI, so they
// should not count hazards that are not there.
//
// FORWARDING = 0 -- the CPI-comparison build.  forward_unit.v forces every
// select to 2'b00, so the only way a consumer can see a correct value is to
// wait until the producer has written the register file.  The hazard unit then
// stalls the instruction in ID while *any* pending write to one of its source
// registers is still in EX or in MEM:
//
//     stall = ID reads a register that a valid instruction in EX or in MEM
//             will write (rd != 0)
//
// A producer in EX needs two stall cycles, a producer in MEM needs one, and a
// producer already in WB needs none because the register file's WB->ID bypass
// covers it -- hence "up to 2 cycles".  Loads need no special case here: the
// general rule already holds the consumer until the load reaches WB, where its
// data is valid.
//
// ------------------------------------------------------------------- flushes
//
// Independent of FORWARDING:
//
//   redirect_id  `jal`, resolved in ID.  Only the instruction being fetched is
//                on the wrong path -> flush_if.  The jal itself must go on
//                into EX to compute and write its link value, so flush_id
//                stays 0.  Cost: 1 bubble.
//
//   redirect_ex  taken conditional branch, `jalr`, `ecall` trap entry, `mret`
//                -- all resolved in EX.  Both younger slots (ID and IF) are on
//                the wrong path -> flush_if and flush_id.  Cost: 2 bubbles.
//
//   ebreak_pending  an `ebreak` is in EX, MEM or WB.  `ebreak` is not a trap
//                and does not redirect the PC, but nothing behind it may
//                commit, so IF/ID and ID/EX are held empty until the ebreak
//                retires and cpu_top's sticky `done` freezes the machine.  The
//                ebreak itself is already past ID/EX and retires normally.
//
// A redirect OVERRIDES a stall: the instruction in ID that raised the stall is
// being killed anyway.  That is expressed twice -- `stall` is suppressed here
// when a flush is happening, and cpu_top gives `flush` priority over `stall`
// inside every pipeline register and uses `redirect | ~stall` as its fetch
// enable.  Either alone would do; both together make the intent unmissable.
//
// Naming: `id_*` is the instruction in ID (IF/ID register + decoder), `ex_*`
// the ID/EX register outputs (instruction in EX), `mem_*` the EX/MEM register
// outputs (instruction in MEM).
//=============================================================================

module hazard_unit #(
    parameter FORWARDING = 1
) (
    // instruction currently in ID
    input  wire        id_valid,
    input  wire [4:0]  id_rs1,
    input  wire [4:0]  id_rs2,
    input  wire        id_uses_rs1,     // decoder says rs1 is a real source
    input  wire        id_uses_rs2,     // decoder says rs2 is a real source
    // instruction currently in EX (ID/EX register)
    input  wire        ex_valid,
    input  wire        ex_mem_re,       // it is a load
    input  wire        ex_reg_we,
    input  wire [4:0]  ex_rd,
    // instruction currently in MEM (EX/MEM register)
    input  wire        mem_valid,
    input  wire        mem_reg_we,
    input  wire [4:0]  mem_rd,
    // control-flow redirects and the halt shadow
    input  wire        redirect_ex,     // taken branch / jalr / trap / mret
    input  wire        redirect_id,     // jal
    input  wire        ebreak_pending,  // an ebreak is in EX, MEM or WB

    output wire        stall,           // hold PC + IF/ID, bubble ID/EX
    output wire        flush_if,        // clear IF/ID to a bubble
    output wire        flush_id         // clear ID/EX to a bubble
);

    localparam FWD_ON = (FORWARDING != 0);

    // ---- does the instruction in ID depend on a given destination? --------
    wire ex_match  = (id_uses_rs1 && (id_rs1 == ex_rd)) ||
                     (id_uses_rs2 && (id_rs2 == ex_rd));
    wire mem_match = (id_uses_rs1 && (id_rs1 == mem_rd)) ||
                     (id_uses_rs2 && (id_rs2 == mem_rd));

    // ---- pending register writes still in flight --------------------------
    wire ex_pending_load  = ex_valid  && ex_mem_re  && (ex_rd  != 5'd0);
    wire ex_pending_write = ex_valid  && ex_reg_we  && (ex_rd  != 5'd0);
    wire mem_pending_write= mem_valid && mem_reg_we && (mem_rd != 5'd0);

    // ---- interlock --------------------------------------------------------
    wire load_use  = ex_pending_load  && ex_match;                  // FWD = 1
    wire raw_any   = (ex_pending_write  && ex_match) ||             // FWD = 0
                     (mem_pending_write && mem_match);

    wire need_stall = FWD_ON ? load_use : raw_any;

    // Never stall an instruction that is about to be flushed, and never stall
    // one that is itself redirecting the PC.
    //
    // The `redirect_id` term is a safety interlock, not an optimisation.  A
    // stall bubbles ID/EX while holding IF/ID, which is correct for an
    // instruction that is waiting -- but a `jal` in ID has ALREADY committed
    // the machine to its target by the time the stall would take effect, so
    // holding it would redirect the PC and then delete the jal itself,
    // silently losing its link-register write.  A `jal` reads no registers, so
    // `id_uses_rs1`/`id_uses_rs2` are both 0 and `need_stall` cannot fire on
    // one today; this term makes that invariant explicit rather than
    // load-bearing.  (Verified: removing the `id_uses_rsN` qualifiers below
    // WITHOUT this term makes asm/prog/bloop lose one retired instruction per
    // loop iteration; with this term it stays correct.)
    assign stall = id_valid && need_stall &&
                   !redirect_ex && !redirect_id && !ebreak_pending;

    // ---- flushes ----------------------------------------------------------
    assign flush_if = redirect_ex || redirect_id || ebreak_pending;
    assign flush_id = redirect_ex || ebreak_pending;

endmodule
