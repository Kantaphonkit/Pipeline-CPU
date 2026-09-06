# vivado/create_project.tcl
#
# Creates a project-mode Vivado project ("rv32i_cpu") for the RISC-V RV32I
# pipelined CPU, targeting the Basys3 part (xc7a35tcpg236-1). Project files
# are generated on demand in vivado/project/ and are NOT committed (see
# .gitignore); this script is the portable source of truth instead of a
# checked-in .xpr.
#
# Usage:
#   vivado -mode batch -source vivado/create_project.tcl
#
# Run from the repo root (or any directory — paths below are resolved
# relative to this script's own location, so it works either way).
#
# All rtl/*.v files are added as design sources with cpu_top as the top
# module; all tb/*.v files are added as simulation sources; asm/*.hex files
# are added as simulation-only data files (for $readmemh). No SystemVerilog,
# no IP catalog, no block designs — plain Verilog-2001 only, per CLAUDE.md.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/.."]

set project_name "rv32i_cpu"
set project_dir  "$script_dir/project"
set part         "xc7a35tcpg236-1"

create_project $project_name $project_dir -part $part -force

set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]

# --- Design sources (rtl/*.v) ------------------------------------------------
set rtl_files [glob -nocomplain "$repo_root/rtl/*.v"]
if {[llength $rtl_files] > 0} {
    add_files -norecurse -fileset sources_1 $rtl_files
    set_property file_type Verilog [get_files -of_objects [get_filesets sources_1] $rtl_files]
} else {
    puts "WARNING: no rtl/*.v files found yet under $repo_root/rtl — add them and re-run."
}

if {[llength [get_files -of_objects [get_filesets sources_1] -filter {NAME =~ *cpu_top.v}]] > 0} {
    set_property top cpu_top [current_fileset]
} else {
    puts "WARNING: rtl/cpu_top.v not found — top module not set. Set it manually once it exists:"
    puts "  set_property top cpu_top \[current_fileset\]"
}
update_compile_order -fileset sources_1

# --- Simulation sources (tb/*.v) --------------------------------------------
set tb_files [glob -nocomplain "$repo_root/tb/*.v"]
if {[llength $tb_files] > 0} {
    add_files -norecurse -fileset sim_1 $tb_files
    set_property file_type Verilog [get_files -of_objects [get_filesets sim_1] $tb_files]
} else {
    puts "WARNING: no tb/*.v files found yet under $repo_root/tb."
}

# --- Simulation data files (asm/*.hex, for $readmemh) -----------------------
set hex_files [glob -nocomplain "$repo_root/asm/*.hex"]
if {[llength $hex_files] > 0} {
    add_files -norecurse -fileset sim_1 $hex_files
    set_property file_type "Memory Initialization Files" \
        [get_files -of_objects [get_filesets sim_1] $hex_files]
    foreach f $hex_files {
        set_property used_in_simulation true [get_files $f]
        set_property used_in_synthesis  false [get_files $f]
    }
} else {
    puts "WARNING: no asm/*.hex files found yet under $repo_root/asm."
}
update_compile_order -fileset sim_1

# --- Constraints -------------------------------------------------------------
if {[file exists "$script_dir/constraints.xdc"]} {
    add_files -norecurse -fileset constrs_1 "$script_dir/constraints.xdc"
}

puts "rv32i_cpu project created at $project_dir"
puts "Open it in the GUI with: vivado $project_dir/$project_name.xpr"
