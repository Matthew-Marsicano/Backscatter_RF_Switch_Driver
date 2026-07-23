/*
 * symbol_timing.v — clk -> 1 Mbit/s symbol clock + sync/scope output (§4.4)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-15..FR-17.
 *
 * Divides {clk} by SYMBOL_DIV = CLK_FREQ_HZ / SYMBOL_RATE_HZ.  Emits a
 * one-clk-wide {sym_tick} once per symbol period (the FSM advances one bit per
 * tick) and a 50%-ish-duty {sym_clk} for scope triggering (FR-17).
 *
 * When {run} is low the divider is frozen, so if the FSM stalls on a FIFO
 * underrun the symbol clock pauses in step with the data and stays aligned.
 */

`default_nettype none

module symbol_timing #(
    parameter integer SYMBOL_DIV = 64   // clk / symbol_rate
) (
    input  wire clk,
    input  wire rst_n,
    input  wire run,        // 1 = advance timing, 0 = freeze
    output reg  sym_tick,   // one-clk pulse at the start of each symbol
    output reg  sym_clk     // ~50% duty symbol-rate clock (scope sync)
);

  // width for the divider counter
  localparam integer CW = (SYMBOL_DIV <= 1)   ? 1 :
                          (SYMBOL_DIV <= 2)   ? 1 :
                          (SYMBOL_DIV <= 4)   ? 2 :
                          (SYMBOL_DIV <= 8)   ? 3 :
                          (SYMBOL_DIV <= 16)  ? 4 :
                          (SYMBOL_DIV <= 32)  ? 5 :
                          (SYMBOL_DIV <= 64)  ? 6 :
                          (SYMBOL_DIV <= 128) ? 7 :
                          (SYMBOL_DIV <= 256) ? 8 : 16;

  reg [CW-1:0] cnt;
  localparam [CW-1:0] LAST = SYMBOL_DIV[CW-1:0] - 1'b1;
  localparam [CW-1:0] HALF = (SYMBOL_DIV/2);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt      <= {CW{1'b0}};
      sym_tick <= 1'b0;
      sym_clk  <= 1'b0;
    end else if (!run) begin
      cnt      <= {CW{1'b0}};
      sym_tick <= 1'b0;
      sym_clk  <= 1'b0;
    end else begin
      if (cnt == LAST) begin
        cnt      <= {CW{1'b0}};
        sym_tick <= 1'b1;      // pulse at symbol boundary
      end else begin
        cnt      <= cnt + 1'b1;
        sym_tick <= 1'b0;
      end
      sym_clk <= (cnt < HALF) ? 1'b1 : 1'b0;
    end
  end

endmodule

`default_nettype wire
