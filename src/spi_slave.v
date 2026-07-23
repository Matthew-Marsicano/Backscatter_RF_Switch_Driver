/*
 * spi_slave.v — oversampled SPI slave (config + payload stream + status readback)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-27..FR-29, §4.7, §7.
 *
 * SPI mode 0 (CPOL=0, CPHA=0), MSB-first on the wire.  The bus pins are already
 * double-flop synchronized (see sync_reset), so this block simply oversamples
 * them in the {clk} domain and detects sclk edges — keeping the whole design in
 * a single clock domain (NFR-2).  The host clock must stay well below clk/4.
 *
 * Wire protocol (one transaction per CS-low window):
 *   Byte 0 : command  = { rw, addr[6:0] }   rw=1 write, rw=0 read
 *   Byte 1+: data bytes.
 *     - write, addr <  PAYLOAD_ADDR : reg[addr] <= data; addr auto-increments.
 *     - write, addr >= PAYLOAD_ADDR : push data into the payload FIFO (addr held,
 *                                     so a long burst streams payload bytes).
 *     - read : reg[addr] shifts out on MISO (MSB first); addr auto-increments.
 */

`default_nettype none

module spi_slave #(
    parameter [6:0] PAYLOAD_ADDR = 7'h08
) (
    input  wire       clk,
    input  wire       rst_n,

    // synchronized SPI pins
    input  wire       sclk,
    input  wire       mosi,
    input  wire       cs_n,
    output reg        miso,

    // register-file interface
    output wire [6:0] reg_rd_addr,    // combinational read pointer
    input  wire [7:0] reg_rd_data,    // combinational reg[reg_rd_addr]
    output reg        reg_wr_en,
    output reg  [6:0] reg_wr_addr,
    output reg  [7:0] reg_wr_data,

    // payload FIFO push
    output reg        pay_wr_en,
    output reg  [7:0] pay_wr_data
);

  // ---- oversampled edge detection ----
  reg sclk_d;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) sclk_d <= 1'b0; else sclk_d <= sclk;
  wire sclk_rise = (sclk == 1'b1) && (sclk_d == 1'b0);
  wire sclk_fall = (sclk == 1'b0) && (sclk_d == 1'b1);
  wire active    = ~cs_n;

  // ---- byte assembly ----
  reg [2:0] bit_cnt;     // bits received within current byte
  reg [7:0] rx_shift;    // MSB-first receive shift register
  reg [7:0] tx_shift;    // MSB-first transmit shift register
  reg       have_cmd;    // command byte already captured
  reg       rw;          // 1=write 0=read
  reg [6:0] addr;        // current (auto-incrementing) pointer

  assign reg_rd_addr = addr;

  wire [7:0] rx_byte = {rx_shift[6:0], mosi}; // completed byte on the 8th rising edge

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bit_cnt     <= 3'd0;
      rx_shift    <= 8'h00;
      tx_shift    <= 8'h00;
      have_cmd    <= 1'b0;
      rw          <= 1'b0;
      addr        <= 7'h00;
      miso        <= 1'b0;
      reg_wr_en   <= 1'b0;
      reg_wr_addr <= 7'h00;
      reg_wr_data <= 8'h00;
      pay_wr_en   <= 1'b0;
      pay_wr_data <= 8'h00;
    end else begin
      // single-cycle strobes default low
      reg_wr_en <= 1'b0;
      pay_wr_en <= 1'b0;

      if (!active) begin
        bit_cnt  <= 3'd0;
        have_cmd <= 1'b0;
        miso     <= 1'b0;
      end else begin
        if (sclk_rise) begin
          rx_shift <= {rx_shift[6:0], mosi};
          bit_cnt  <= bit_cnt + 1'b1;

          if (bit_cnt == 3'd7) begin
            bit_cnt <= 3'd0;
            if (!have_cmd) begin
              have_cmd <= 1'b1;
              rw       <= rx_byte[7];
              addr     <= rx_byte[6:0];
            end else begin
              if (rw) begin
                if (addr >= PAYLOAD_ADDR) begin
                  pay_wr_en   <= 1'b1;
                  pay_wr_data <= rx_byte;      // hold addr: stream into FIFO
                end else begin
                  reg_wr_en   <= 1'b1;
                  reg_wr_addr <= addr;
                  reg_wr_data <= rx_byte;
                  addr        <= addr + 1'b1;
                end
              end else begin
                addr <= addr + 1'b1;           // read burst auto-increment
              end
            end
          end
        end

        if (sclk_fall) begin
          if (bit_cnt == 3'd0) begin
            tx_shift <= {reg_rd_data[6:0], 1'b0};
            miso     <= reg_rd_data[7];
          end else begin
            miso     <= tx_shift[7];
            tx_shift <= {tx_shift[6:0], 1'b0};
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
