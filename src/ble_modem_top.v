/*
 * ble_modem_top.v — Top-level digital baseband and backscatter-switch controller
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: §9, §4, §3, §8.
 *
 * Integrates sync_reset, spi_slave, config_regs, payload_fifo,
 * packet_fsm, symbol_timing, and modulator into a single top-level.
 */

`default_nettype none

module ble_modem_top #(
    parameter integer CLK_FREQ_HZ        = 64_000_000,
    parameter integer SYMBOL_RATE_HZ     = 1_000_000,
    parameter integer F_SWITCH_HZ        = 16_000_000,
    parameter integer PHASE_COUNT        = 4,
    parameter integer MAX_PAYLOAD_BYTES  = 37,
    parameter [31:0]  ACCESS_ADDR        = 32'h8E89BED6,
    parameter [7:0]   PREAMBLE           = 8'hAA,
    parameter [23:0]  CRC_INIT           = 24'h555555,
    parameter [23:0]  CRC_MASK           = 24'hDA6000,
    parameter integer ENABLE_REPEAT      = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,

    // SPI interface (asynchronous inputs, synchronized internally)
    input  wire       spi_sclk,
    input  wire       spi_mosi,
    input  wire       spi_cs_n,
    output wire       spi_miso,

    // Control inputs
    input  wire       tx_start,
    input  wire       mode_sel,
    input  wire [2:0] chan_quick,

    // Control & RF phase outputs
    output wire [3:0] phase_ctrl,
    output wire       tx_active,
    output wire       sym_clk,
    output wire       done,
    output wire       irq,
    output wire [6:0] debug
);

  // ---- Calculated Dividers ----
  localparam integer SYMBOL_DIV = CLK_FREQ_HZ / SYMBOL_RATE_HZ;
  localparam integer PW         = (PHASE_COUNT <= 2) ? 1 : ((PHASE_COUNT <= 4) ? 2 : 3);

  // Config A (default): SSB @ F_SWITCH_HZ (16 MHz); DSB keyed around F_SWITCH_HZ.
  localparam integer PHASE_DIV_A = CLK_FREQ_HZ / (PHASE_COUNT * F_SWITCH_HZ);
  localparam integer FSK_DIV0_A  = (CLK_FREQ_HZ / (2 * F_SWITCH_HZ)) > 0 ? (CLK_FREQ_HZ / (2 * F_SWITCH_HZ)) : 1;
  localparam integer FSK_DIV1_A  = FSK_DIV0_A + 1;

  // Config B (host-selectable via SPI PHASE_CFG reg 0x04, bit 0): SSB unchanged
  // (PHASE_DIV_A is already the fastest achievable divider from this clock);
  // DSB keyed between the two fastest achievable tones (32 MHz / 16 MHz from a
  // 64 MHz clock), centered ~24 MHz -- 64 MHz has no exact integer divider for
  // 2*24 MHz.
  localparam integer PHASE_DIV_B = PHASE_DIV_A;
  localparam integer FSK_DIV0_B  = 1;
  localparam integer FSK_DIV1_B  = 2;

  // ---- Build-time parameter assertions (FR-3 checks) ----
  initial begin
    if (CLK_FREQ_HZ > 66_000_000) begin
      $display("ERROR: CLK_FREQ_HZ (%0d Hz) exceeds TinyTapeout 66 MHz ceiling!", CLK_FREQ_HZ);
      $finish;
    end
    if (CLK_FREQ_HZ < PHASE_COUNT * F_SWITCH_HZ) begin
      $display("ERROR: CLK_FREQ_HZ (%0d Hz) must be >= PHASE_COUNT * F_SWITCH_HZ (%0d Hz)!",
               CLK_FREQ_HZ, PHASE_COUNT * F_SWITCH_HZ);
      $finish;
    end
    if ((CLK_FREQ_HZ % SYMBOL_RATE_HZ) != 0) begin
      $display("WARNING: CLK_FREQ_HZ / SYMBOL_RATE_HZ has non-zero remainder.");
    end
    if ((CLK_FREQ_HZ % (PHASE_COUNT * F_SWITCH_HZ)) != 0) begin
      $display("WARNING: CLK_FREQ_HZ / (PHASE_COUNT * F_SWITCH_HZ) has non-zero remainder.");
    end
  end

  // ---- Input Synchronizer & Reset Handler ----
  wire rst_sync_n;
  wire spi_sclk_s, spi_mosi_s, spi_cs_n_s;
  wire tx_start_s, mode_sel_s;
  wire [2:0] chan_quick_s;

  sync_reset u_sync (
      .clk         (clk),
      .rst_n       (rst_n),
      .ena         (ena),
      .spi_sclk_a  (spi_sclk),
      .spi_mosi_a  (spi_mosi),
      .spi_cs_n_a  (spi_cs_n),
      .tx_start_a  (tx_start),
      .mode_sel_a  (mode_sel),
      .chan_quick_a(chan_quick),
      .rst_sync_n  (rst_sync_n),
      .spi_sclk_s  (spi_sclk_s),
      .spi_mosi_s  (spi_mosi_s),
      .spi_cs_n_s  (spi_cs_n_s),
      .tx_start_s  (tx_start_s),
      .mode_sel_s  (mode_sel_s),
      .chan_quick_s(chan_quick_s)
  );

  // ---- SPI Slave Interface ----
  wire [6:0] reg_rd_addr;
  wire [7:0] reg_rd_data;
  wire       reg_wr_en;
  wire [6:0] reg_wr_addr;
  wire [7:0] reg_wr_data;
  wire       pay_wr_en;
  wire [7:0] pay_wr_data;

  spi_slave u_spi (
      .clk        (clk),
      .rst_n      (rst_sync_n),
      .sclk       (spi_sclk_s),
      .mosi       (spi_mosi_s),
      .cs_n       (spi_cs_n_s),
      .miso       (spi_miso),
      .reg_rd_addr(reg_rd_addr),
      .reg_rd_data(reg_rd_data),
      .reg_wr_en  (reg_wr_en),
      .reg_wr_addr(reg_wr_addr),
      .reg_wr_data(reg_wr_data),
      .pay_wr_en  (pay_wr_en),
      .pay_wr_data(pay_wr_data)
  );

  // ---- Configuration Registers ----
  wire       busy, done_int;
  wire       fifo_full, fifo_empty;
  wire       cfg_mode_sel, cfg_repeat_en, cfg_tx_start;
  wire [5:0] cfg_chan;
  wire [7:0] cfg_len, cfg_hdr0;
  wire [1:0] cfg_phase_sel;

  config_regs u_cfg (
      .clk          (clk),
      .rst_n        (rst_sync_n),
      .reg_wr_en    (reg_wr_en),
      .reg_wr_addr  (reg_wr_addr),
      .reg_wr_data  (reg_wr_data),
      .reg_rd_addr  (reg_rd_addr),
      .reg_rd_data  (reg_rd_data),
      .busy         (busy),
      .done         (done_int),
      .fifo_full    (fifo_full),
      .cfg_mode_sel (cfg_mode_sel),
      .cfg_repeat_en(cfg_repeat_en),
      .cfg_chan     (cfg_chan),
      .cfg_len      (cfg_len),
      .cfg_phase_sel(cfg_phase_sel),
      .cfg_hdr0     (cfg_hdr0),
      .cfg_tx_start (cfg_tx_start)
  );

  // Combine pin and config register control sources
  wire effective_mode_sel = mode_sel_s | cfg_mode_sel;
  wire effective_tx_start = tx_start_s | cfg_tx_start;
  wire effective_repeat   = (ENABLE_REPEAT != 0) | cfg_repeat_en;
  wire [5:0] effective_chan = (chan_quick_s == 3'd1) ? 6'd37 :
                              (chan_quick_s == 3'd2) ? 6'd38 :
                              (chan_quick_s == 3'd3) ? 6'd39 :
                              (chan_quick_s != 3'd0) ? (6'd36 + {3'b0, chan_quick_s}) :
                              cfg_chan;

  // ---- Payload Streaming FIFO ----
  wire       fifo_rd_en;
  wire [7:0] fifo_rd_data;
  wire [3:0] fifo_count;

  payload_fifo #(
      .DEPTH(8),
      .AW   (3)
  ) u_fifo (
      .clk    (clk),
      .rst_n  (rst_sync_n),
      .flush  (1'b0),
      .wr_en  (pay_wr_en),
      .wr_data(pay_wr_data),
      .rd_en  (fifo_rd_en),
      .rd_data(fifo_rd_data),
      .empty  (fifo_empty),
      .full   (fifo_full),
      .count  (fifo_count)
  );

  // ---- Symbol Timing ----
  wire run_fsm;
  wire sym_tick;
  wire sym_clk_scope;  // 50% duty scope clock from symbol_timing (unused, sym_tick used instead)

  symbol_timing #(
      .SYMBOL_DIV(SYMBOL_DIV)
  ) u_sym (
      .clk     (clk),
      .rst_n   (rst_sync_n),
      .run     (run_fsm),
      .sym_tick(sym_tick),
      .sym_clk (sym_clk_scope)
  );

  // ---- Packet Sequencer FSM ----
  wire data_bit, tx_active_int;

  packet_fsm #(
      .PREAMBLE_VAL(PREAMBLE),
      .ACCESS_ADDR (ACCESS_ADDR),
      .CRC_INIT    (CRC_INIT),
      .CRC_MASK    (CRC_MASK)
  ) u_fsm (
      .clk         (clk),
      .rst_n       (rst_sync_n),
      .tx_start    (effective_tx_start),
      .repeat_en   (effective_repeat),
      .cfg_chan    (effective_chan),
      .cfg_len     (cfg_len),
      .cfg_hdr0    (cfg_hdr0),
      .run         (run_fsm),
      .sym_tick    (sym_tick),
      .fifo_empty  (fifo_empty),
      .fifo_rd_data(fifo_rd_data),
      .fifo_rd_en  (fifo_rd_en),
      .data_bit    (data_bit),
      .tx_active   (tx_active_int),
      .busy        (busy),
      .done        (done_int)
  );

  // ---- Modulator ----
  modulator #(
      .PHASE_COUNT(PHASE_COUNT),
      .PW         (PW),
      .PHASE_DIV_A(PHASE_DIV_A),
      .FSK_DIV0_A (FSK_DIV0_A),
      .FSK_DIV1_A (FSK_DIV1_A),
      .PHASE_DIV_B(PHASE_DIV_B),
      .FSK_DIV0_B (FSK_DIV0_B),
      .FSK_DIV1_B (FSK_DIV1_B)
  ) u_mod (
      .clk           (clk),
      .rst_n         (rst_sync_n),
      .active        (tx_active_int),
      .mode_ssb      (effective_mode_sel),
      .cfg_phase_sel (cfg_phase_sel),
      .data_bit      (data_bit),
      .phase_ctrl    (phase_ctrl)
  );

  // ---- Output Assignments ----
  assign tx_active = tx_active_int;
  assign done      = done_int;
  assign irq       = done_int | fifo_full;
  assign sym_clk   = sym_tick;  // expose sym_tick directly for testbench sampling

  // Debug taps for scope/logic analyzer observation
  assign debug = {data_bit, run_fsm, busy, fifo_empty, fifo_full, done_int, tx_active_int};

endmodule

`default_nettype wire

