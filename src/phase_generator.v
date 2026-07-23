/*
 * phase_generator.v — parameterized multi-phase square-wave generator (§4.5)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-19, FR-20, FR-21.
 *
 * Maintains a phase index that advances by one step per {tick}.  For each of the
 * PHASE_COUNT outputs, line k is high for the first half of the phase wheel
 * relative to position k, i.e. 50%-duty square waves evenly spaced by
 * 360/PHASE_COUNT degrees.  {up} selects the direction the index rotates — the
 * SSB modulator flips {up} with the data bit to swap the reflected sideband.
 *
 * All outputs are registered (FR-21): they only change on {tick}-driven index
 * updates, so there are no combinational hazards on the switch-control lines.
 * PHASE_COUNT must be a power of two (2, 4, 8) so the phase wheel wraps naturally
 * on the index width.
 */

`default_nettype none

module phase_generator #(
    parameter integer PHASE_COUNT = 4,
    parameter integer PW          = 2   // $clog2(PHASE_COUNT)
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    active,   // 0 -> lines forced to safe 0
    input  wire                    tick,     // advance the phase index
    input  wire                    up,       // 1 = index++, 0 = index--
    output reg  [PHASE_COUNT-1:0]  phase_lines
);

  reg [PW-1:0] pcnt;
  integer j;
  reg [PW-1:0] rel;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pcnt        <= {PW{1'b0}};
      phase_lines <= {PHASE_COUNT{1'b0}};
    end else if (!active) begin
      pcnt        <= {PW{1'b0}};
      phase_lines <= {PHASE_COUNT{1'b0}};   // safe state (FR-26)
    end else begin
      if (tick)
        pcnt <= up ? (pcnt + 1'b1) : (pcnt - 1'b1);

      for (j = 0; j < PHASE_COUNT; j = j + 1) begin
        // (pcnt - j) mod PHASE_COUNT < PHASE_COUNT/2  -> 50% duty, offset by j
        rel = pcnt - j[PW-1:0];
        phase_lines[j] <= (rel < (PHASE_COUNT/2));
      end
    end
  end

endmodule

`default_nettype wire
