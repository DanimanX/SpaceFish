// pk_io: APF Bridge & Controller adapter for SpaceFish (Taito F3 System)
//
// Converts APF data slot downloads and pad inputs into the MiSTer-compatible
// ioctl_* and joystick buses expected by the Taito F3 core.
//
`default_nettype none

module pk_io #(
	parameter [31:0] INTERACT_BASE = 32'hF000_0000
) (
	// ---- APF side ----------------------------------------------------------
	input  wire        clk_74a,          // APF bridge clock (74.25 MHz)
	input  wire        apf_reset_n,
	input  wire [31:0] bridge_addr,      // synchronous to clk_74a
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	// ---- APF pad controller ------------------------------------------------
	input  wire [31:0] pad_key,          // APF key bitmap
	input  wire        apf_dataslot_complete,

	// ---- Core side ---------------------------------------------------------
	input  wire        clk_sys,          // 53.37 MHz
	input  wire        clk_ram,          // 97.03 MHz (ioctl_* & FIFO read domain)
	input  wire        pll_locked,

	output reg  [127:0] status = 128'd0,
	output reg  [31:0] joystick_0 = 32'd0,
	output reg  [31:0] joystick_1 = 32'd0,
	output reg         core_reset_btn = 1'b0,
	output reg         service_mode = 1'b0,
	output reg  [1:0]  audio_boost = 2'd2,
	output reg  [2:0]  cpu_speed = 3'd1,

	output reg         ioctl_download = 1'b0,
	output reg         ioctl_wr = 1'b0,
	output reg  [7:0]  ioctl_index = 8'd0,
	output reg  [26:0] ioctl_addr = 27'd0,
	output reg  [15:0] ioctl_dout = 16'd0,
	input  wire        ioctl_wait,

	output reg         boot_done = 1'b0,
	output reg         fifo_ovf = 1'b0
);

	// -------------------------------------------------------------------------
	// 1. APF interact.json register handler (clk_74a)
	// -------------------------------------------------------------------------
	reg reset_action_74 = 1'b0;
	reg service_check_74 = 1'b0;
	reg [1:0] boost_list_74 = 2'd2;
	reg [2:0] speed_list_74 = 3'd1;

	always @(posedge clk_74a) begin
		reset_action_74 <= 1'b0; // 1-cycle pulse
		if (bridge_wr) begin
			if (bridge_addr == INTERACT_BASE) begin
				reset_action_74 <= bridge_wr_data[0];
			end else if (bridge_addr == (INTERACT_BASE + 32'h4)) begin
				service_check_74 <= bridge_wr_data[0];
			end else if (bridge_addr == (INTERACT_BASE + 32'h8)) begin
				boost_list_74 <= bridge_wr_data[1:0];
			end else if (bridge_addr == (INTERACT_BASE + 32'hC)) begin
				speed_list_74 <= bridge_wr_data[2:0];
			end
		end
	end

	// Sync interact registers to clk_sys
	reg [2:0] rst_act_sync;
	reg [1:0] srv_sync;
	reg [1:0] bst_sync;
	reg [2:0] spd_sync [0:1];
	always @(posedge clk_sys) begin
		rst_act_sync <= {rst_act_sync[1:0], reset_action_74};
		srv_sync     <= {srv_sync[0], service_check_74};
		bst_sync     <= boost_list_74; // static select
		spd_sync[0]  <= speed_list_74;
		spd_sync[1]  <= spd_sync[0];

		core_reset_btn <= rst_act_sync[1] & ~rst_act_sync[2];
		service_mode   <= srv_sync[1];
		audio_boost    <= bst_sync;
		cpu_speed      <= spd_sync[1];
		status[2]      <= srv_sync[1]; // MiSTer status[2] = Service Mode
		status[17:16]  <= bst_sync;    // MiSTer status[17:16] = Audio Boost
	end

	// -------------------------------------------------------------------------
	// 2. ROM Download CDC and Parser (clk_74a -> clk_sys)
	// -------------------------------------------------------------------------
	// Slot 1 writes hit bridge_addr < 0x0800_0000 (up to 128MB).
	// First 4 bridge words (16 bytes) are the header:
	//   Word 0 (addr 0x0):  Magic "TF3\x01"
	//   Word 1 (addr 0x4):  game_cfg[15:0] (low=idx1, high=idx2)
	//   Word 2 (addr 0x8):  rom_len[31:0]
	//   Word 3 (addr 0xC):  crc32[31:0]
	// Words from addr 0x10 onwards are payload.

	wire is_slot1 = (bridge_addr < 32'h0800_0000) && bridge_wr;
	wire is_header = is_slot1 && (bridge_addr < 32'h10);
	wire is_payload = is_slot1 && (bridge_addr >= 32'h10);

	reg [15:0] latched_cfg_74 = 16'd0;
	reg        header_seen_74 = 1'b0;

	always @(posedge clk_74a) begin
		if (is_header && (bridge_addr[3:0] == 4'h4)) begin
			latched_cfg_74 <= bridge_wr_data[15:0];
			header_seen_74 <= 1'b1;
		end
	end

	// Payload FIFO from clk_74a to clk_sys
	wire fifo_wr = is_payload;
	wire [31:0] fifo_din = bridge_wr_data;
	wire [31:0] fifo_dout;
	wire fifo_empty;
	wire fifo_full;
	reg  fifo_rd = 1'b0;

	reg fifo_ovf_74 = 1'b0;
	always @(posedge clk_74a) begin
		if (fifo_wr && fifo_full) fifo_ovf_74 <= 1'b1;
	end
	reg [1:0] ovf_sync = 2'd0;
	always @(posedge clk_sys) begin
		ovf_sync <= {ovf_sync[0], fifo_ovf_74};
		fifo_ovf <= ovf_sync[1];
	end

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(256),
		.lpm_showahead("ON"),
		.lpm_type("dcfifo"),
		.lpm_width(32),
		.lpm_widthu(8),
		.overflow_checking("ON"),
		.underflow_checking("OFF"),
		.use_eab("ON")
	) rom_fifo (
		.data(fifo_din), .wrclk(clk_74a), .wrreq(fifo_wr),
		.rdclk(clk_ram), .rdreq(fifo_rd), .q(fifo_dout),
		.rdempty(fifo_empty), .wrfull(fifo_full),
		.aclr(1'b0), .eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// Synchronize header arrival & dataslot completion to clk_ram
	reg [2:0] hdr_sync;
	reg [1:0] dsc_sync;
	always @(posedge clk_ram) begin
		hdr_sync <= {hdr_sync[1:0], header_seen_74};
		dsc_sync <= {dsc_sync[0], apf_dataslot_complete};
	end
	wire hdr_seen_ram     = hdr_sync[1];
	wire dsc_complete_ram = dsc_sync[1];

	// ioctl FSM on clk_ram (97.03 MHz, zero-CDC with SDRAM)
	localparam [3:0]
		S_IDLE        = 4'd0,
		S_CFG1        = 4'd1, // Emit index 1 (cfg low byte)
		S_CFG1_ACK    = 4'd2,
		S_CFG2        = 4'd3, // Emit index 2 (cfg high byte)
		S_CFG2_ACK    = 4'd4,
		S_LOAD_RD     = 4'd5, // Read FIFO
		S_LOAD_LAT    = 4'd6,
		S_LOAD_LO     = 4'd7, // Emit low 16-bit word
		S_LOAD_LO_INC = 4'd8,
		S_LOAD_HI     = 4'd9, // Emit high 16-bit word
		S_LOAD_HI_INC = 4'd10,
		S_RUN         = 4'd11;

	reg [3:0]  state = S_IDLE;
	reg [31:0] lat_word = 32'd0;
	reg [15:0] latched_cfg_ram = 16'd0;
	reg [7:0]  dsc_wait = 8'd0;

	always @(posedge clk_ram or negedge pll_locked) begin
		if (!pll_locked) begin
			state          <= S_IDLE;
			ioctl_download <= 1'b0;
			ioctl_wr       <= 1'b0;
			ioctl_index    <= 8'd0;
			ioctl_addr     <= 27'd0;
			ioctl_dout     <= 16'd0;
			fifo_rd        <= 1'b0;
			boot_done      <= 1'b0;
		end else begin
			fifo_rd  <= 1'b0;
			ioctl_wr <= 1'b0;

			case (state)
				S_IDLE: begin
					if (hdr_seen_ram) begin
						latched_cfg_ram <= latched_cfg_74;
						ioctl_download  <= 1'b1;
						state           <= S_CFG1;
					end
				end

				S_CFG1: begin
					ioctl_index <= 8'd1;
					ioctl_addr  <= 27'd0;
					ioctl_dout  <= {8'd0, latched_cfg_ram[7:0]};
					ioctl_wr    <= 1'b1;
					state       <= S_CFG1_ACK;
				end

				S_CFG1_ACK: begin
					if (!ioctl_wait) state <= S_CFG2;
				end

				S_CFG2: begin
					ioctl_index <= 8'd2;
					ioctl_addr  <= 27'd0;
					ioctl_dout  <= {8'd0, latched_cfg_ram[15:8]};
					ioctl_wr    <= 1'b1;
					state       <= S_CFG2_ACK;
				end

				S_CFG2_ACK: begin
					if (!ioctl_wait) begin
						ioctl_index <= 8'd0;
						ioctl_addr  <= 27'd0;
						state       <= S_LOAD_RD;
					end
				end

				S_LOAD_RD: begin
					if (!fifo_empty) begin
						dsc_wait <= 8'd0;
						lat_word <= fifo_dout;
						fifo_rd  <= 1'b1;
						state    <= S_LOAD_LO;
					end else if (dsc_complete_ram) begin
						if (&dsc_wait) state <= S_RUN;
						else dsc_wait <= dsc_wait + 8'd1;
					end
				end

				S_LOAD_LO: begin
					if (!ioctl_wait) begin
						ioctl_dout <= lat_word[15:0];
						ioctl_wr   <= 1'b1;
						state      <= S_LOAD_LO_INC;
					end
				end

				S_LOAD_LO_INC: begin
					ioctl_addr <= ioctl_addr + 27'd2;
					state      <= S_LOAD_HI;
				end

				S_LOAD_HI: begin
					if (!ioctl_wait) begin
						ioctl_dout <= lat_word[31:16];
						ioctl_wr   <= 1'b1;
						state      <= S_LOAD_HI_INC;
					end
				end

				S_LOAD_HI_INC: begin
					ioctl_addr <= ioctl_addr + 27'd2;
					if (!fifo_empty) begin
						dsc_wait <= 8'd0;
						lat_word <= fifo_dout;
						fifo_rd  <= 1'b1;
						state    <= S_LOAD_LO;
					end else begin
						state    <= S_LOAD_RD;
					end
				end

				S_RUN: begin
					ioctl_download <= 1'b0;
					boot_done      <= 1'b1;
				end
			endcase
		end
	end

	// -------------------------------------------------------------------------
	// 3. Controller mapping: APF pad_key -> MiSTer joystick_0
	// -------------------------------------------------------------------------
	// APF key layout:
	//   [0] dpad_up, [1] dpad_down, [2] dpad_left, [3] dpad_right
	//   [4] face_a, [5] face_b, [6] face_x, [7] face_y
	//   [8] trig_l1, [9] trig_r1, [10] trig_l2, [11] trig_r2
	//   [14] select, [15] start
	//
	// MiSTer joystick layout:
	//   [0] right, [1] left, [2] down, [3] up
	//   [4] Shot / Button 1
	//   [5] Bomb / Button 2
	//   [6] Button 3
	//   [7] Button 4
	//   [8] Button 5
	//   [9] Button 6
	//   [10] 1P Start
	//   [11] Coin
	//   [12] Service / Test
	//   [13] Pause
	always @(posedge clk_sys) begin
		joystick_0[0]  <= pad_key[3];  // Right
		joystick_0[1]  <= pad_key[2];  // Left
		joystick_0[2]  <= pad_key[1];  // Down
		joystick_0[3]  <= pad_key[0];  // Up
		joystick_0[4]  <= pad_key[7];  // Button 1 (Y)
		joystick_0[5]  <= pad_key[5];  // Button 2 (B)
		joystick_0[6]  <= pad_key[4];  // Button 3 (A)
		joystick_0[7]  <= pad_key[6];  // Button 4 (X)
		joystick_0[8]  <= pad_key[8];  // Button 5 (L)
		joystick_0[9]  <= pad_key[9];  // Button 6 (R)
		joystick_0[10] <= pad_key[15]; // Start
		joystick_0[11] <= pad_key[14]; // Select / Coin
		joystick_0[12] <= pad_key[10] | service_mode; // L2 / Service
		joystick_0[13] <= pad_key[15] & pad_key[14];  // Start+Select = Pause
	end

endmodule
`default_nettype wire
