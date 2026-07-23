/*
 * tt_um_ble_backscatter_modem.v — TinyTapeout 1x2 Tile Top Module Wrapper
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: §2, §6, §9.
 */

`default_nettype none

module tt_um_ble_backscatter_modem (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when design is powered
    input  wire       clk,      // clock (≤ 66 MHz)
    input  wire       rst_n     // reset_n - active low reset
);

  // Unused bidirectional inputs tap
  wire _unused_uio = &{uio_in, 1'b0};

  // Pin decoding per §6
  wire spi_sclk   = ui_in[0];
  wire spi_mosi   = ui_in[1];
  wire spi_cs_n   = ui_in[2];
  wire tx_start   = ui_in[3];
  wire mode_sel   = ui_in[4];
  wire [2:0] chan_quick = ui_in[7:5];

  wire [3:0] phase_ctrl;
  wire       tx_active;
  wire       sym_clk;
  wire       done;
  wire       irq;
  wire       spi_miso;
  wire [6:0] debug;

  // Instantiate core top-level
  ble_modem_top #(
      .CLK_FREQ_HZ(64_000_000),
      .SYMBOL_RATE_HZ(1_000_000),
      .F_SWITCH_HZ(16_000_000),
      .PHASE_COUNT(4)
  ) u_core (
      .clk       (clk),
      .rst_n     (rst_n),
      .ena       (ena),
      .spi_sclk  (spi_sclk),
      .spi_mosi  (spi_mosi),
      .spi_cs_n  (spi_cs_n),
      .spi_miso  (spi_miso),
      .tx_start  (tx_start),
      .mode_sel  (mode_sel),
      .chan_quick(chan_quick),
      .phase_ctrl(phase_ctrl),
      .tx_active (tx_active),
      .sym_clk   (sym_clk),
      .done      (done),
      .irq       (irq),
      .debug     (debug)
  );

  // Map dedicated outputs
  assign uo_out[3:0] = phase_ctrl;
  assign uo_out[4]   = tx_active;
  assign uo_out[5]   = sym_clk;
  assign uo_out[6]   = done;
  assign uo_out[7]   = irq;

  // Map bidirectional pins per §6:
  // uio[0] = spi_miso (out)
  // uio[7:1] = debug[6:0] (out)
  assign uio_out = {debug, spi_miso};
  assign uio_oe  = 8'hFF;  // all outputs driven

endmodule

`default_nettype wire
