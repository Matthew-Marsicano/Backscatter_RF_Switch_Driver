/*
 * modulator.v — DSB-FSK / SSB harmonic-reject switch-control modulator (§4.5)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-18..FR-22.
 *
 * Mode 0 — DSB-FSK (baseline): a single switch line (phase_ctrl[0], with its
 *   complement on phase_ctrl[1]) is driven with a square wave whose frequency is
 *   keyed by the data bit (divider FSK_DIV0 vs FSK_DIV1).  Reflected energy sits
 *   at carrier +/- f_switch (double sideband, image not rejected).
 *
 * Mode 1 — SSB harmonic-reject (target novelty): PHASE_COUNT phase-shifted
 *   square waves approximate a rotating phasor; the SIGN of rotation (up/down)
 *   encodes the data bit, cancelling the image and concentrating reflected power
 *   in one BLE channel.  The tick rate is clk / PHASE_DIV so the phasor turns at
 *   f_switch = clk / (PHASE_COUNT * PHASE_DIV).
 *
 * Config A / Config B (host-selectable via {cfg_phase_sel[0]}, SPI PHASE_CFG
 * reg 0x04): two precomputed divider profiles, independent of {mode_ssb}.
 *   Config A (cfg_phase_sel[0]=0, default) — SSB @ 16 MHz; DSB keyed between
 *     16 MHz / 10.67 MHz (FSK_DIV0_A/FSK_DIV1_A).
 *   Config B (cfg_phase_sel[0]=1) — SSB unchanged (PHASE_DIV is already at its
 *     fastest achievable value from a 64 MHz clock); DSB keyed between
 *     32 MHz / 16 MHz (FSK_DIV0_B/FSK_DIV1_B), centered ~24 MHz. 64 MHz doesn't
 *     divide evenly by 2*24 MHz, so this is the nearest achievable integer-divided
 *     pair rather than a single fixed 24 MHz tone. cfg_phase_sel[1] is reserved.
 *
 * All outputs are registered inside phase_generator / here (FR-21).  When
 * {active} is low every control line is held at 0 (FR-26).
 */

`default_nettype none

module modulator #(
    parameter integer PHASE_COUNT = 4,
    parameter integer PW          = 2,   // $clog2(PHASE_COUNT)
    parameter integer PHASE_DIV_A = 1,   // Config A SSB tick divider = clk/(PC*f_switch)
    parameter integer FSK_DIV0_A  = 2,   // Config A DSB tick divider for data bit 0
    parameter integer FSK_DIV1_A  = 3,   // Config A DSB tick divider for data bit 1
    parameter integer PHASE_DIV_B = 1,   // Config B SSB tick divider
    parameter integer FSK_DIV0_B  = 1,   // Config B DSB tick divider for data bit 0
    parameter integer FSK_DIV1_B  = 2    // Config B DSB tick divider for data bit 1
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       active,        // tx in progress
    input  wire       mode_ssb,      // 1 = SSB, 0 = DSB-FSK
    input  wire [1:0] cfg_phase_sel, // [0]: 0 = Config A, 1 = Config B; [1] reserved
    input  wire       data_bit,      // current (whitened) data bit
    output reg  [3:0] phase_ctrl     // switch-control output lines
);

  // ---- programmable tick divider ----
  // Reload value depends on Config A/B, mode (SSB fixed per config) and data
  // (DSB freq-keys within the selected config).
  localparam integer DW = 16;
  reg  [DW-1:0] tcnt;
  wire cfg_b = cfg_phase_sel[0];
  wire [DW-1:0] phase_div = cfg_b ? PHASE_DIV_B[DW-1:0] : PHASE_DIV_A[DW-1:0];
  wire [DW-1:0] fsk_div0  = cfg_b ? FSK_DIV0_B[DW-1:0]  : FSK_DIV0_A[DW-1:0];
  wire [DW-1:0] fsk_div1  = cfg_b ? FSK_DIV1_B[DW-1:0]  : FSK_DIV1_A[DW-1:0];
  wire [DW-1:0] reload = mode_ssb ? phase_div
                                  : (data_bit ? fsk_div1 : fsk_div0);
  wire tick = (tcnt == {DW{1'b0}});

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)          tcnt <= {DW{1'b0}};
    else if (!active)    tcnt <= {DW{1'b0}};
    else if (tick)       tcnt <= (reload > 0) ? (reload - 1'b1) : {DW{1'b0}};
    else                 tcnt <= tcnt - 1'b1;
  end

  // ---- SSB multi-phase generator ----
  wire [PHASE_COUNT-1:0] phase_lines;
  phase_generator #(
      .PHASE_COUNT(PHASE_COUNT),
      .PW         (PW)
  ) u_phase (
      .clk        (clk),
      .rst_n      (rst_n),
      .active     (active),
      .tick       (tick),
      .up         (data_bit),     // rotation sign = data bit
      .phase_lines(phase_lines)
  );

  // ---- DSB square wave (toggles each tick) + complement ----
  reg dsb_sq;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)       dsb_sq <= 1'b0;
    else if (!active) dsb_sq <= 1'b0;
    else if (tick)    dsb_sq <= ~dsb_sq;
  end

  // ---- output mux (registered) ----
  // SSB drives up to 4 phase lines; DSB drives [0] and its complement on [1].
  wire [3:0] ssb_out;
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_ssb_map
      if (gi < PHASE_COUNT) assign ssb_out[gi] = phase_lines[gi];
      else                  assign ssb_out[gi] = 1'b0;
    end
  endgenerate
  wire [3:0] dsb_out = {2'b00, ~dsb_sq, dsb_sq};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)       phase_ctrl <= 4'b0000;
    else if (!active) phase_ctrl <= 4'b0000;
    else              phase_ctrl <= mode_ssb ? ssb_out : dsb_out;
  end

endmodule

`default_nettype wire
