/*
 * crc24.v — BLE CRC-24 LFSR (bit-serial, LSB-first)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-6..FR-10, §4.2.
 *
 * BLE CRC-24 polynomial: x^24 + x^10 + x^9 + x^6 + x^4 + x^3 + x + 1  [VERIFY]
 *   Forward poly (powers 0..23) = 0x00065B.
 *   For an LSB-first (right-shifting) LFSR the tap mask is the bit-reversal of
 *   the forward poly over 24 bits = 0xDA6000.  This matches the widely-used
 *   btle-tools / open-source BLE reference implementations.
 * Init value for advertising channels: 0x555555 [VERIFY].
 *
 * Bits are fed in transmit order (each byte LSB-first). After the last
 * header+payload bit is clocked in, {crc} holds the 24-bit remainder which is
 * transmitted LSB-first (crc[0] first) — see packet_fsm.
 *
 * This module is a pure register + combinational next-state; the parent asserts
 * {en} for exactly one clk per data bit that must be included in the CRC.
 */

`default_nettype none

module crc24 #(
    parameter [23:0] CRC_INIT = 24'h555555,
    parameter [23:0] CRC_MASK = 24'hDA6000   // bit-reversed poly, LSB-first form
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load,      // synchronous re-init to CRC_INIT
    input  wire        en,        // clock one data bit into the CRC
    input  wire        data_bit,  // pre-whitening data bit (LSB-first order)
    output wire [23:0] crc        // current 24-bit remainder
);

  reg [23:0] crc_r;

  wire       feedback = crc_r[0] ^ data_bit;
  // right shift: crc_r[i] <- crc_r[i+1], crc_r[23] <- 0, then conditional XOR
  wire [23:0] shifted = {1'b0, crc_r[23:1]};
  wire [23:0] next    = feedback ? (shifted ^ CRC_MASK) : shifted;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)      crc_r <= CRC_INIT;
    else if (load)   crc_r <= CRC_INIT;
    else if (en)     crc_r <= next;
  end

  assign crc = crc_r;

endmodule

`default_nettype wire
