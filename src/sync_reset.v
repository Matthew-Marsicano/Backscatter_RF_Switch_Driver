/*
 * sync_reset.v — reset handling + async-input double-flop synchronizers
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: NFR-2 (double-flop synchronize async inputs), FR-26 (ena low ->
 * IDLE), §2 (active-low rst_n).
 *
 * All external inputs that are asynchronous to {clk} (SPI pins, tx_start,
 * mode/channel selects) are 2-flop synchronized here.  {rst_sync_n} is the
 * combined reset: asserted (low) when rst_n is low OR ena is low, so dropping
 * {ena} returns the whole design to its idle state (FR-26).
 */

`default_nettype none

module sync_reset (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,

    // raw asynchronous inputs
    input  wire       spi_sclk_a,
    input  wire       spi_mosi_a,
    input  wire       spi_cs_n_a,
    input  wire       tx_start_a,
    input  wire       mode_sel_a,
    input  wire [2:0] chan_quick_a,

    // synchronized outputs (in clk domain)
    output reg        rst_sync_n,
    output reg        spi_sclk_s,
    output reg        spi_mosi_s,
    output reg        spi_cs_n_s,
    output reg        tx_start_s,
    output reg        mode_sel_s,
    output reg  [2:0] chan_quick_s
);

  // --- reset synchronizer (async assert, sync deassert) ---
  reg meta_rst;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      meta_rst   <= 1'b0;
      rst_sync_n <= 1'b0;
    end else begin
      meta_rst   <= 1'b1;
      rst_sync_n <= meta_rst & ena;  // ena low forces reset-active
    end
  end

  // --- data input synchronizers ---
  reg        sclk_m,  mosi_m,  cs_n_m,  txs_m,  mode_m;
  reg  [2:0] chan_m;

  always @(posedge clk or negedge rst_sync_n) begin
    if (!rst_sync_n) begin
      sclk_m       <= 1'b0;  spi_sclk_s   <= 1'b0;
      mosi_m       <= 1'b0;  spi_mosi_s   <= 1'b0;
      cs_n_m       <= 1'b1;  spi_cs_n_s   <= 1'b1;   // idle high (deselected)
      txs_m        <= 1'b0;  tx_start_s   <= 1'b0;
      mode_m       <= 1'b0;  mode_sel_s   <= 1'b0;
      chan_m       <= 3'd0;  chan_quick_s <= 3'd0;
    end else begin
      sclk_m       <= spi_sclk_a;   spi_sclk_s   <= sclk_m;
      mosi_m       <= spi_mosi_a;   spi_mosi_s   <= mosi_m;
      cs_n_m       <= spi_cs_n_a;   spi_cs_n_s   <= cs_n_m;
      txs_m        <= tx_start_a;   tx_start_s   <= txs_m;
      mode_m       <= mode_sel_a;   mode_sel_s   <= mode_m;
      chan_m       <= chan_quick_a; chan_quick_s <= chan_m;
    end
  end

endmodule

`default_nettype wire
