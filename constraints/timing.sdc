# 50 MHz board oscillator; retain the video/serializer PLL relationship.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name sd_card_clk -source [get_ports clk] -master_clock clk [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name ext_mem_clk -source [get_ports clk] -master_clock clk [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name video_clk -source [get_ports clk] -master_clock clk [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name hdmi_5x_clk -source [get_ports clk] -master_clock clk [get_pins {video_pll_m0/pll_inst.clkc[1]}]
# Counter Gray buses: a transition must settle within the fastest source period.
# No asynchronous clock groups: these max delays must remain effective.
set_max_delay -datapath_only -from [get_regs {*wr_gray[*] *rd_gray[*]}] -to [get_regs {*wr_sync1[*] *rd_sync1[*]}] 9.7
set_max_delay -datapath_only -from [get_regs {*/cdc$cross_inst/primary_addr_gray_reg_w[*]}] -to [get_regs {*/cdc$cross_inst/sync_r1_w[*]}] 9.7
set_max_delay -datapath_only -from [get_regs {*/cdc$cross_inst/primary_addr_gray_reg_r[*]}] -to [get_regs {*/cdc$cross_inst/sync_r1_r[*]}] 9.7
# status_snapshot holds data from request toggle until a three-stage return ack.
# Destination captures only AFTER the three-stage request synchronizer, so the
# same-edge hold check between the unrelated PLL/reference clocks is inapplicable.
# Keep an explicit data flight bound, rather than false-pathing the entire bus.
set_max_delay -datapath_only -from [get_regs {u_status/held[*]}] -to [get_regs {u_status/snapshot[*]}] 9.7
set_false_path -hold -from [get_regs {u_status/held[*]}] -to [get_regs {u_status/snapshot[*]}]
set_max_delay -datapath_only -from [get_regs {u_image_status/held[*]}] -to [get_regs {u_image_status/snapshot[*]}] 9.7
set_false_path -hold -from [get_regs {u_image_status/held[*]}] -to [get_regs {u_image_status/snapshot[*]}]
set_max_delay -datapath_only -from [get_regs {u_panel_settings/held[*]}] -to [get_regs {u_panel_settings/snapshot[*]}] 9.7
set_false_path -hold -from [get_regs {u_panel_settings/held[*]}] -to [get_regs {u_panel_settings/snapshot[*]}]
# Only the first request synchronizer stage may resolve metastability. Its
# same-edge hold check is not a functional capture; stages 1 and 2 stay timed.
set_false_path -hold -from [get_regs {u_status/request u_image_status/request u_panel_settings/request}] -to [get_regs {u_status/request_sync[0] u_image_status/request_sync[0] u_panel_settings/request_sync[0]}]
# Board indicator levels cross into clk through three-stage synchronizers. TD may
# merge/rename the stages, so exempt by launch clock; clk-to-clk stages stay timed.
set_false_path -hold -from [get_clocks {sd_card_clk video_clk}] -to [get_regs {auto_ref_sync* card_ref_sync* audio_ref_sync*}]
# Asynchronous user inputs enter explicit synchronizers.
set_false_path -from [get_ports {rst_n key1 key2 key3 sw[*]}]

# Fast mode: 30 ns from the card's falling-edge launch to rising-edge sample.
# Budget 22 ns for card tOD plus forwarded-clock/board flight; 0 ns earliest data.
# The RX register enable only samples on SCK rising edges (DIV=3).
set_input_delay -clock sd_card_clk -max 22 [get_ports sd_miso]
set_input_delay -clock sd_card_clk -min 0 [get_ports sd_miso]
set_multicycle_path 3 -setup -from [get_ports sd_miso]
set_multicycle_path 2 -hold -from [get_ports sd_miso]
# MOSI/CS setup at the card: next SCK rising edge is at least three core cycles away.
set_output_delay -clock sd_card_clk -max 5 [get_ports {sd_mosi sd_ncs}]
set_output_delay -clock sd_card_clk -min 0 [get_ports {sd_mosi sd_ncs}]
set_multicycle_path 3 -setup -to [get_ports {sd_mosi sd_ncs}]
set_multicycle_path 2 -hold -to [get_ports {sd_mosi sd_ncs}]
# Independent U33 data Flash at 2 MHz, 250 ns half-period.
set_input_delay -clock sd_card_clk -max 22 [get_ports flash_miso]
set_input_delay -clock sd_card_clk -min 0 [get_ports flash_miso]
set_multicycle_path 25 -setup -from [get_ports flash_miso]
set_multicycle_path 24 -hold -from [get_ports flash_miso]
set_output_delay -clock sd_card_clk -max 5 [get_ports {flash_cs flash_mosi flash_wp_n flash_hold_n}]
set_output_delay -clock sd_card_clk -min 0 [get_ports {flash_cs flash_clk flash_mosi flash_wp_n flash_hold_n}]
# Flash captures CS/MOSI at the divided SCK edge, at least 25 core cycles
# after CS and 24 after MOSI change. Use a conservative three-cycle budget.
set_multicycle_path 3 -setup -to [get_ports {flash_cs flash_mosi}]
set_multicycle_path 2 -hold -to [get_ports {flash_cs flash_mosi}]
# Forwarded SCK flight is bounded to 7 ns, included in the MISO budget above.
set_output_delay -clock sd_card_clk -max 3 [get_ports flash_clk]
# Bound forwarded clock flight to 7 ns (10-3); included with card tOD=14 ns
# and board flight=1 ns in the 22 ns MISO budget.
set_output_delay -clock sd_card_clk -max 3 [get_ports sd_dclk]
set_output_delay -clock sd_card_clk -min 0 [get_ports sd_dclk]
# Slow board controls have no external synchronous capture clock. These 5 ns
# budgets bound pad paths conservatively; DDC protocol is handled inside the IP.
set_input_delay -clock video_clk -max 5 [get_ports HDMI_DDC_SDA]
set_input_delay -clock video_clk -min 0 [get_ports HDMI_DDC_SDA]
set_output_delay -clock video_clk -max 5 [get_ports {HDMI_DDC_SDA HDMI_DDC_SCL}]
set_output_delay -clock video_clk -min 0 [get_ports {HDMI_DDC_SDA HDMI_DDC_SCL}]
set_output_delay -clock clk -max 5 [get_ports {seg_sel[*] seg_data[*] led[*] buzzer}]
set_output_delay -clock clk -min 0 [get_ports {seg_sel[*] seg_data[*] led[*] buzzer}]
