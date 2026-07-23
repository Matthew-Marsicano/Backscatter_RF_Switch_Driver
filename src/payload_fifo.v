/*
 * payload_fifo.v — small synchronous byte FIFO for streamed payload
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-29, §2 (streaming — NOT a full-PDU buffer), §11 non-goal.
 *
 * A few-byte FIFO (default depth 8 = 64 flops, far below the ~300-flop full-PDU
 * buffer that would force >=2 tiles).  The host pushes payload bytes over SPI;
 * the packet FSM pops them as it serializes.  If the FIFO underruns mid-packet
 * the FSM stalls the bit clock (backpressure) rather than emitting garbage — the
 * emitted BIT SEQUENCE is therefore independent of host timing, which is what
 * the golden-model check (V-2) compares.
 */

`default_nettype none

module payload_fifo #(
    parameter DEPTH = 8,          // must be a power of two
    parameter AW    = 3           // clog2(DEPTH)
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       flush,      // synchronous clear (start of packet)

    input  wire       wr_en,
    input  wire [7:0] wr_data,

    input  wire       rd_en,
    output wire [7:0] rd_data,

    output wire       empty,
    output wire       full,
    output wire [AW:0] count
);

  reg [7:0]   mem [0:DEPTH-1];
  reg [AW:0]  cnt;              // 0..DEPTH
  reg [AW-1:0] wr_ptr, rd_ptr;

  wire do_wr = wr_en && !full;
  wire do_rd = rd_en && !empty;

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= {AW{1'b0}};
      rd_ptr <= {AW{1'b0}};
      cnt    <= {(AW+1){1'b0}};
      for (i = 0; i < DEPTH; i = i + 1) mem[i] <= 8'h00;
    end else if (flush) begin
      wr_ptr <= {AW{1'b0}};
      rd_ptr <= {AW{1'b0}};
      cnt    <= {(AW+1){1'b0}};
    end else begin
      if (do_wr) begin
        mem[wr_ptr] <= wr_data;
        wr_ptr      <= wr_ptr + 1'b1;
      end
      if (do_rd) begin
        rd_ptr <= rd_ptr + 1'b1;
      end
      case ({do_wr, do_rd})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
        default: cnt <= cnt;   // 00 or simultaneous 11 -> unchanged
      endcase
    end
  end

  assign rd_data = mem[rd_ptr];
  assign empty   = (cnt == 0);
  assign full    = (cnt == DEPTH[AW:0]);
  assign count   = cnt;

endmodule

`default_nettype wire
