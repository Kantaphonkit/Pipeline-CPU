## constraints.xdc — timing constraint for rv32i_cpu (cpu_top)
## 100 MHz system clock on port `clk`. Used by both create_project.tcl
## (project mode) and synth.tcl (non-project mode).

create_clock -period 10.000 -name clk [get_ports clk]
