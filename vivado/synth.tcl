# vivado/synth.tcl
#
# Non-project-mode synthesis for cpu_top, targeting the Basys3 part
# (xc7a35tcpg236-1). Preferred over project-mode for this flow: no .xpr,
# no run directories to gitignore, just sources in -> reports out.
#
# Usage:
#   vivado -mode batch -source vivado/synth.tcl
#
# Produces:
#   vivado/reports/utilization.txt
#   vivado/reports/timing.txt
#
# Do not run this until rtl/cpu_top.v (and its dependencies) exist — this
# script is written now per CLAUDE.md step 8 but is not meant to be invoked
# during earlier build steps.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/.."]
set part       "xc7a35tcpg236-1"

set report_dir "$script_dir/reports"
file mkdir $report_dir

set rtl_files [glob -nocomplain "$repo_root/rtl/*.v"]
if {[llength $rtl_files] == 0} {
    puts "ERROR: no rtl/*.v files found under $repo_root/rtl — nothing to synthesize."
    exit 1
}

# No -sv flag: sources are plain Verilog-2001, not SystemVerilog.
read_verilog $rtl_files

if {[file exists "$script_dir/constraints.xdc"]} {
    read_xdc "$script_dir/constraints.xdc"
} else {
    puts "WARNING: $script_dir/constraints.xdc not found — synthesizing without timing constraints."
}

synth_design -top cpu_top -part $part

report_utilization -file "$report_dir/utilization.txt"
report_timing_summary -file "$report_dir/timing.txt"

puts "Synthesis complete. Reports written to $report_dir"
