// f3_pocket_top: Taito F3 System top-level for Analogue Pocket
//
// Replaces MiSTer emu.sv / sys_top.v with the Analogue Pocket Framework
// (APF) interface, driving:
//   - 64 MB SDR SDRAM for game ROMs, tiles, sprites, sound samples, and pivot RAM
//   - Cellular PSRAM 0 for the sprite framebuffer (replacing MiSTer DDR3)
//   - APF Digital Video (320x224 / 320x240 RGB 24-bit)
//   - APF 48 kHz Stereo I2S Audio
//   - APF Controller / interact.json DIPs & resets
//
`default_nettype none

module f3_pocket_top (
	input  wire        clk_74a,
	input  wire        apf_reset_n,

	// APF bridge bus
	input  wire [31:0] bridge_addr,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	// APF pad
	input  wire [31:0] pad_key,
	input  wire        apf_dataslot_complete,

	// Video out to APF scaler
	output wire [23:0] video_rgb,
	output wire        video_rgb_clock,
	output wire        video_rgb_clock_90,
	output wire        video_de,
	output wire        video_skip,
	output wire        video_vs,
	output wire        video_hs,

	// Audio out to APF I2S DAC
	output wire        audio_mclk,
	output wire        audio_lrck,
	output wire        audio_dac,

	// SDR SDRAM (512 Mbit / 64 MB)
	output wire [12:0] dram_a,
	output wire [1:0]  dram_ba,
	inout  wire [15:0] dram_dq,
	output wire [1:0]  dram_dqm,
	output wire        dram_clk,
	output wire        dram_cke,
	output wire        dram_ras_n,
	output wire        dram_cas_n,
	output wire        dram_we_n,

	// Cellular PSRAM 0 (16 MB, sprite framebuffer)
	output wire [21:16] cram0_a,
	inout  wire [15:0]  cram0_dq,
	input  wire         cram0_wait,
	output wire         cram0_clk,
	output wire         cram0_adv_n,
	output wire         cram0_cre,
	output wire         cram0_ce0_n,
	output wire         cram0_ce1_n,
	output wire         cram0_oe_n,
	output wire         cram0_we_n,
	output wire         cram0_ub_n,
	output wire         cram0_lb_n,

	// Asynchronous SRAM (256 KB, 128K x 16, main CPU 128 KB work RAM)
	output reg  [16:0]  sram_a,
	inout  wire [15:0]  sram_dq,
	output reg          sram_oe_n,
	output reg          sram_we_n,
	output reg          sram_ub_n,
	output reg          sram_lb_n,

	output wire        boot_done,
	output wire        pll_locked_o
);

	assign video_skip = 1'b0;

	// -------------------------------------------------------------------------
	// 1. Clocks
	// -------------------------------------------------------------------------
	wire clk_ram;         // 97.03 MHz (SDRAM)
	wire clk_sys;         // 53.37 MHz (Core system)
	wire clk_pix;         //  6.67 MHz (Pixel clock)
	wire clk_pix_90;      //  6.67 MHz (+90 deg)
	wire pll_locked;
	wire clk_audio_mclk;  // 12.288 MHz (Audio MCLK)

	f3_pll u_pll (
		.refclk    ( clk_74a ),
		.rst       ( 1'b0 ),
		.clk_ram   ( clk_ram ),
		.clk_sys   ( clk_sys ),
		.clk_pix   ( clk_pix ),
		.clk_pix_90( clk_pix_90 ),
		.locked    ( pll_locked )
	);

	f3_audio_pll u_audio_pll (
		.refclk     ( clk_74a ),
		.rst        ( 1'b0 ),
		.audio_mclk ( clk_audio_mclk ),
		.locked     ( )
	);

	assign video_rgb_clock    = clk_pix;
	assign video_rgb_clock_90 = clk_pix_90;
	assign pll_locked_o       = pll_locked;

	// -------------------------------------------------------------------------
	// 2. APF I/O Adapter (pk_io)
	// -------------------------------------------------------------------------
	wire [127:0] status;
	wire [31:0]  joystick_0;
	wire [31:0]  joystick_1;
	wire         core_reset_btn;
	wire         service_mode;
	wire         dbg_overlay;
	wire [1:0]   audio_boost;

	wire         ioctl_download;
	wire         ioctl_wr;
	wire [7:0]   ioctl_index;
	wire [26:0]  ioctl_addr;
	wire [15:0]  ioctl_dout;
	wire         ioctl_wait;

	wire         fifo_ovf;

	pk_io u_pk_io (
		.clk_74a        ( clk_74a ),
		.apf_reset_n    ( apf_reset_n ),
		.bridge_addr    ( bridge_addr ),
		.bridge_wr      ( bridge_wr ),
		.bridge_wr_data ( bridge_wr_data ),
		.pad_key        ( pad_key ),
		.apf_dataslot_complete ( apf_dataslot_complete ),

		.clk_sys        ( clk_sys ),
		.clk_ram        ( clk_ram ),
		.pll_locked     ( pll_locked ),
		.status         ( status ),
		.joystick_0     ( joystick_0 ),
		.joystick_1     ( joystick_1 ),
		.core_reset_btn ( core_reset_btn ),
		.service_mode   ( service_mode ),
		.dbg_overlay    ( dbg_overlay ),
		.audio_boost    ( audio_boost ),

		.ioctl_download ( ioctl_download ),
		.ioctl_wr       ( ioctl_wr ),
		.ioctl_index    ( ioctl_index ),
		.ioctl_addr     ( ioctl_addr ),
		.ioctl_dout     ( ioctl_dout ),
		.ioctl_wait     ( ioctl_wait ),
		.boot_done      ( boot_done ),
		.fifo_ovf       ( fifo_ovf )
	);

	reg [1:0] dl_sync = 2'd0;
	reg [1:0] bd_sync = 2'd0;
	always @(posedge clk_sys) begin
		dl_sync <= {dl_sync[0], ioctl_download};
		bd_sync <= {bd_sync[0], boot_done};
	end
	wire ioctl_download_sys = dl_sync[1];
	wire boot_done_sys      = bd_sync[1];

	wire reset = !pll_locked | core_reset_btn;

	// Diagnostics for the self-test overlay: number of Reset Core actions seen
	// and the ROM FIFO overflow flag (shown in row 2 in place of ioctl_index).
	reg [3:0] dbg_rst_cnt = 4'd0;
	reg       core_reset_btn_d = 1'b0;
	always @(posedge clk_sys) begin
		core_reset_btn_d <= core_reset_btn;
		if (core_reset_btn && !core_reset_btn_d) dbg_rst_cnt <= dbg_rst_cnt + 4'd1;
	end
	wire bus_reset = reset;

	// -------------------------------------------------------------------------
	// 3. Game Config Register Latch (latched on clk_ram during S_CFG1/2)
	// -------------------------------------------------------------------------
	reg [15:0] game_cfg = 16'd0;
	always @(posedge clk_ram or negedge pll_locked) begin
		if (!pll_locked) game_cfg <= 16'd0;
		else if (ioctl_wr && ioctl_index == 8'd1) game_cfg[7:0]  <= ioctl_dout[7:0];
		else if (ioctl_wr && ioctl_index == 8'd2) game_cfg[15:8] <= ioctl_dout[7:0];
	end

	wire [1:0] cfg_vis    = game_cfg[1:0];
	wire       cfg_extend = ~game_cfg[2];
	wire [5:0] cfg_game   = {game_cfg[10:8], game_cfg[5], game_cfg[7:6]};
	wire       cfg_map    = game_cfg[12];
	wire       cfg_pal12  = game_cfg[13];

	wire [26:1] map_tile_lo = cfg_map ? 26'h0C80000 : 26'h440000;
	wire [26:1] map_tile_hi = cfg_map ? 26'h0F80000 : 26'h640000;
	wire [26:1] map_sgfx_lo = cfg_map ? 26'h0280000 : 26'h140000;
	wire [26:1] map_sgfx_hi = cfg_map ? 26'h0900000 : 26'h340000;
	wire [26:1] map_smp     = cfg_map ? 26'h1100000 : 26'h740000;

	// -------------------------------------------------------------------------
	// 4. SDRAM Controller & Direct Download Loader
	// -------------------------------------------------------------------------
	wire [26:1] ch1_addr, ch2_addr, ch4_addr, ch5_addr, ch6_addr, ch7_addr, ch8_addr;
	wire [63:0] ch1_dout, ch2_dout, ch4_dout, ch5_dout, ch6_dout, ch7_dout, ch8_dout;
	wire        ch1_req, ch1_ready, ch2_req, ch2_ready;
	wire        ch4_req, ch4_ready, ch5_req, ch5_ready;
	wire        ch6_req, ch6_ready, ch7_req, ch7_ready;
	wire [15:0] ch8_din;
	wire  [1:0] ch8_be;
	wire        ch8_rnw, ch8_req, ch8_ready;

	wire [26:1] piv_ch_addr_w;
	wire [15:0] piv_ch_din_w;
	wire  [1:0] piv_ch_be_w;
	wire        piv_ch_rnw_w, piv_ch_req_w;

	// SDRAM BIST on ch8 (clk_ram) before releasing cpu_reset
	reg         sdram_bist_done = 1'b0;
	reg  [2:0]  sdram_bist_st   = 3'd0;
	reg  [7:0]  sdram_bist_idx  = 8'd0;
	reg [15:0]  sdram_err_cnt   = 16'd0;
	reg [15:0]  sdram_first_bad = 16'd0;
	reg [26:1]  bist_ch8_addr   = 26'd0;
	reg [15:0]  bist_ch8_din    = 16'd0;
	reg         bist_ch8_rnw    = 1'b1;
	reg         bist_ch8_req    = 1'b0;

	always @(posedge clk_ram) begin
		if (!pll_locked || ioctl_download || !boot_done) begin
			sdram_bist_done <= 1'b0;
			sdram_bist_st   <= 3'd0;
			sdram_bist_idx  <= 8'd0;
			sdram_err_cnt   <= 16'd0;
			sdram_first_bad <= 16'd0;
			bist_ch8_req    <= 1'b0;
			bist_ch8_rnw    <= 1'b1;
		end else if (!sdram_bist_done) begin
			case (sdram_bist_st)
				3'd0: begin // Issue write
					bist_ch8_addr <= 26'h0B00000 + {18'd0, sdram_bist_idx};
					bist_ch8_din  <= {8'd0, sdram_bist_idx} ^ 16'h5A3C;
					bist_ch8_rnw  <= 1'b0;
					bist_ch8_req  <= 1'b1;
					sdram_bist_st <= 3'd1;
				end
				3'd1: begin
					if (ch8_ready) begin
						bist_ch8_req <= 1'b0;
						if (sdram_bist_idx == 8'hFF) begin
							sdram_bist_idx <= 8'd0;
							sdram_bist_st  <= 3'd2;
						end else begin
							sdram_bist_idx <= sdram_bist_idx + 8'd1;
							sdram_bist_st  <= 3'd0;
						end
					end
				end
				3'd2: begin // Issue 4-word burst read
					bist_ch8_addr <= 26'h0B00000 + {18'd0, sdram_bist_idx[7:2], 2'b00};
					bist_ch8_rnw  <= 1'b1;
					bist_ch8_req  <= 1'b1;
					sdram_bist_st <= 3'd3;
				end
				3'd3: begin
					if (ch8_ready) begin
						bist_ch8_req <= 1'b0;
						if (ch8_dout[15:0]  != ({8'd0, sdram_bist_idx[7:2], 2'd0} ^ 16'h5A3C) ||
						    ch8_dout[31:16] != ({8'd0, sdram_bist_idx[7:2], 2'd1} ^ 16'h5A3C) ||
						    ch8_dout[47:32] != ({8'd0, sdram_bist_idx[7:2], 2'd2} ^ 16'h5A3C) ||
						    ch8_dout[63:48] != ({8'd0, sdram_bist_idx[7:2], 2'd3} ^ 16'h5A3C)) begin
							if (sdram_err_cnt == 16'd0)
								sdram_first_bad <= ch8_dout[15:0];
							if (sdram_err_cnt != 16'hFFFF)
								sdram_err_cnt <= sdram_err_cnt + 16'd1;
						end
						if (sdram_bist_idx[7:2] == 6'h3F) begin
							sdram_bist_done <= 1'b1;
							sdram_bist_st   <= 3'd4;
						end else begin
							sdram_bist_idx[7:2] <= sdram_bist_idx[7:2] + 6'd1;
							sdram_bist_st       <= 3'd2;
						end
					end
				end
				default: bist_ch8_req <= 1'b0;
			endcase
		end
	end

	assign ch8_addr = sdram_bist_done ? piv_ch_addr_w : bist_ch8_addr;
	assign ch8_din  = sdram_bist_done ? piv_ch_din_w  : bist_ch8_din;
	assign ch8_be   = sdram_bist_done ? piv_ch_be_w   : 2'b11;
	assign ch8_rnw  = sdram_bist_done ? piv_ch_rnw_w  : bist_ch8_rnw;
	assign ch8_req  = sdram_bist_done ? piv_ch_req_w  : bist_ch8_req;

	reg [1:0] sdram_bist_done_sync = 2'd0;
	always @(posedge clk_sys) sdram_bist_done_sync <= {sdram_bist_done_sync[0], sdram_bist_done};
	wire sdram_bist_done_sys = sdram_bist_done_sync[1];

	wire [26:1] ch3_addr_pb;
	wire [63:0] ch3_dout;
	wire [15:0] ch3_din_pb;
	wire  [1:0] ch3_be_pb;
	wire        ch3_req_pb, ch3_rnw_pb, ch3_ready;

	reg         ld_req;
	reg  [26:1] ld_addr;
	reg  [15:0] ld_din;
	reg         ld_busy;

	wire dl_word = ioctl_wr && (ioctl_index == 8'd0);

	always @(posedge clk_ram) begin
		if (!pll_locked) begin
			ld_req <= 1'b0; ld_busy <= 1'b0;
		end else begin
			if (dl_word && !ld_busy) begin
				ld_addr <= ioctl_addr[26:1];
				ld_din  <= (ioctl_addr < 27'h200000) ? {ioctl_dout[7:0], ioctl_dout[15:8]} : ioctl_dout;
				ld_req  <= 1'b1;
				ld_busy <= 1'b1;
			end else if (ld_busy && ch3_ready) begin
				ld_req  <= 1'b0;
				ld_busy <= 1'b0;
			end
		end
	end

	assign ioctl_wait = ld_busy;

	wire dram_dqml, dram_dqmh;
	assign dram_dqm = {dram_dqmh, dram_dqml};

	sdram u_sdram (
		.init       ( !pll_locked ),
		.clk        ( clk_ram ),
		.doRefresh  ( 1'b0 ),
		.SDRAM_DQ   ( dram_dq ),
		.SDRAM_A    ( dram_a ),
		.SDRAM_DQML ( dram_dqml ),
		.SDRAM_DQMH ( dram_dqmh ),
		.SDRAM_BA   ( dram_ba ),
		.SDRAM_nCS  ( ),
		.SDRAM_nWE  ( dram_we_n ),
		.SDRAM_nRAS ( dram_ras_n ),
		.SDRAM_nCAS ( dram_cas_n ),
		.SDRAM_CKE  ( dram_cke ),
		.SDRAM_CLK  ( dram_clk ),

		.ch1_addr   ( ch1_addr ),
		.ch1_dout   ( ch1_dout ),
		.ch1_req    ( ch1_req & ~ioctl_download ),
		.ch1_ready  ( ch1_ready ),

		.ch2_addr   ( ch2_addr ),
		.ch2_dout   ( ch2_dout ),
		.ch2_req    ( ch2_req & ~ioctl_download ),
		.ch2_ready  ( ch2_ready ),

		.ch3_addr   ( ioctl_download ? ld_addr : ch3_addr_pb ),
		.ch3_dout   ( ch3_dout ),
		.ch3_din    ( ioctl_download ? ld_din : ch3_din_pb ),
		.ch3_be     ( ioctl_download ? 2'b11 : ch3_be_pb ),
		.ch3_req    ( ioctl_download ? ld_req : ch3_req_pb ),
		.ch3_rnw    ( ioctl_download ? 1'b0 : ch3_rnw_pb ),
		.ch3_ready  ( ch3_ready ),

		.ch4_addr   ( ch4_addr ),
		.ch4_dout   ( ch4_dout ),
		.ch4_req    ( ch4_req & ~ioctl_download ),
		.ch4_ready  ( ch4_ready ),

		.ch5_addr   ( ch5_addr ),
		.ch5_dout   ( ch5_dout ),
		.ch5_req    ( ch5_req & ~ioctl_download ),
		.ch5_ready  ( ch5_ready ),

		.ch6_addr   ( ch6_addr ),
		.ch6_dout   ( ch6_dout ),
		.ch6_req    ( ch6_req & ~ioctl_download ),
		.ch6_ready  ( ch6_ready ),

		.ch7_addr   ( ch7_addr ),
		.ch7_dout   ( ch7_dout ),
		.ch7_req    ( ch7_req & ~ioctl_download ),
		.ch7_ready  ( ch7_ready ),

		.ch8_addr   ( ch8_addr ),
		.ch8_din    ( ch8_din ),
		.ch8_be     ( ch8_be ),
		.ch8_rnw    ( ch8_rnw ),
		.ch8_dout   ( ch8_dout ),
		.ch8_req    ( ch8_req & ~ioctl_download ),
		.ch8_ready  ( ch8_ready )
	);

	// -------------------------------------------------------------------------
	// 5. Cellular PSRAM 0 Interface for Sprite Framebuffer (via psram_phy)
	// -------------------------------------------------------------------------
	// The sprite framebuffer (rf_spr_fb) needs 320 KB (40,960 64-bit words).
	// On Analogue Pocket, cram0 (16 MB PSRAM) is dedicated to it via psram_phy.
	wire  [7:0] fb_burstcnt;
	wire [28:0] fb_addr;
	wire [63:0] fb_din;
	reg  [63:0] fb_dout;
	wire  [7:0] fb_be;
	wire        fb_we, fb_rd, fb_busy;
	reg         fb_dout_ready;

	// clk_sys -> clk_ram request handoff (data stable while req_tog != req_ack_tog)
	reg         fb_active = 1'b0;
	reg         fb_req_tog = 1'b0;
	reg         fb_req_we = 1'b0;
	reg  [16:0] fb_req_addr = 17'd0;
	reg  [63:0] fb_req_din = 64'd0;
	reg   [7:0] fb_req_cnt = 8'd0;

	reg  [2:0]  fb_done_sync = 3'd0;
	reg  [2:0]  fb_rsp_sync  = 3'd0;
	reg  [1:0]  cfg_done_sync = 2'd0;
	wire        cfg_done_ram;
	wire        cfg_done_sys = cfg_done_sync[1];

	reg  [63:0] ps_rsp_rdata = 64'd0;
	reg         ps_rsp_tog   = 1'b0;
	reg         ps_done_tog  = 1'b0;

	assign fb_busy = fb_active || !cfg_done_sys;

	always @(posedge clk_sys or posedge reset) begin
		if (reset) begin
			fb_active     <= 1'b0;
			fb_req_tog    <= 1'b0;
			fb_done_sync  <= 3'd0;
			fb_rsp_sync   <= 3'd0;
			cfg_done_sync <= 2'd0;
			fb_dout       <= 64'd0;
			fb_dout_ready <= 1'b0;
		end else begin
			cfg_done_sync <= {cfg_done_sync[0], cfg_done_ram};
			fb_done_sync  <= {fb_done_sync[1:0], ps_done_tog};
			fb_rsp_sync   <= {fb_rsp_sync[1:0],  ps_rsp_tog};
			fb_dout_ready <= 1'b0;

			if (fb_rsp_sync[2] ^ fb_rsp_sync[1]) begin
				fb_dout       <= ps_rsp_rdata;
				fb_dout_ready <= 1'b1;
			end

			if (fb_active) begin
				if (fb_done_sync[2] ^ fb_done_sync[1]) begin
					fb_active <= 1'b0;
				end
			end else if (!fb_busy && (fb_we || fb_rd)) begin
				fb_active   <= 1'b1;
				fb_req_we   <= fb_we;
				fb_req_addr <= fb_addr[16:0];
				fb_req_din  <= fb_din;
				fb_req_cnt  <= fb_we ? 8'd1 : fb_burstcnt;
				fb_req_tog  <= ~fb_req_tog;
			end
		end
	end

	// clk_ram reset sync
	reg [1:0] ram_rst_sync = 2'b11;
	always @(posedge clk_ram or negedge pll_locked) begin
		if (!pll_locked) ram_rst_sync <= 2'b11;
		else             ram_rst_sync <= {ram_rst_sync[0], reset};
	end
	wire ram_reset = ram_rst_sync[1];

	// psram_phy wires
	reg         ps_cmd_valid = 1'b0;
	wire        ps_cmd_ready;
	reg         ps_cmd_we    = 1'b0;
	reg  [22:0] ps_cmd_addr  = 23'd0;
	wire        ps_wd_pop;
	reg   [1:0] ps_w_idx     = 2'd0;
	wire [15:0] ps_wd_data   = (ps_w_idx == 2'd0) ? fb_req_din[15:0]  :
	                           (ps_w_idx == 2'd1) ? fb_req_din[31:16] :
	                           (ps_w_idx == 2'd2) ? fb_req_din[47:32] :
	                                                fb_req_din[63:48];
	wire        ps_rd_valid;
	wire [15:0] ps_rd_data;
	wire        ps_rd_last;

	wire [15:0] cram0_dq_out;
	wire        cram0_dq_oe;
	assign cram0_dq = cram0_dq_oe ? cram0_dq_out : 16'hzzzz;

	psram_phy #(
		.LC(2),
		.CLKDIV(2),
		.RDLAT(2)
	) u_cram0_phy (
		.clk       ( clk_ram ),
		.rst       ( ram_reset ),
		.cmd_valid ( ps_cmd_valid ),
		.cmd_ready ( ps_cmd_ready ),
		.cmd_we    ( ps_cmd_we ),
		.cmd_addr  ( ps_cmd_addr ),
		.cmd_len   ( 5'd3 ), // 4 x 16-bit words = 64 bits
		.wd_pop    ( ps_wd_pop ),
		.wd_data   ( ps_wd_data ),
		.wd_be     ( 2'b11 ),
		.rd_valid  ( ps_rd_valid ),
		.rd_data   ( ps_rd_data ),
		.rd_last   ( ps_rd_last ),
		.cfg_done  ( cfg_done_ram ),
		.p_a       ( cram0_a ),
		.p_dq_out  ( cram0_dq_out ),
		.p_dq_oe   ( cram0_dq_oe ),
		.p_dq_in   ( cram0_dq ),
		.p_clk     ( cram0_clk ),
		.p_adv_n   ( cram0_adv_n ),
		.p_cre     ( cram0_cre ),
		.p_ce0_n   ( cram0_ce0_n ),
		.p_ce1_n   ( cram0_ce1_n ),
		.p_oe_n    ( cram0_oe_n ),
		.p_we_n    ( cram0_we_n ),
		.p_ub_n    ( cram0_ub_n ),
		.p_lb_n    ( cram0_lb_n ),
		.p_wait    ( cram0_wait )
	);

	// clk_ram bridge FSM for 64-bit transactions & bursts
	localparam [1:0] PS_IDLE = 2'd0, PS_ISSUE = 2'd1, PS_WAIT_WR = 2'd2, PS_WAIT_RD = 2'd3;
	reg  [1:0] ps_st = PS_IDLE;
	reg  [2:0] ps_req_sync = 3'd0;
	reg  [7:0] ps_rem = 8'd0;
	reg [47:0] ps_rd_shift = 48'd0;
	reg  [1:0] ps_r_idx = 2'd0;

	always @(posedge clk_ram or posedge ram_reset) begin
		if (ram_reset) begin
			ps_st        <= PS_IDLE;
			ps_req_sync  <= 3'd0;
			ps_cmd_valid <= 1'b0;
			ps_w_idx     <= 2'd0;
			ps_r_idx     <= 2'd0;
			ps_rsp_tog   <= 1'b0;
			ps_done_tog  <= 1'b0;
		end else begin
			ps_req_sync <= {ps_req_sync[1:0], fb_req_tog};

			case (ps_st)
				PS_IDLE: begin
					ps_cmd_valid <= 1'b0;
					if (ps_req_sync[2] ^ ps_req_sync[1]) begin
						ps_cmd_we    <= fb_req_we;
						ps_cmd_addr  <= {4'b0, fb_req_addr, 2'b00};
						ps_rem       <= fb_req_cnt;
						ps_w_idx     <= 2'd0;
						ps_r_idx     <= 2'd0;
						ps_cmd_valid <= 1'b1;
						ps_st        <= PS_ISSUE;
					end
				end

				PS_ISSUE: begin
					if (ps_cmd_valid && ps_cmd_ready) begin
						ps_cmd_valid <= 1'b0;
						ps_st        <= ps_cmd_we ? PS_WAIT_WR : PS_WAIT_RD;
					end
				end

				PS_WAIT_WR: begin
					if (ps_wd_pop) begin
						if (ps_w_idx == 2'd3) begin
							ps_w_idx    <= 2'd0;
							ps_done_tog <= ~ps_done_tog;
							ps_st       <= PS_IDLE;
						end else begin
							ps_w_idx <= ps_w_idx + 2'd1;
						end
					end
				end

				PS_WAIT_RD: begin
					if (ps_rd_valid) begin
						case (ps_r_idx)
							2'd0: ps_rd_shift[15:0]  <= ps_rd_data;
							2'd1: ps_rd_shift[31:16] <= ps_rd_data;
							2'd2: ps_rd_shift[47:32] <= ps_rd_data;
							default: ;
						endcase
						ps_r_idx <= ps_r_idx + 2'd1;
						if (ps_rd_last) begin
							ps_r_idx     <= 2'd0;
							ps_rsp_rdata <= {ps_rd_data, ps_rd_shift[47:0]};
							ps_rsp_tog   <= ~ps_rsp_tog;
							if (ps_rem <= 8'd1) begin
								ps_done_tog <= ~ps_done_tog;
								ps_st       <= PS_IDLE;
							end else begin
								ps_rem       <= ps_rem - 8'd1;
								ps_cmd_addr  <= ps_cmd_addr + 23'd4;
								ps_cmd_valid <= 1'b1;
								ps_st        <= PS_ISSUE;
							end
						end
					end
				end
			endcase
		end
	end

	// -------------------------------------------------------------------------
	// 6. Taito F3 Motherboard (rf_main) & Video Pipeline (vpipe)
	// -------------------------------------------------------------------------
	reg         sram_bist_done   = 1'b0;
	reg         sram_bist_active = 1'b0;
	reg  [1:0]  sram_bist_phase  = 2'd0;
	reg  [15:0] sram_bist_addr   = 16'd0;
	reg  [15:0] sram_err_cnt     = 16'd0;

	reg  [2:0]  rom_bist_st      = 3'd0;
	reg         rom_bist_req     = 1'b0;
	reg  [1:0]  rom_bist_addr    = 2'd0;
	reg  [15:0] dbg_rom_w0       = 16'd0;
	reg  [15:0] dbg_rom_w1       = 16'd0;
	reg  [15:0] dbg_rom_w2       = 16'd0;
	reg  [15:0] dbg_rom_w3       = 16'd0;
	wire        rom_bist_active  = (rom_bist_st >= 3'd1 && rom_bist_st <= 3'd4);

	wire cpu_reset = reset | ioctl_download_sys | !boot_done_sys | !sram_bist_done | !sdram_bist_done_sys | (rom_bist_st != 3'd5);
	wire [21:1] cpu_prog_addr;
	wire        cpu_prog_req;
	wire [15:0] prog_data;
	wire        prog_valid;

	always @(posedge clk_sys or posedge reset) begin
		if (reset) begin
			rom_bist_st   <= 3'd0;
			rom_bist_req  <= 1'b0;
			rom_bist_addr <= 2'd0;
			dbg_rom_w0    <= 16'd0;
			dbg_rom_w1    <= 16'd0;
			dbg_rom_w2    <= 16'd0;
			dbg_rom_w3    <= 16'd0;
		end else if (ioctl_download_sys || !boot_done_sys || !sdram_bist_done_sys) begin
			rom_bist_st   <= 3'd0;
			rom_bist_req  <= 1'b0;
			rom_bist_addr <= 2'd0;
		end else begin
			case (rom_bist_st)
				3'd0: begin
					rom_bist_addr <= 2'd0;
					rom_bist_req  <= 1'b1;
					rom_bist_st   <= 3'd1;
				end
				3'd1: begin
					rom_bist_req <= 1'b0;
					if (prog_valid) begin
						dbg_rom_w0    <= prog_data;
						rom_bist_addr <= 2'd1;
						rom_bist_req  <= 1'b1;
						rom_bist_st   <= 3'd2;
					end
				end
				3'd2: begin
					rom_bist_req <= 1'b0;
					if (prog_valid) begin
						dbg_rom_w1    <= prog_data;
						rom_bist_addr <= 2'd2;
						rom_bist_req  <= 1'b1;
						rom_bist_st   <= 3'd3;
					end
				end
				3'd3: begin
					rom_bist_req <= 1'b0;
					if (prog_valid) begin
						dbg_rom_w2    <= prog_data;
						rom_bist_addr <= 2'd3;
						rom_bist_req  <= 1'b1;
						rom_bist_st   <= 3'd4;
					end
				end
				3'd4: begin
					rom_bist_req <= 1'b0;
					if (prog_valid) begin
						dbg_rom_w3  <= prog_data;
						rom_bist_st <= 3'd5;
					end
				end
				default: rom_bist_req <= 1'b0;
			endcase
		end
	end

	rf_prog_bus u_prog_bus (
		.clk_cpu   ( clk_sys ),
		.reset     ( bus_reset ),
		.addr      ( rom_bist_active ? {19'd0, rom_bist_addr} : cpu_prog_addr ),
		.req       ( rom_bist_active ? rom_bist_req : cpu_prog_req ),
		.data      ( prog_data ),
		.valid     ( prog_valid ),
		.dl_wr     ( 1'b0 ),
		.dl_addr   ( 21'd0 ),
		.dl_data   ( 16'd0 ),
		.dl_wait   ( ),
		.clk_ram   ( clk_ram ),
		.ch_addr   ( ch3_addr_pb ),
		.ch_dout   ( ch3_dout ),
		.ch_req    ( ch3_req_pb ),
		.ch_ready  ( ch3_ready ),
		.ch_din    ( ch3_din_pb ),
		.ch_be     ( ch3_be_pb ),
		.ch_rnw    ( ch3_rnw_pb )
	);

	wire [31:0] dbg_wr_count, dbg_wr_hash, dbg_last_pc, dbg_cpu_addr;
	wire [3:0]  dbg_wait_state;
	wire        dbg_wd_rst;
	wire [23:0] dbg_cpu_a;
	wire [23:0] dbg_trap_addr, dbg_trap_prev;
	wire [15:0] dbg_frame_cnt, dbg_irq2_cnt, dbg_irq3_cnt;
	wire [15:0] dbg_pf_wr_cnt, dbg_spr_wr_cnt, dbg_pal_wr_cnt, dbg_line_wr_cnt;
	wire        dbg_trap_oor;
	reg  [31:0] dbg_dl_bytes = 32'd0;
	always @(posedge clk_ram) begin
		if (!pll_locked) dbg_dl_bytes <= 32'd0;
		else if (dl_word && !ld_busy) dbg_dl_bytes <= dbg_dl_bytes + 32'd2;
	end
	wire [7:0][15:0] vctrl0, vctrl1;
	wire [13:0] v_pal_addr;   wire [15:0] v_pal_q;
	wire [13:0] v_pf_addr;    wire [15:0] v_pf_q;
	wire [11:0] v_text_addr;  wire [15:0] v_text_q;
	wire [11:0] v_char_addr;  wire [15:0] v_char_q;
	wire [14:0] v_line_addr;  wire [15:0] v_line_q;
	wire [14:0] v_pivot_addr; wire [15:0] v_pivot_q;
	wire [14:0] v_spr_addr;   wire [15:0] v_spr_q;
	wire        spr_wr_stb;

	// Sound wires
	wire  [9:0] snd_dp_addr;
	wire [15:0] snd_dp_wdata, snd_dp_q;
	wire        snd_dp_wren;
	wire  [1:0] snd_dp_be;
	wire        snd_reset;
	wire [2:0]  snd_bank;
	wire        snd_bank_en;

	wire vbl_rise, hblank, vblank;
	wire [2:0] vid_div;
	wire [8:0] vid_hcnt, vid_vcnt;

	// Async SRAM controller shared by main CPU 128 KB RAM, sound CPU 64 KB RAM,
	// pfx 16 KB and the pivot CPU read-back 8 KB (saves 192 + 24 M10K blocks).
	// Word addresses: main 0x00000, sound 0x10000, pfx 0x18000, pivot 0x1A000.
	wire [16:0] ext_ram_addr;
	wire [15:0] ext_ram_wdata;
	wire  [1:0] ext_ram_be;
	wire        ext_ram_wr;
	wire        ext_ram_req;
	reg  [15:0] ext_ram_rdata = 16'd0;
	reg         ext_ram_ack   = 1'b0;

	wire [14:0] snd_ext_ram_addr;
	wire [15:0] snd_ext_ram_wdata;
	wire  [1:0] snd_ext_ram_be;
	wire        snd_ext_ram_wr;
	wire        snd_ext_ram_req;
	reg         snd_ext_ram_ack = 1'b0;

	reg         main_ram_pend = 1'b0;
	reg         snd_ram_pend  = 1'b0;
	reg         sram_owner    = 1'b0; // 0 = main, 1 = sound

	reg  [15:0] sram_dq_out = 16'd0;
	reg         sram_dq_oe  = 1'b0;
	assign sram_dq = sram_dq_oe ? sram_dq_out : 16'hzzzz;

	localparam [1:0] SR_IDLE = 2'd0, SR_WAIT = 2'd1, SR_DONE = 2'd2;
	reg [1:0] sram_st = SR_IDLE;
	reg       sram_wr_lat = 1'b0;

	always @(posedge clk_sys or posedge reset) begin
		if (reset) begin
			sram_st         <= SR_IDLE;
			sram_a          <= 17'd0;
			sram_oe_n       <= 1'b1;
			sram_we_n       <= 1'b1;
			sram_ub_n       <= 1'b1;
			sram_lb_n       <= 1'b1;
			sram_dq_oe      <= 1'b0;
			sram_dq_out     <= 16'd0;
			ext_ram_ack     <= 1'b0;
			snd_ext_ram_ack <= 1'b0;
			main_ram_pend    <= 1'b0;
			snd_ram_pend     <= 1'b0;
			sram_owner       <= 1'b0;
			sram_bist_done   <= 1'b0;
			sram_bist_active <= 1'b0;
			sram_bist_phase  <= 2'd0;
			sram_bist_addr   <= 16'd0;
			sram_err_cnt     <= 16'd0;
		end else begin
			ext_ram_ack     <= 1'b0;
			snd_ext_ram_ack <= 1'b0;
			if (ext_ram_req)     main_ram_pend <= 1'b1;
			if (snd_ext_ram_req) snd_ram_pend  <= 1'b1;
			if (ioctl_download_sys || !boot_done_sys) begin
				sram_bist_done   <= 1'b0;
				sram_bist_active <= 1'b0;
				sram_bist_phase  <= 2'd0;
				sram_bist_addr   <= 16'd0;
				sram_err_cnt     <= 16'd0;
			end

			case (sram_st)
				SR_IDLE: begin
					sram_oe_n  <= 1'b1;
					sram_we_n  <= 1'b1;
					sram_dq_oe <= 1'b0;
					if (!sram_bist_done && boot_done_sys && !ioctl_download_sys) begin
						sram_bist_active <= 1'b1;
						sram_a           <= {1'b0, sram_bist_addr};
						sram_ub_n        <= 1'b0;
						sram_lb_n        <= 1'b0;
						sram_wr_lat      <= (sram_bist_phase != 2'd1);
						if (sram_bist_phase != 2'd1) begin
							sram_dq_out <= (sram_bist_phase == 2'd0) ? (sram_bist_addr ^ 16'hA55A) : 16'd0;
							sram_dq_oe  <= 1'b1;
							sram_we_n   <= 1'b0;
							sram_oe_n   <= 1'b1;
						end else begin
							sram_dq_oe  <= 1'b0;
							sram_we_n   <= 1'b1;
							sram_oe_n   <= 1'b0;
						end
						sram_st <= SR_WAIT;
					end else if (ext_ram_req || main_ram_pend) begin
						main_ram_pend <= 1'b0;
						sram_owner    <= 1'b0;
						sram_a        <= ext_ram_addr;
						sram_ub_n     <= ~ext_ram_be[1];
						sram_lb_n     <= ~ext_ram_be[0];
						sram_wr_lat   <= ext_ram_wr;
						if (ext_ram_wr) begin
							sram_dq_out <= ext_ram_wdata;
							sram_dq_oe  <= 1'b1;
							sram_we_n   <= 1'b0;
							sram_oe_n   <= 1'b1;
						end else begin
							sram_dq_oe  <= 1'b0;
							sram_we_n   <= 1'b1;
							sram_oe_n   <= 1'b0;
						end
						sram_st <= SR_WAIT;
					end else if (snd_ext_ram_req || snd_ram_pend) begin
						snd_ram_pend <= 1'b0;
						sram_owner   <= 1'b1;
						sram_a       <= {2'b10, snd_ext_ram_addr};
						sram_ub_n    <= ~snd_ext_ram_be[1];
						sram_lb_n    <= ~snd_ext_ram_be[0];
						sram_wr_lat  <= snd_ext_ram_wr;
						if (snd_ext_ram_wr) begin
							sram_dq_out <= snd_ext_ram_wdata;
							sram_dq_oe  <= 1'b1;
							sram_we_n   <= 1'b0;
							sram_oe_n   <= 1'b1;
						end else begin
							sram_dq_oe  <= 1'b0;
							sram_we_n   <= 1'b1;
							sram_oe_n   <= 1'b0;
						end
						sram_st <= SR_WAIT;
					end
				end

				SR_WAIT: begin
					// 1 full clk_sys (18.7 ns) settle time (> 10 ns SRAM access/write pulse)
					sram_st <= SR_DONE;
				end

				SR_DONE: begin
					if (sram_bist_active) begin
						if (sram_bist_phase == 2'd1 && (sram_dq !== (sram_bist_addr ^ 16'hA55A))) begin
							if (sram_err_cnt != 16'hFFFF)
								sram_err_cnt <= sram_err_cnt + 16'd1;
						end
						sram_bist_active <= 1'b0;
						if (sram_bist_addr == 16'hFFFF) begin
							if (sram_bist_phase == 2'd2)
								sram_bist_done <= 1'b1;
							else begin
								sram_bist_phase <= sram_bist_phase + 2'd1;
								sram_bist_addr  <= 16'd0;
							end
						end else begin
							sram_bist_addr <= sram_bist_addr + 16'd1;
						end
					end else begin
						if (!sram_wr_lat) begin
							ext_ram_rdata <= sram_dq;
						end
						if (sram_owner) snd_ext_ram_ack <= 1'b1;
						else            ext_ram_ack     <= 1'b1;
					end
					sram_oe_n   <= 1'b1;
					sram_we_n   <= 1'b1;
					sram_dq_oe  <= 1'b0;
					sram_st     <= SR_IDLE;
				end

				default: sram_st <= SR_IDLE;
			endcase
		end
	end

	rf_main #(.EXT_RAM(1'b1), .RING_EN(1'b0)) u_main (
		.clk        ( clk_sys ),
		.reset      ( cpu_reset ),
		.clk_ram    ( clk_ram ),
		.prog_addr  ( cpu_prog_addr ),
		.prog_req   ( cpu_prog_req ),
		.prog_data  ( prog_data ),
		.prog_valid ( prog_valid ),

		.vbl_rise   ( vbl_rise ),
		.j0         ( joystick_0[15:0] ),
		.j1         ( joystick_1[15:0] ),
		.six_button ( 1'b1 ),
		.pause      ( 1'b0 ),
		.test_sw    ( service_mode ),
		.nv_wr      ( ), .nv_addr ( ), .nv_data ( ),
		.hs_pause   ( 1'b0 ), .hs_addr ( 16'd0 ), .hs_wdata ( 16'd0 ),
		.hs_be      ( 2'b00 ), .hs_we ( 1'b0 ), .hs_q ( ),
		.nv_sv_addr ( 6'd0 ), .nv_sv_data ( ), .nv_wrote ( ),

		.ctrl0      ( vctrl0 ),
		.ctrl1      ( vctrl1 ),

		.v_pal_addr ( v_pal_addr ),   .v_pal_q ( v_pal_q ),
		.v_pf_addr  ( v_pf_addr ),    .v_pf_q  ( v_pf_q ),
		.v_text_addr( v_text_addr ),  .v_text_q( v_text_q ),
		.v_char_addr( v_char_addr ),  .v_char_q( v_char_q ),
		.v_line_addr( v_line_addr ),  .v_line_q( v_line_q ),
		.v_pivot_addr( v_pivot_addr ),.v_pivot_q( v_pivot_q ),
		.v_spr_addr ( v_spr_addr ),   .v_spr_q ( v_spr_q ),

		.wr_count   ( dbg_wr_count ), .wr_hash ( dbg_wr_hash ), .last_pc ( dbg_last_pc ), .trap_oor ( dbg_trap_oor ),
		.frame_cnt  ( dbg_frame_cnt ), .irq2_cnt ( dbg_irq2_cnt ), .irq3_cnt ( dbg_irq3_cnt ),
		.pf_wr_cnt  ( dbg_pf_wr_cnt ), .spr_wr_cnt ( dbg_spr_wr_cnt ), .spr_wr_stb ( spr_wr_stb ),
		.pal_wr_cnt ( dbg_pal_wr_cnt ), .pal_wr_hi ( ), .pal_wr_lo ( ), .line_wr_cnt ( dbg_line_wr_cnt ),
		.vid_vcnt   ( vid_vcnt ), .vctrl_wr_dbg ( ),
		.cpu_speed  ( 3'd0 ), .cpu_spin ( ),
		.zone_inj   ( 2'd0 ),
		.txt_wr_cnt ( ),
		.irq2_rate  ( ), .irq3_rate ( ), .irq_rate_valid ( ),

		.ring_raddr ( 11'd0 ), .ring_rdata ( ), .ring_wptr ( ), .ring_full ( ),
		.snd_dp_addr( snd_dp_addr ), .snd_dp_wdata( snd_dp_wdata ), .snd_dp_wren( snd_dp_wren ),
		.snd_dp_be  ( snd_dp_be ),   .snd_dp_q    ( snd_dp_q ),
		.snd_reset  ( snd_reset ),
		.ring_ext_sel ( 1'b0 ), .ring_arm_en ( 1'b0 ), .ring_ext_we ( 1'b0 ), .ring_ext_data ( 56'd0 ),
		.pivot_wr_cnt( ),
		.snd_bank_o ( snd_bank ), .snd_bank_en_o( snd_bank_en ),

		.piv_ch_addr  ( piv_ch_addr_w ),
		.piv_ch_din   ( piv_ch_din_w ),
		.piv_ch_be    ( piv_ch_be_w ),
		.piv_ch_rnw   ( piv_ch_rnw_w ),
		.piv_ch_req   ( piv_ch_req_w ),
		.piv_ch_ready ( sdram_bist_done ? ch8_ready : 1'b0 ),
		.piv_ch_dout  ( ch8_dout ),
		.ext_ram_addr ( ext_ram_addr ),
		.ext_ram_wdata( ext_ram_wdata ),
		.ext_ram_be   ( ext_ram_be ),
		.ext_ram_wr   ( ext_ram_wr ),
		.ext_ram_req  ( ext_ram_req ),
		.ext_ram_rdata( ext_ram_rdata ),
		.ext_ram_ack  ( ext_ram_ack ),
		.dbg_cpu_addr ( dbg_cpu_addr ),
		.dbg_wait_state( dbg_wait_state ),
		.dbg_wd_rst   ( dbg_wd_rst ),
		.dbg_cpu_a    ( dbg_cpu_a ),
		.dbg_trap_addr( dbg_trap_addr ),
		.dbg_trap_prev( dbg_trap_prev )
	);

	// -------------------------------------------------------------------------
	// Watchdog diagnostic latches. Cleared ONLY by !pll_locked -- never by
	// reset or cpu_reset -- so a watchdog reboot leaves its evidence on screen
	// after the reboot has passed (cpu_reset clears every in-core counter).
	// -------------------------------------------------------------------------
	reg         dbg_wd_rst_d  = 1'b0;
	reg   [7:0] dbg_wd_cnt    = 8'd0;
	reg  [23:0] dbg_wd_addr   = 24'd0;
	reg  [15:0] dbg_wd_frame  = 16'd0;
	reg  [15:0] dbg_vbl_cnt   = 16'd0;   // vblank edges since the last cpu_reset end
	reg         dbg_cpu_reset_d = 1'b0;
	always @(posedge clk_sys) begin
		if (!pll_locked) begin
			dbg_wd_rst_d  <= 1'b0;
			dbg_wd_cnt    <= 8'd0;
			dbg_wd_addr   <= 24'd0;
			dbg_wd_frame  <= 16'd0;
			dbg_vbl_cnt   <= 16'd0;
		end else begin
			dbg_wd_rst_d <= dbg_wd_rst;
			if (cpu_reset) dbg_vbl_cnt <= 16'd0;
			else if (vbl_rise && dbg_vbl_cnt != 16'hFFFF) dbg_vbl_cnt <= dbg_vbl_cnt + 16'd1;
			if (dbg_wd_rst && !dbg_wd_rst_d) begin
				if (dbg_wd_cnt != 8'hFF) dbg_wd_cnt <= dbg_wd_cnt + 8'd1;
				// Latch on EVERY rising edge, not just the first: the first is
				// the intentional boot reset (F3 boot code idles at 0x01016E
				// with interrupts masked; 0x010170 on hardware), so keeping
				// only that one hides the real crash.
				dbg_wd_addr  <= dbg_cpu_a;
				dbg_wd_frame <= dbg_vbl_cnt;
			end
		end
	end
	wire [31:0] dbg_rec;
	wire [15:0] dbg_rec_drop = dbg_rec[15:0];   // rf_video_pipe: sprite rows dropped (peak-hold)

	// Sprite fetch bus sharing
	wire [26:1] spr_a_lo_addr, spr_a_hi_addr, spr_b_lo_addr, spr_b_hi_addr;
	wire [63:0] spr_a_lo_dout, spr_a_hi_dout, spr_b_lo_dout, spr_b_hi_dout;
	wire        spr_a_lo_req, spr_a_lo_ready, spr_a_hi_req, spr_a_hi_ready;
	wire        spr_b_lo_req, spr_b_lo_ready, spr_b_hi_req, spr_b_hi_ready;

	rf_spr_ch_share spr_ch_share_a (
		.clk_ram(clk_ram),
		.a_lo_addr(spr_a_lo_addr), .a_lo_dout(spr_a_lo_dout), .a_lo_req(spr_a_lo_req), .a_lo_ready(spr_a_lo_ready),
		.a_hi_addr(spr_a_hi_addr), .a_hi_dout(spr_a_hi_dout), .a_hi_req(spr_a_hi_req), .a_hi_ready(spr_a_hi_ready),
		.b_lo_addr(26'd0), .b_lo_dout(), .b_lo_req(1'b0), .b_lo_ready(),
		.b_hi_addr(26'd0), .b_hi_dout(), .b_hi_req(1'b0), .b_hi_ready(),
		.ch_addr(ch4_addr), .ch_dout(ch4_dout), .ch_req(ch4_req), .ch_ready(ch4_ready)
	);

	rf_spr_ch_share spr_ch_share_b (
		.clk_ram(clk_ram),
		.a_lo_addr(spr_b_lo_addr), .a_lo_dout(spr_b_lo_dout), .a_lo_req(spr_b_lo_req), .a_lo_ready(spr_b_lo_ready),
		.a_hi_addr(spr_b_hi_addr), .a_hi_dout(spr_b_hi_dout), .a_hi_req(spr_b_hi_req), .a_hi_ready(spr_b_hi_ready),
		.b_lo_addr(26'd0), .b_lo_dout(), .b_lo_req(1'b0), .b_lo_ready(),
		.b_hi_addr(26'd0), .b_hi_dout(), .b_hi_req(1'b0), .b_hi_ready(),
		.ch_addr(ch7_addr), .ch_dout(ch7_dout), .ch_req(ch7_req), .ch_ready(ch7_ready)
	);

	// Video Pipeline
	wire [23:0] game_rgb;
	rf_video_pipe u_vpipe (
		.clk          ( clk_sys ),
		.reset        ( reset ),
		.clk_ram      ( clk_ram ),
		.div          ( vid_div ),
		.hcnt         ( vid_hcnt ),
		.vcnt         ( vid_vcnt ),
		.hblank       ( hblank ),
		.vblank       ( vblank ),
		.rate_60      ( 1'b0 ),
		.ctrl0        ( vctrl0 ),
		.ctrl1        ( vctrl1 ),
		.flip         ( 1'b0 ),
		.vis_mode     ( cfg_vis ),
		.extend       ( cfg_extend ),

		.line_addr    ( v_line_addr ), .line_q ( v_line_q ),
		.pf_addr      ( v_pf_addr ),   .pf_q   ( v_pf_q ),
		.pal_addr     ( v_pal_addr ),  .pal_q  ( v_pal_q ),
		.text_addr    ( v_text_addr ), .text_q ( v_text_q ),
		.char_addr    ( v_char_addr ), .char_q ( v_char_q ),
		.pivot_addr   ( v_pivot_addr ),.pivot_q( v_pivot_q ),

		.ch1_addr     ( ch1_addr ), .ch1_dout ( ch1_dout ), .ch1_req ( ch1_req ), .ch1_ready ( ch1_ready ),
		.ch2_addr     ( ch2_addr ), .ch2_dout ( ch2_dout ), .ch2_req ( ch2_req ), .ch2_ready ( ch2_ready ),

		.spr_addr     ( v_spr_addr ), .spr_q ( v_spr_q ),
		.spr_a_lo_addr( spr_a_lo_addr ), .spr_a_lo_dout( spr_a_lo_dout ), .spr_a_lo_req( spr_a_lo_req ), .spr_a_lo_ready( spr_a_lo_ready ),
		.spr_a_hi_addr( spr_a_hi_addr ), .spr_a_hi_dout( spr_a_hi_dout ), .spr_a_hi_req( spr_a_hi_req ), .spr_a_hi_ready( spr_a_hi_ready ),
		.spr_b_lo_addr( spr_b_lo_addr ), .spr_b_lo_dout( spr_b_lo_dout ), .spr_b_lo_req( spr_b_lo_req ), .spr_b_lo_ready( spr_b_lo_ready ),
		.spr_b_hi_addr( spr_b_hi_addr ), .spr_b_hi_dout( spr_b_hi_dout ), .spr_b_hi_req( spr_b_hi_req ), .spr_b_hi_ready( spr_b_hi_ready ),

		.rgb          ( game_rgb ),
		.dbg_lines    ( ), .dbg_fetch ( ), .dbg_max ( ),
		.dbg_nz       ( ), .dbg_spr ( ), .dbg_rec ( dbg_rec ),
		.dbg_sfetch   ( ), .dbg_short ( ), .dbg_fold ( ),
		.spr_wr_stb   ( spr_wr_stb ), .dbg_tear ( ),
		.dbg_seq_rec01( ), .dbg_seq_rec23( ), .dbg_seq_nspr01( ), .dbg_seq_nspr23( ), .dbg_seq_ovr( ),
		.dbg_seq_fold01( ), .dbg_seq_fold23( ), .dbg_seq_used01( ), .dbg_seq_used23( ),
		.dbg_sprpix   ( ), .dbg_mixpix ( ), .row_cap ( 2'd0 ),
		.pal12        ( cfg_pal12 ),
		.tile_base_lo ( map_tile_lo ), .tile_base_hi ( map_tile_hi ),
		.sgfx_base_lo ( map_sgfx_lo ), .sgfx_base_hi ( map_sgfx_hi ),

		.ddr_burstcnt ( fb_burstcnt ), .ddr_addr ( fb_addr ), .ddr_din ( fb_din ),
		.ddr_be       ( fb_be ),       .ddr_we   ( fb_we ),   .ddr_rd  ( fb_rd ),
		.ddr_busy     ( fb_busy ),     .ddr_dout ( fb_dout ), .ddr_dout_ready ( fb_dout_ready )
	);

	// Raster timing generator (MAME taito_f3.cpp)
	wire vid_hsync, vid_vsync;
	wire [7:0] dbg_vid_r, dbg_vid_g, dbg_vid_b;
	rayforce_video u_vid_timing (
		.clk        ( clk_sys ),
		.reset      ( reset ),
		.dl_active  ( ioctl_download_sys ), .dl_seen ( boot_done_sys ), .dl_bytes ( dbg_dl_bytes ), .dl_sum ( {dbg_rom_w0, dbg_rom_w1} ), .dl_index ( {fifo_ovf, 3'b000, dbg_rst_cnt} ),
		// Rows 6-10 show the ROM/SDRAM load proofs at boot, and the trap and
		// watchdog evidence while the Debug Overlay interact is set:
		//   row 6  : trap_prev[23:16] | trap_addr[23:0]  (first out-of-range fetch)
		//   row 7  : rec peak | sprite rows dropped
		//   row 8  : irq3 | trap_prev[15:0]
		//   row 9  : frame of LAST watchdog reset | wd count, addr[23:16]
		//   row 10 : addr[15:0] of LAST watchdog reset
		.trap_oor   ( dbg_trap_oor ), .wr_count ( dbg_wr_count ), .wr_hash ( dbg_wr_hash ), .last_pc ( dbg_overlay ? {dbg_trap_prev[23:16], dbg_trap_addr[23:0]} : dbg_last_pc ),
		.bist_sum   ( {sdram_err_cnt, sram_err_cnt} ), .bist_done ( sdram_bist_done_sys ),
		.frame_cnt  ( dbg_overlay ? dbg_rec[31:16] : dbg_frame_cnt ), .irq2_cnt ( dbg_overlay ? dbg_rec_drop : dbg_irq2_cnt ), .irq3_cnt ( dbg_irq3_cnt ),
		.pf_wr_cnt  ( dbg_overlay ? dbg_wd_frame : dbg_rom_w2 ),
		.spr_wr_cnt ( dbg_overlay ? {dbg_wd_cnt, dbg_wd_addr[23:16]} : dbg_rom_w3 ),
		.pal_wr_cnt ( dbg_overlay ? dbg_trap_prev[15:0] : dbg_pal_wr_cnt ),
		.line_wr_cnt( dbg_overlay ? dbg_wd_addr[15:0] : sdram_first_bad ),
		.v_pal_addr ( ), .v_pal_q ( 16'd0 ),
		.vis_mode   ( cfg_vis ),
		.rate_60    ( 1'b0 ),
		.vbl_rise   ( vbl_rise ),
		.div_o      ( vid_div ),
		.hcnt_o     ( vid_hcnt ),
		.vcnt_o     ( vid_vcnt ),
		.ce_pix     ( ),
		.r          ( dbg_vid_r ), .g ( dbg_vid_g ), .b ( dbg_vid_b ),
		.hblank     ( hblank ),
		.vblank     ( vblank ),
		.hsync      ( vid_hsync ),
		.vsync      ( vid_vsync )
	);

	// Direct APF video generation. The rayforce_video self-test hex page is
	// shown only on demand (Debug Overlay interact or L1+R1); the boot no longer
	// shows it while pal_wr_cnt == 0, so a release starts straight into the game.
	assign video_rgb = dbg_overlay ? {dbg_vid_r, dbg_vid_g, dbg_vid_b} : game_rgb;
	assign video_de  = !hblank && !vblank;
	assign video_hs  = vid_hsync;
	assign video_vs  = vid_vsync;

	// -------------------------------------------------------------------------
	// 7. Sound Board (rf_sound_main + ES5505 + I2S)
	// -------------------------------------------------------------------------
	wire        es_we, bk_we, es_irqv_ack, vl_we, vl_offset;
	wire  [7:0] vl_data;
	wire  [3:0] es_reg;
	wire [15:0] es_data;
	wire  [1:0] es_be;
	wire  [4:0] bk_voice;
	wire  [2:0] bk_data;
	wire  [7:0] es_irqv;
	wire        es_rd_req, es_rd_valid;
	wire  [3:0] es_rd_reg;
	wire [15:0] es_rd_data;

	rf_sound_main #(.EXT_RAM(1'b1)) u_sound (
		.clk        ( clk_sys ),
		.reset      ( cpu_reset ),
		.snd_reset  ( snd_reset ),
		.pause      ( 1'b0 ),
		.snd_bank   ( snd_bank ),
		.snd_bank_en( snd_bank_en ),
		.clk_ram    ( clk_ram ),
		.ch_addr    ( ch5_addr ),
		.ch_dout    ( ch5_dout ),
		.ch_req     ( ch5_req ),
		.ch_ready   ( ch5_ready ),
		.dp_addr    ( snd_dp_addr ),
		.dp_wdata   ( snd_dp_wdata ),
		.dp_wren    ( snd_dp_wren ),
		.dp_be      ( snd_dp_be ),
		.dp_q       ( snd_dp_q ),
		.es_we      ( es_we ),
		.es_reg     ( es_reg ),
		.es_data    ( es_data ),
		.es_be      ( es_be ),
		.bk_we      ( bk_we ),
		.bk_voice   ( bk_voice ),
		.bk_data    ( bk_data ),
		.vl_we      ( vl_we ),
		.vl_offset  ( vl_offset ),
		.vl_data    ( vl_data ),
		.esp_halt   ( ),
		.es_irqv    ( es_irqv ),
		.es_irqv_ack( es_irqv_ack ),
		.es_rd_req  ( es_rd_req ),
		.es_rd_reg  ( es_rd_reg ),
		.es_rd_data ( es_rd_data ),
		.es_rd_valid( es_rd_valid ),
		.ring_we    ( ),
		.ring_data  ( ),
		.last_pc    ( ),
		.es_wr_cnt  ( ),
		.running    ( ),
		.ext_ram_addr ( snd_ext_ram_addr ),
		.ext_ram_wdata( snd_ext_ram_wdata ),
		.ext_ram_be   ( snd_ext_ram_be ),
		.ext_ram_wr   ( snd_ext_ram_wr ),
		.ext_ram_req  ( snd_ext_ram_req ),
		.ext_ram_rdata( ext_ram_rdata ),
		.ext_ram_ack  ( snd_ext_ram_ack )
	);

	wire        sm_req, sm_valid, sm_busy;
	wire [22:3] sm_addr;
	wire [63:0] sm_line;
	wire        es_out_valid;
	wire [7:0][19:0] es_out;
	wire  [4:0] es_active;

	logic es_tick;
	logic [31:0] es_acc;
	logic [31:0] es_rate;
	always_comb begin
		case (es_active)
			5'd0:  es_rate = 32'd952380;
			5'd1:  es_rate = 32'd476190;
			5'd2:  es_rate = 32'd317460;
			5'd3:  es_rate = 32'd238095;
			5'd4:  es_rate = 32'd190476;
			5'd5:  es_rate = 32'd158730;
			5'd6:  es_rate = 32'd136054;
			5'd7:  es_rate = 32'd119047;
			5'd8:  es_rate = 32'd105820;
			5'd9:  es_rate = 32'd95238;
			5'd10: es_rate = 32'd86580;
			5'd11: es_rate = 32'd79365;
			5'd12: es_rate = 32'd73260;
			5'd13: es_rate = 32'd68027;
			5'd14: es_rate = 32'd63492;
			5'd15: es_rate = 32'd59523;
			5'd16: es_rate = 32'd56022;
			5'd17: es_rate = 32'd52910;
			5'd18: es_rate = 32'd50125;
			5'd19: es_rate = 32'd47619;
			5'd20: es_rate = 32'd45351;
			5'd21: es_rate = 32'd43290;
			5'd22: es_rate = 32'd41407;
			5'd23: es_rate = 32'd39682;
			5'd24: es_rate = 32'd38095;
			5'd25: es_rate = 32'd36630;
			5'd26: es_rate = 32'd35273;
			5'd27: es_rate = 32'd34013;
			5'd28: es_rate = 32'd32840;
			5'd29: es_rate = 32'd31746;
			5'd30: es_rate = 32'd30721;
			5'd31: es_rate = 32'd29761;
			default: es_rate = 32'd29761;
		endcase
	end

	always_ff @(posedge clk_sys) begin
		es_tick <= 1'b0;
		if (cpu_reset) es_acc <= 32'd0;
		else if (es_acc + es_rate >= 32'd53372000) begin
			es_acc  <= es_acc + es_rate - 32'd53372000;
			es_tick <= 1'b1;
		end else begin
			es_acc  <= es_acc + es_rate;
		end
	end

	logic [2:0] cfg_bankmask;
	always_comb begin
		case (cfg_game)
			6'd8:    cfg_bankmask = 3'd1; // Arkanoid Returns  (4 MB)
			6'd9:    cfg_bankmask = 3'd7; // Puzzle Bobble 3  (16 MB)
			6'd10:   cfg_bankmask = 3'd7; // Puzzle Bobble 4  (16 MB)
			6'd13:   cfg_bankmask = 3'd1; // Cleopatra Fortune (4 MB)
			6'd14:   cfg_bankmask = 3'd1; // Twin Qix          (4 MB)
			6'd36:   cfg_bankmask = 3'd7; // Kirameki Star Road
			default: cfg_bankmask = 3'd3; // 8 MB region
		endcase
	end

	rf_es5505 u_es5505 (
		.clk        ( clk_sys ),
		.reset      ( cpu_reset | snd_reset ),
		.es_we      ( es_we ),
		.es_reg     ( es_reg ),
		.es_data    ( es_data ),
		.es_be      ( es_be ),
		.bk_we      ( bk_we ),
		.bk_voice   ( bk_voice ),
		.bk_data    ( bk_data ),
		.bank_mask  ( cfg_bankmask ),
		.sm_req     ( sm_req ),
		.sm_addr    ( sm_addr ),
		.sm_line    ( sm_line ),
		.sm_valid   ( sm_valid ),
		.sm_busy    ( sm_busy ),
		.tick       ( es_tick ),
		.out_valid  ( es_out_valid ),
		.out_ch     ( es_out ),
		.out_active ( es_active ),
		.irqv_out   ( es_irqv ),
		.irqv_ack   ( es_irqv_ack ),
		.rd_req     ( es_rd_req ),
		.rd_reg     ( es_rd_reg ),
		.rd_data    ( es_rd_data ),
		.rd_valid   ( es_rd_valid ),
		.dbg_overrun( ), .dbg_miss( ), .dbg_wqdrop( )
	);

	rf_smp_bus u_smp_bus (
		.clk_cpu ( clk_sys ),
		.reset   ( cpu_reset ),
		.addr    ( sm_addr ),
		.req     ( sm_req ),
		.line    ( sm_line ),
		.valid   ( sm_valid ),
		.busy    ( sm_busy ),
		.clk_ram ( clk_ram ),
		.ch_addr ( ch6_addr ),
		.ch_dout ( ch6_dout ),
		.ch_req  ( ch6_req ),
		.ch_ready( ch6_ready ),
		.base    ( map_smp )
	);

	// Mixer & Volume
	logic signed [22:0] mix_l, mix_r;
	always_ff @(posedge clk_sys) if (es_out_valid) begin
		mix_l <= 23'($signed(es_out[0])) + 23'($signed(es_out[2])) + 23'($signed(es_out[4])) + 23'($signed(es_out[6]));
		mix_r <= 23'($signed(es_out[1])) + 23'($signed(es_out[3])) + 23'($signed(es_out[5])) + 23'($signed(es_out[7]));
	end
	logic mix_valid;
	always_ff @(posedge clk_sys) mix_valid <= es_out_valid;

	wire signed [15:0] snd_l, snd_r;
	rf_mb87078 u_mb87078 (
		.clk     ( clk_sys ),
		.reset   ( cpu_reset ),
		.we      ( vl_we ),
		.offset  ( vl_offset ),
		.data    ( vl_data ),
		.in_valid( mix_valid ),
		.in_l    ( mix_l ),
		.in_r    ( mix_r ),
		.out_l   ( snd_l ),
		.out_r   ( snd_r )
	);

	// 48 kHz Linear Interpolation Resampler (29.76 kHz ES5505 -> 48 kHz I2S)
	reg snd_valid = 1'b0;
	always_ff @(posedge clk_sys) snd_valid <= mix_valid;

	reg signed [15:0] prev_snd_l = 16'sd0, curr_snd_l = 16'sd0;
	reg signed [15:0] prev_snd_r = 16'sd0, curr_snd_r = 16'sd0;
	always_ff @(posedge clk_sys) begin
		if (cpu_reset | snd_reset) begin
			prev_snd_l <= 16'sd0; curr_snd_l <= 16'sd0;
			prev_snd_r <= 16'sd0; curr_snd_r <= 16'sd0;
		end else if (snd_valid) begin
			prev_snd_l <= curr_snd_l; curr_snd_l <= snd_l;
			prev_snd_r <= curr_snd_r; curr_snd_r <= snd_r;
		end
	end

	// 48 kHz sample strobe in clk_sys (53.3671875 MHz)
	reg [31:0] aud_48k_acc = 32'd0;
	reg        aud_48k_stb = 1'b0;
	always_ff @(posedge clk_sys) begin
		aud_48k_stb <= 1'b0;
		if (cpu_reset) begin
			aud_48k_acc <= 32'd0;
		end else if (aud_48k_acc + 32'd48000 >= 32'd53367188) begin
			aud_48k_acc <= aud_48k_acc + 32'd48000 - 32'd53367188;
			aud_48k_stb <= 1'b1;
		end else begin
			aud_48k_acc <= aud_48k_acc + 32'd48000;
		end
	end

	// Stage 1: capture fractional phase t = es_acc / 53372000 in [0, 65535] & sample delta
	wire [32:0] es_t_prod = {1'b0, es_acc[25:10]} * 17'd82399;
	reg  [15:0] es_t_q = 16'd0;
	reg signed [16:0] diff_l_q = 17'sd0, diff_r_q = 17'sd0;
	reg signed [15:0] base_l_q = 16'sd0, base_r_q = 16'sd0;
	reg               aud_48k_stb_d1 = 1'b0;
	always_ff @(posedge clk_sys) begin
		aud_48k_stb_d1 <= aud_48k_stb;
		if (aud_48k_stb) begin
			es_t_q   <= es_t_prod[31:16];
			base_l_q <= prev_snd_l;
			base_r_q <= prev_snd_r;
			diff_l_q <= $signed(curr_snd_l) - $signed(prev_snd_l);
			diff_r_q <= $signed(curr_snd_r) - $signed(prev_snd_r);
		end
	end

	// Stage 2: linear interpolation (prev + diff * t)
	wire signed [33:0] interp_prod_l = diff_l_q * $signed({1'b0, es_t_q});
	wire signed [33:0] interp_prod_r = diff_r_q * $signed({1'b0, es_t_q});
	reg signed [15:0] interp_l = 16'sd0, interp_r = 16'sd0;
	reg               aud_48k_stb_d2 = 1'b0;
	always_ff @(posedge clk_sys) begin
		aud_48k_stb_d2 <= aud_48k_stb_d1;
		if (aud_48k_stb_d1) begin
			interp_l <= base_l_q + interp_prod_l[31:16];
			interp_r <= base_r_q + interp_prod_r[31:16];
		end
	end

	// Saturating audio boost multiplier (matches Rayforce.sv)
	wire [2:0] aud_sh = (audio_boost == 2'd0) ? 3'd3 : // 8x
	                    (audio_boost == 2'd1) ? 3'd0 : // 1x
	                    (audio_boost == 2'd2) ? 3'd2 : // 4x
	                                            3'd4;  // 16x
	wire signed [23:0] aud_wl = 24'($signed(interp_l)) <<< aud_sh;
	wire signed [23:0] aud_wr = 24'($signed(interp_r)) <<< aud_sh;
	wire signed [15:0] boost_l = (aud_wl >  24'sd32767) ?  16'sd32767 :
	                             (aud_wl < -24'sd32768) ? -16'sd32768 : aud_wl[15:0];
	wire signed [15:0] boost_r = (aud_wr >  24'sd32767) ?  16'sd32767 :
	                             (aud_wr < -24'sd32768) ? -16'sd32768 : aud_wr[15:0];

	// Pocket I2S Audio DAC (48 kHz, 16-bit signed, jitter-free PLL MCLK)
	sound_i2s #(
		.CHANNEL_WIDTH  ( 16 ),
		.SIGNED_INPUT   ( 1 )
	) u_i2s (
		.clk_74a        ( clk_74a ),
		.clk_audio      ( clk_sys ),
		.ext_mclk       ( clk_audio_mclk ),
		.audio_l        ( boost_l ),
		.audio_r        ( boost_r ),
		.audio_stb      ( aud_48k_stb_d2 ),
		.audio_mclk     ( audio_mclk ),
		.audio_lrck     ( audio_lrck ),
		.audio_dac      ( audio_dac )
	);

endmodule
`default_nettype wire
