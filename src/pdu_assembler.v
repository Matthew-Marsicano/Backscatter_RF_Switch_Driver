/*
 * pdu_assembler.v — advertising PDU field assembly (§4.1)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-1..FR-5.
 *
 * Combinational helper that presents the fixed preamble / access-address
 * constants and builds the 16-bit advertising PDU header from the config
 * registers.  Actual bit serialization (LSB-first) is performed by packet_fsm
 * which shifts these words out least-significant-bit first.
 *
 * Header layout [VERIFY against Core Spec Link Layer packet format]:
 *   byte0 = hdr0 = { RxAdd, TxAdd, ChSel, RFU, PDU_Type[3:0] }
 *   byte1 = length (payload byte count)
 * Transmitted byte0 first, each byte LSB-first.
 */

`default_nettype none

module pdu_assembler #(
    parameter [7:0]  PREAMBLE_VAL = 8'hAA,
    parameter [31:0] ACCESS_ADDR  = 32'h8E89BED6
) (
    input  wire [7:0]  hdr0,        // header byte 0 (type/flag bits)
    input  wire [7:0]  length,      // payload length in bytes
    output wire [7:0]  preamble,    // 1M PHY preamble
    output wire [31:0] access_addr, // advertising access address
    output wire [15:0] header       // {length, hdr0}: hdr0 shifted out first
);

  assign preamble    = PREAMBLE_VAL;
  assign access_addr = ACCESS_ADDR;
  assign header      = {length, hdr0};

endmodule

`default_nettype wire
