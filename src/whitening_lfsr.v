/*
 * whitening_lfsr.v — BLE data-whitening LFSR (7-bit, channel-seeded)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-11..FR-14, §4.3.
 *
 * Polynomial x^7 + x^4 + 1  [VERIFY].
 * Seed (init) convention used here [VERIFY exact bit ordering against Core Spec]:
 *   w[0] = 1
 *   w[1] = chan[5] (MSB of 6-bit channel index)
 *   w[2] = chan[4]
 *   w[3] = chan[3]
 *   w[4] = chan[2]
 *   w[5] = chan[1]
 *   w[6] = chan[0] (LSB)
 *
 * Per whitened bit the register advances (output taken from w[6], feedback into
 * w[0] and the x^4 tap):
 *   out  = w[6]
 *   fb   = w[6]
 *   w[6] = w[5]; w[5] = w[4]; w[4] = w[3]^fb; w[3] = w[2];
 *   w[2] = w[1]; w[1] = w[0]; w[0] = fb;
 *
 * whitened_bit = data_bit ^ out.  The Python golden model uses this EXACT
 * algorithm so the DUT and reference match bit-for-bit (V-2).
 */

`default_nettype none

module whitening_lfsr (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       load,       // synchronous seed load from {chan}
    input  wire [5:0] chan,       // channel index 0..39
    input  wire       en,         // advance one bit
    output wire       whiten_out  // current whitening bit (= w[6])
);

  reg [6:0] w;

  wire fb = w[6];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w <= 7'b0000001;  // safe idle: position 0 = 1
    end else if (load) begin
      w[0] <= 1'b1;
      w[1] <= chan[5];
      w[2] <= chan[4];
      w[3] <= chan[3];
      w[4] <= chan[2];
      w[5] <= chan[1];
      w[6] <= chan[0];
    end else if (en) begin
      w[6] <= w[5];
      w[5] <= w[4];
      w[4] <= w[3] ^ fb;
      w[3] <= w[2];
      w[2] <= w[1];
      w[1] <= w[0];
      w[0] <= fb;
    end
  end

  assign whiten_out = w[6];

endmodule

`default_nettype wire
