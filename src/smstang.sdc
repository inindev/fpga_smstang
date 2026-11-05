
create_clock -name clk_sys -period 18.62 -waveform {0 9.31} [get_nets {clk_sys}]

# Relax T80 timing constraints
set_multicycle_path 2 -setup -start -from [get_pins {system/z80_inst/**/*}] -to [get_clocks {clk_sys}]
set_multicycle_path 1 -hold -start -from [get_pins {system/z80_inst/**/*}] -to [get_clocks {clk_sys}]

// Clock crossings: a register named *_meta is the first stage of a synchronizer (iosys's
// UART input, usb_hid_sync's USB buttons). The path into it crosses clocks on purpose.
set_false_path -to [get_regs {*_meta*}]
