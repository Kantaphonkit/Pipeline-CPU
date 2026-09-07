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
#   rtl/*.v, constraints.xdc, asm/prog/*.hex, asm/smoke.hex
#
# Usage (invoked by synth.sh/synth.ps1, not directly):
#   vivado -mode batch -source synth.tcl -log synth.log -journal synth.jou \
#          [-tclargs --impl --hex <path> --period <ns>]
#
# --impl        additionally runs opt_design; place_design; route_design and
#               re-emits timing/utilization reports post-implementation.
#               Without it, this stops after synth_design (fast estimates).
# --hex <path>  IMEM image, relative to the shadow CWD.
#               Default asm/prog/bpred.hex.
# --period <ns> clock period to constrain to. Default 10.000 (100 MHz).
#
# --- IMEM image: why NOT smoke.hex ------------------------------------------
# The committed rtl/cpu_top.v defaults IMEM_INIT to the bare filename
# "prog.hex", which does not exist in the shadow dir and would make imem.v's
# `initial $readmemh(INIT, mem)` fail during elaboration, so the image is
# always overridden here via `-generic`.
#
# Until 2026-09-07 that override pointed at asm/smoke.hex, a ~60-instruction
# bring-up program.  Combined with imem.v carrying no ram_style attribute,
# Vivado constant-folded the 1024x32 instruction ROM away entirely: the
# post-route netlist contained zero IMEM memory cells, its single RAMB36E1 was
# the *register file*, and the reported 2173 LUT / 88 MHz therefore
# characterised the loaded program rather than the CPU (see docs/DESIGN.md
# §11.5).  Two changes fix that: rtl/{imem,dmem}.v now carry
# (* ram_style = "block" *) and rtl/regfile.v (* ram_style = "distributed" *),
# and the default image here is a real program (asm/prog/bpred.hex, the
# largest committed program image) so the ROM contents are representative.
#
# DMEM_INIT defaults to "" and dmem.v skips $readmemh entirely in that case
# (see docs/INTERFACES.md §8.7), so it is left alone.
#
# Produces (written to CWD, i.e. the shadow dir; synth.sh/synth.ps1 copy them
# back to vivado/reports/):
#   utilization.txt, timing.txt, clocks.txt, memory.txt

set part "xc7a35tcpg236-1"

set impl 0
set hex "asm/prog/bpred.hex"
set period 10.000

if {[info exists argv]} {
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            --impl   { set impl 1 }
            --hex    { incr i ; set hex [lindex $argv $i] }
            --period { incr i ; set period [lindex $argv $i] }
            default  { puts "WARNING: synth.tcl: ignoring unknown argument '$a'" }
        }
    }
}

if {![file exists $hex]} {
    puts "ERROR: IMEM image '$hex' not found in [pwd]."
    exit 1
}

set rtl_files [glob -nocomplain rtl/*.v]
if {[llength $rtl_files] == 0} {
    puts "ERROR: no rtl/*.v files found in [pwd] -- nothing to synthesize."
    exit 1
}

# No -sv flag: sources are plain Verilog-2001, not SystemVerilog.
read_verilog $rtl_files

# ---- clock period override --------------------------------------------------
# Constraints cannot be issued as plain Tcl before synth_design (there is no
# design in memory yet, so `get_ports clk` would fail), and constraints.xdc
# hardcodes 10.000 because create_project.tcl reads the same file. So for a
# non-default period the xdc is copied with the create_clock period rewritten,
# and the copy is what gets read. Everything else in the file is preserved.
set xdc "constraints.xdc"
if {[file exists $xdc]} {
    if {abs($period - 10.000) > 1e-9} {
        set fh [open $xdc r]
        set txt [read $fh]
        close $fh
        set n [regsub -all {create_clock +-period +[0-9.]+} $txt \
                   "create_clock -period [format %.3f $period]" txt]
        if {$n != 1} {
            puts "ERROR: expected exactly 1 create_clock -period line in $xdc, found $n."
            exit 1
        }
        set fh [open "constraints_gen.xdc" w]
        puts -nonewline $fh $txt
        close $fh
        set xdc "constraints_gen.xdc"
        puts "== clock period overridden to [format %.3f $period] ns via $xdc =="
    }
    read_xdc $xdc
} else {
    puts "WARNING: constraints.xdc not found in [pwd] -- synthesizing without timing constraints."
}

puts "== synth_design: part=$part IMEM_INIT=$hex period=[format %.3f $period] ns impl=$impl =="
synth_design -top cpu_top -mode out_of_context -part $part -generic IMEM_INIT=$hex

# ---- memory inference evidence ---------------------------------------------
# report_utilization's "Memory" table gives the totals; this dumps the actual
# BRAM/LUTRAM primitive instances with their hierarchical paths, which is what
# tells you *which* array went where (the 2026-09-07 finding was that the only
# RAMB36E1 in the design was the register file). Written after synth and again
# after route so the pre/post picture is both recorded.
proc report_memory_cells {fname stage} {
    set fh [open $fname w]
    puts $fh "== memory primitive instances ($stage) =="
    foreach ref {RAMB36E1 RAMB18E1 RAMS64E RAMD64E RAMS32 RAMD32} {
        set cells [get_cells -quiet -hierarchical -filter "REF_NAME == $ref"]
        puts $fh [format "%-10s count=%d" $ref [llength $cells]]
        foreach c $cells {
            puts $fh "    $c"
        }
    }
    close $fh
}

report_utilization -file utilization.txt
report_timing_summary -file timing.txt
report_clocks -file clocks.txt
report_memory_cells memory.txt "post-synth"

if {$impl} {
    opt_design
    place_design
    route_design
    report_timing_summary -file timing.txt
    report_utilization -file utilization.txt
    report_memory_cells memory.txt "post-route"
}

puts "SYNTH_TCL_DONE"
