derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ARM7 memory-ready is a 2-cycle (multicycle) feedback path. The ARM only advances
# when arm_advance = arm_en & mem_ready, and the cache mem_ready cannot assert in the
# same cycle a new ALU-generated address appears: it gates on arm_addr_stable =
# (arm_addr == arm_addr_q), and arm_addr_q is the previous cycle's address (igs027a.sv).
# So the io_mem_ADDR -> cache tag lookup -> mem_ready -> arm_advance feedback always has
# at least two system-clock periods to resolve, regardless of the catch-up counter.
# Relax only that cache-ready cone (validate the -through scope in quartus_sta).
set_multicycle_path -setup -end 2 -through [get_pins -compatibility_mode {*igs027a*|mem_ready}]
set_multicycle_path -hold  -end 1 -through [get_pins -compatibility_mode {*igs027a*|mem_ready}]
