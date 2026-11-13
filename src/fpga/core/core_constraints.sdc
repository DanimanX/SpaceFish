# SpaceFish (Taito F3) Pocket: core-side timing constraints.
#
# Loaded by apf/apf_constraints.sdc (APF's, unmodified) after it creates the
# 74.25 MHz clocks and derives the PLL clocks.

set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a clk_74b}] \
    -group [get_clocks {*u_pll*counter[0].output_counter|divclk}] \
    -group [get_clocks {*u_pll*counter[1].output_counter|divclk *u_pll*counter[2].output_counter|divclk *u_pll*counter[3].output_counter|divclk}]

# TG68K advances only on clkena_in (every other clk_sys cycle or slower)
set_multicycle_path -setup 2 \
    -from [get_registers {*TG68KdotC_Kernel*}] \
    -to   [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -hold 1 \
    -from [get_registers {*TG68KdotC_Kernel*}] \
    -to   [get_registers {*TG68KdotC_Kernel*}]

# Video out is the pixel clock; apf_top samples it with the DDR converters.
# Nothing to constrain beyond the clock itself, which derive_pll_clocks makes.
