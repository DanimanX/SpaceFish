// f3_pll: Exact clock synthesis for Taito F3 on Analogue Pocket
// Reference input: Pocket clk_74a (74.25 MHz)
//
// Clocks generated:
//   outclk_0: clk_ram    = 97.0312 MHz (SDRAM controller, target 97.04 MHz)
//   outclk_1: clk_sys    = 53.3672 MHz (F3 system, 8x pixel clock, target 53.372 MHz)
//   outclk_2: clk_pix    =  6.6709 MHz (APF video pixel clock)
//   outclk_3: clk_pix_90 =  6.6709 MHz (+90 degrees phase for APF video)
//
// VCO:
//   f_vco = 74.25 * 115 / 8 = 1067.34375 MHz (valid Cyclone V range: 600..1300 MHz)
//   C0 = 11  -> 97.0312 MHz
//   C1 = 20  -> 53.3672 MHz
//   C2 = 160 ->  6.6709 MHz
//   C3 = 160 ->  6.6709 MHz (+90 deg)
//
`default_nettype none

module f3_pll (
	input  wire refclk,          // clk_74a: 74.25 MHz
	input  wire rst,
	output wire clk_ram,         // 97.03 MHz
	output wire clk_sys,         // 53.37 MHz
	output wire clk_pix,         //  6.67 MHz
	output wire clk_pix_90,      //  6.67 MHz (+90 deg)
	output wire locked
);
	wire [3:0] outclk;

	assign clk_ram    = outclk[0];
	assign clk_sys    = outclk[1];
	assign clk_pix    = outclk[2];
	assign clk_pix_90 = outclk[3];

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("97.03125 MHz"),
		.output_clock_frequency1("53.367187 MHz"),
		.output_clock_frequency2("6.670898 MHz"),
		.output_clock_frequency3("6.670898 MHz"),
		.phase_shift3("37476 ps"), // +90 deg at 6.67 MHz (149.9 ns period / 4)
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(58), .m_cnt_lo_div(57), // M = 115
		.n_cnt_hi_div(4),  .n_cnt_lo_div(4),  // N = 8
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("false"),
		.m_cnt_odd_div_duty_en("true"), .n_cnt_odd_div_duty_en("false"),
		.c_cnt_hi_div0(6),  .c_cnt_lo_div0(5),  .c_cnt_odd_div_duty_en0("true"),  // C0 = 11
		.c_cnt_hi_div1(10), .c_cnt_lo_div1(10), .c_cnt_odd_div_duty_en1("false"), // C1 = 20
		.c_cnt_hi_div2(80), .c_cnt_lo_div2(80), .c_cnt_odd_div_duty_en2("false"), // C2 = 160
		.c_cnt_hi_div3(80), .c_cnt_lo_div3(80), .c_cnt_odd_div_duty_en3("false"), // C3 = 160
		.pll_vco_div(1),
		.pll_cp_current(20),
		.pll_bwctrl(4000),
		.pll_output_clk_frequency("1067.34375 MHz"),
		.mimic_fbclk_type("GCLK"),
		.pll_fbclk_mux_1("glb"),
		.pll_fbclk_mux_2("m_cnt"),
		.pll_m_cnt_in_src("ph_mux_clk"),
		.pll_slf_rst("true")
	) pll_i (
		.refclk(refclk),
		.rst(rst),
		.fbclk(1'b0),
		.outclk(outclk),
		.locked(locked),
		.zdbclk(),
		.fboutclk()
	);

endmodule
`default_nettype wire
