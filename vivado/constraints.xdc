## constraints.xdc — timing constraints for rv32i_cpu (cpu_top).
## Used by both create_project.tcl (project mode) and synth.tcl (non-project
## mode).  synth.tcl may rewrite the create_clock period into a generated
## copy (constraints_gen.xdc) when invoked with `--period <ns>`; the line
## below is the single source of truth for the period and must keep the
## literal form `create_clock -period <value>` for that substitution to work.

create_clock -period 10.000 -name clk [get_ports clk]

## ---------------------------------------------------------------------------
## I/O constraint hygiene
##
## cpu_top has 363 ports.  Two are real inputs (rst, irq), one is a real
## status output (done), and the remaining 361 bits are the commit-trace and
## performance-counter observation ports (trace_*, perf_*).  Left alone,
## check_timing reports 2 unconstrained inputs and 361 unconstrained outputs,
## which buries any genuine I/O problem in noise.
##
## The trace/perf ports exist only so the self-checking testbenches can watch
## the pipeline (docs/DESIGN.md §10).  They are not driven off-chip, are never
## sampled by anything with a setup requirement, and on a real board would not
## be bonded out at all.  Constraining them with an output delay would invent
## a timing requirement that does not exist and would distort the reported
## critical path, so they are declared false paths instead — the honest
## statement that no timing requirement applies to them.
##
## rst / irq / done ARE real I/O and are constrained (zero external delay:
## synthesis here is out-of-context, so there is no board model to reference
## and 0 ns is the neutral choice that still times the port's internal path).
## ---------------------------------------------------------------------------

## Measured on 2026-09-07: `set_false_path` alone does NOT clear these ports
## from check_timing's no_output_delay list (361 -> 360, i.e. only `done`
## below was cleared).  Vivado's check counts a port as constrained only if it
## carries an actual output-delay object.  So both are applied: the 0 ns
## output delay makes check_timing clean, and the false path then removes the
## same endpoints from max-delay analysis so they cannot inflate or mask the
## real critical path.  (Exceptions are applied after constraints regardless
## of file order.)
set_output_delay -clock clk 0.000 [get_ports -quiet {trace_* perf_*}]
set_false_path   -to        [get_ports -quiet {trace_* perf_*}]

set_input_delay  -clock clk 0.000 [get_ports -quiet {rst irq}]
set_output_delay -clock clk 0.000 [get_ports -quiet {done}]
