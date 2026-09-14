# Per-clock timing constraints.
#
# --freq alone applies one figure to every clock nextpnr does not otherwise
# know, so constraining the 126 MHz serial clock also demanded 126 MHz of the
# 27 MHz crystal domain and of the 25.2 MHz pixel domain.  Both then "fail"
# timing they were never meant to meet -- and which seed happens to squeak
# past becomes the difference between a build and an error.
create_clock -name clk27      -period 37.04 [get_nets clk27]
create_clock -name serial_clk -period 7.94  [get_nets serial_clk]
create_clock -name pixel_clk  -period 39.68 [get_nets pixel_clk]
