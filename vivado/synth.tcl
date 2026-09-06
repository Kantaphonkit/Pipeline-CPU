# NOTE: synth_design runs -mode out_of_context: cpu_top exposes ~360 trace/perf bits which exceed the 106 IOBs of xc7a35tcpg236; OOC reports the core fmax/utilization without IO buffers.
# vivado/synth.tcl
#
# Non-project-mode synthesis (and optional place/route) for cpu_top. See
# docs/INTERFACES.md §6 for the cpu_top port/parameter list.
#
# This script is NOT meant to be sourced with CWD = repo root. Empirically,
# Vivado 2026.1 batch mode has the same non-ANSI-CWD bug as xvlog/xelab/xsim
# (see sim/run.sh's header comment): `read_verilog` under this repo's Thai
# path ("OneDrive/เอกสาร/...") fails with
#   ERROR: [Common 17-69] Command failed: File 'C:/.../??????/.../foo.v'
#   does not exist
# (verified directly: a trivial one-module read_verilog + synth_design run
# under the repo root reproduces the mangled-path error; the same run from
# an ASCII-only directory succeeds). So vivado/synth.sh and vivado/synth.ps1
# copy a snapshot of rtl/, constraints.xdc and this script into an ASCII-only
# shadow directory under %LOCALAPPDATA% and invoke vivado there; this script
# only ever sees relative paths resolved against that shadow CWD:
#   rtl/*.v, constraints.xdc, asm/smoke.hex
#
# Usage (invoked by synth.sh/synth.ps1, not directly):
#   vivado -mode batch -source synth.tcl -log synth.log -journal synth.jou [-tclargs --impl]
#
# --impl (passed after -tclargs) additionally runs opt_design; place_design;
# route_design and re-emits timing/utilization reports post-implementation.
# Without it, this stops after synth_design (fast: synth-only estimates).
#
# IMEM_INIT note: the committed rtl/cpu_top.v defaults IMEM_INIT to the bare
# filename "prog.hex", which does not exist in the shadow dir and would make
# imem.v's `initial $readmemh(INIT, mem)` fail during elaboration. This
# script overrides IMEM_INIT via `-generic` to asm/smoke.hex (copied into the
# shadow dir by synth.sh/synth.ps1) so the BRAM initial value is well-defined.
# DMEM_INIT defaults to "" and dmem.v skips $readmemh entirely in that case
# (see docs/INTERFACES.md §8.7), so it is left alone.
#
# Produces (written to CWD, i.e. the shadow dir; synth.sh/synth.ps1 copy them
# back to vivado/reports/):
#   utilization.txt, timing.txt, clocks.txt

set part "xc7a35tcpg236-1"

set impl 0
if {[info exists argv] && [lsearch -exact $argv "--impl"] >= 0} {
    set impl 1
}

set rtl_files [glob -nocomplain rtl/*.v]
if {[llength $rtl_files] == 0} {
    puts "ERROR: no rtl/*.v files found in [pwd] -- nothing to synthesize."
    exit 1
}

# No -sv flag: sources are plain Verilog-2001, not SystemVerilog.
read_verilog $rtl_files

if {[file exists constraints.xdc]} {
    read_xdc constraints.xdc
} else {
    puts "WARNING: constraints.xdc not found in [pwd] -- synthesizing without timing constraints."
}

synth_design -top cpu_top -mode out_of_context -part $part -generic IMEM_INIT=asm/smoke.hex

report_utilization -file utilization.txt
report_timing_summary -file timing.txt
report_clocks -file clocks.txt

if {$impl} {
    opt_design
    place_design
    route_design
    report_timing_summary -file timing.txt
    report_utilization -file utilization.txt
}

puts "SYNTH_TCL_DONE"
