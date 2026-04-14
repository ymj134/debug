//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12 (64-bit) 
//Created Time: 2026-04-14 11:28:16
create_clock -name osc_clk_i -period 20 -waveform {0 10} [get_ports {osc_clk_i}]
create_clock -name cfg_clk -period 20 -waveform {0 10} [get_nets {cfg_clk}]
create_clock -name sys_clk -period 12.8 -waveform {0 3.2} [get_nets {sys_clk}]
set_clock_groups -asynchronous -group [get_clocks {cfg_clk}] -group [get_clocks {sys_clk}]
