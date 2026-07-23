/*
 * config_regs.v — SPI-accessed configuration register file (§7)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Register map (8-bit address, 8-bit data):
 *   0x00 CTRL   [0] tx_start (W1, self-clearing) [1] mode_sel [2] repeat_en
 *   0x01 STATUS [0] busy [1] done [2] fifo_full   (read-only)
 *   0x02 CHAN   [5:0] channel_index (0..39)
 *   0x03 LEN    [7:0] payload length in bytes
 *   0x04 PHASE_CFG [1:0] phase-count select, [7:2] rsvd (documentation/debug)
 *   0x05 PDU_HDR   PDU header type/flag bits (byte 0 of the 16-bit header)
 *   0x08+ PAYLOAD   streaming FIFO write port (handled outside this module)
 */

`default_nettype none

module config_regs (
    input  wire       clk,
    input  wire       rst_n,

    // write port (from spi_slave)
    input  wire       reg_wr_en,
    input  wire [6:0] reg_wr_addr,
    input  wire [7:0] reg_wr_data,

    // read port (combinational)
    input  wire [6:0] reg_rd_addr,
    output reg  [7:0] reg_rd_data,

    // live status inputs (for STATUS read-back)
    input  wire       busy,
    input  wire       done,
    input  wire       fifo_full,

    // configuration outputs
    output reg        cfg_mode_sel,
    output reg        cfg_repeat_en,
    output reg  [5:0] cfg_chan,
    output reg  [7:0] cfg_len,
    output reg  [1:0] cfg_phase_sel,
    output reg  [7:0] cfg_hdr0,

    // one-cycle trigger from a CTRL write with bit0 set (FR-24)
    output reg        cfg_tx_start
);

  localparam [6:0] A_CTRL   = 7'h00;
  localparam [6:0] A_STATUS = 7'h01;
  localparam [6:0] A_CHAN   = 7'h02;
  localparam [6:0] A_LEN    = 7'h03;
  localparam [6:0] A_PHASE  = 7'h04;
  localparam [6:0] A_HDR    = 7'h05;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_mode_sel  <= 1'b0;
      cfg_repeat_en <= 1'b0;
      cfg_chan      <= 6'd37;      // default advertising channel 37
      cfg_len       <= 8'd0;
      cfg_phase_sel <= 2'd0;
      cfg_hdr0      <= 8'h02;      // default ADV_NONCONN_IND type=0x2 [VERIFY]
      cfg_tx_start  <= 1'b0;
    end else begin
      cfg_tx_start <= 1'b0;        // pulse
      if (reg_wr_en) begin
        case (reg_wr_addr)
          A_CTRL: begin
            cfg_tx_start  <= reg_wr_data[0];
            cfg_mode_sel  <= reg_wr_data[1];
            cfg_repeat_en <= reg_wr_data[2];
          end
          A_CHAN:  cfg_chan      <= reg_wr_data[5:0];
          A_LEN:   cfg_len       <= reg_wr_data;
          A_PHASE: cfg_phase_sel <= reg_wr_data[1:0];
          A_HDR:   cfg_hdr0      <= reg_wr_data;
          default: ; // payload / rsvd handled elsewhere
        endcase
      end
    end
  end

  // combinational read mux
  always @(*) begin
    case (reg_rd_addr)
      A_CTRL:   reg_rd_data = {5'b0, cfg_repeat_en, cfg_mode_sel, 1'b0};
      A_STATUS: reg_rd_data = {5'b0, fifo_full, done, busy};
      A_CHAN:   reg_rd_data = {2'b0, cfg_chan};
      A_LEN:    reg_rd_data = cfg_len;
      A_PHASE:  reg_rd_data = {6'b0, cfg_phase_sel};
      A_HDR:    reg_rd_data = cfg_hdr0;
      default:  reg_rd_data = 8'h00;
    endcase
  end

endmodule

`default_nettype wire
