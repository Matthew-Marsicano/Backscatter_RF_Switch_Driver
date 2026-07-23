/*
 * packet_fsm.v — transmit sequencer + on-the-fly CRC/whitening serializer (§4.6)
 * Copyright (c) 2026
 * SPDX-License-Identifier: Apache-2.0
 *
 * Spec refs: FR-23..FR-26, and the streaming datapath of §4.1/§4.2/§4.3.
 *
 * State flow: IDLE -> TX_PREAMBLE -> TX_ACCESS -> TX_HEADER -> TX_PAYLOAD ->
 *             TX_CRC -> DONE -> IDLE   (payload skipped when length == 0).
 *
 * The full PDU is NEVER buffered (§2, §11): each field lives only in a shift
 * register, CRC-24 and the whitening LFSR update per emitted bit, and payload
 * bytes are pulled from a small FIFO on the fly.  One data bit is emitted per
 * {sym_tick}; if the payload FIFO underruns the sequencer deasserts {run} so the
 * symbol clock freezes until the host supplies more (backpressure) — the emitted
 * bit sequence is therefore host-timing-independent, which is what the golden
 * model checks bit-for-bit (V-2).
 *
 * Whitening covers PDU header + payload + CRC; CRC covers header + payload only
 * (pre-whitening).  Preamble and access address are neither whitened nor CRC'd.
 */

`default_nettype none

module packet_fsm #(
    parameter [7:0]  PREAMBLE_VAL = 8'hAA,
    parameter [31:0] ACCESS_ADDR  = 32'h8E89BED6,
    parameter [23:0] CRC_INIT     = 24'h555555,
    parameter [23:0] CRC_MASK     = 24'hDA6000
) (
    input  wire        clk,
    input  wire        rst_n,        // synchronized reset (rst_sync_n)

    input  wire        tx_start,     // one-cycle trigger
    input  wire        repeat_en,    // re-transmit after DONE (stretch)

    // configuration snapshot
    input  wire [5:0]  cfg_chan,
    input  wire [7:0]  cfg_len,
    input  wire [7:0]  cfg_hdr0,

    // symbol timing
    output wire        run,          // enable to symbol_timing
    input  wire        sym_tick,     // one-clk pulse per symbol

    // payload FIFO
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output wire        fifo_rd_en,

    // outputs
    output wire        data_bit,     // whitened serial bit to the modulator
    output reg         tx_active,    // high during a packet (FR-22)
    output wire        busy,
    output reg         done
);

  // ---- states ----
  localparam [2:0] S_IDLE     = 3'd0,
                   S_PREAMBLE = 3'd1,
                   S_ACCESS   = 3'd2,
                   S_HEADER   = 3'd3,
                   S_PAYLOAD  = 3'd4,
                   S_CRC      = 3'd5,
                   S_DONE     = 3'd6;

  reg [2:0]  state;

  // ---- shift registers / counters ----
  reg [7:0]  pre_sr;
  reg [31:0] aa_sr;
  reg [15:0] hdr_sr;
  reg [7:0]  pay_sr;
  reg [23:0] crc_sr;
  reg        crc_loaded;

  reg [5:0]  bit_cnt;      // within preamble/access/header/crc
  reg [2:0]  byte_bit;     // within a payload byte

  reg [8:0]  len_l;        // latched payload length (bytes)
  reg [8:0]  pay_fetched;  // payload bytes popped from FIFO
  reg [8:0]  pay_done;     // payload bytes fully transmitted
  reg        pay_valid;    // pay_sr holds a live byte

  reg        pkt_load;     // one-cycle: (re)seed CRC + whitening at packet start

  // ---- header assembly ----
  wire [7:0]  preamble_w;
  wire [31:0] aa_w;
  wire [15:0] header_w;
  pdu_assembler #(
      .PREAMBLE_VAL(PREAMBLE_VAL),
      .ACCESS_ADDR (ACCESS_ADDR)
  ) u_pdu (
      .hdr0       (cfg_hdr0),
      .length     (cfg_len),
      .preamble   (preamble_w),
      .access_addr(aa_w),
      .header     (header_w)
  );

  // ---- raw (pre-whitening) bit source ----
  reg raw_bit;
  always @(*) begin
    case (state)
      S_PREAMBLE: raw_bit = pre_sr[0];
      S_ACCESS:   raw_bit = aa_sr[0];
      S_HEADER:   raw_bit = hdr_sr[0];
      S_PAYLOAD:  raw_bit = pay_sr[0];
      S_CRC:      raw_bit = crc_sr[0];
      default:    raw_bit = 1'b0;
    endcase
  end

  wire whiten_scope = (state == S_HEADER) || (state == S_PAYLOAD) || (state == S_CRC);
  wire crc_scope    = (state == S_HEADER) || (state == S_PAYLOAD);

  // ---- CRC-24 + whitening LFSR ----
  wire [23:0] crc_now;
  wire        whiten_out;

  crc24 #(.CRC_INIT(CRC_INIT), .CRC_MASK(CRC_MASK)) u_crc (
      .clk(clk), .rst_n(rst_n),
      .load(pkt_load),
      .en  (sym_tick && crc_scope),
      .data_bit(raw_bit),
      .crc (crc_now)
  );

  whitening_lfsr u_whiten (
      .clk(clk), .rst_n(rst_n),
      .load(pkt_load),
      .chan(cfg_chan),
      .en  (sym_tick && whiten_scope),
      .whiten_out(whiten_out)
  );

  assign data_bit = whiten_scope ? (raw_bit ^ whiten_out) : raw_bit;

  // ---- payload FIFO fetch (clk domain, between symbols) ----
  wire payload_need  = (state == S_PAYLOAD) && !pay_valid && (pay_fetched < len_l);
  assign fifo_rd_en  = payload_need && !fifo_empty;
  wire   payload_stall = payload_need && fifo_empty;

  assign run  = (state != S_IDLE) && (state != S_DONE) && !payload_stall;
  assign busy = (state != S_IDLE);

  // ---- main sequencer ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      pre_sr      <= 8'h00;
      aa_sr       <= 32'h0;
      hdr_sr      <= 16'h0;
      pay_sr      <= 8'h00;
      crc_sr      <= 24'h0;
      crc_loaded  <= 1'b0;
      bit_cnt     <= 6'd0;
      byte_bit    <= 3'd0;
      len_l       <= 9'd0;
      pay_fetched <= 9'd0;
      pay_done    <= 9'd0;
      pay_valid   <= 1'b0;
      pkt_load    <= 1'b0;
      tx_active   <= 1'b0;
      done        <= 1'b0;
    end else begin
      pkt_load <= 1'b0;  // default

      case (state)
        // ----------------------------------------------------------------
        S_IDLE: begin
          tx_active <= 1'b0;
          if (tx_start) begin
            // latch config, preload fields, seed CRC + whitening
            len_l       <= {1'b0, cfg_len};
            pre_sr      <= preamble_w;
            aa_sr       <= aa_w;
            hdr_sr      <= header_w;
            bit_cnt     <= 6'd0;
            byte_bit    <= 3'd0;
            pay_fetched <= 9'd0;
            pay_done    <= 9'd0;
            pay_valid   <= 1'b0;
            crc_loaded  <= 1'b0;
            pkt_load    <= 1'b1;
            tx_active   <= 1'b1;
            done        <= 1'b0;
            state       <= S_PREAMBLE;
          end
        end

        // ----------------------------------------------------------------
        S_PREAMBLE: if (sym_tick) begin
          pre_sr  <= {1'b0, pre_sr[7:1]};
          bit_cnt <= bit_cnt + 1'b1;
          if (bit_cnt == 6'd7) begin
            bit_cnt <= 6'd0;
            state   <= S_ACCESS;
          end
        end

        // ----------------------------------------------------------------
        S_ACCESS: if (sym_tick) begin
          aa_sr   <= {1'b0, aa_sr[31:1]};
          bit_cnt <= bit_cnt + 1'b1;
          if (bit_cnt == 6'd31) begin
            bit_cnt <= 6'd0;
            state   <= S_HEADER;
          end
        end

        // ----------------------------------------------------------------
        S_HEADER: if (sym_tick) begin
          hdr_sr  <= {1'b0, hdr_sr[15:1]};
          bit_cnt <= bit_cnt + 1'b1;
          if (bit_cnt == 6'd15) begin
            bit_cnt    <= 6'd0;
            crc_loaded <= 1'b0;
            if (len_l == 9'd0) state <= S_CRC;   // no payload
            else               state <= S_PAYLOAD;
          end
        end

        // ----------------------------------------------------------------
        S_PAYLOAD: begin
          // fast fetch of the next byte (independent of sym_tick)
          if (fifo_rd_en) begin
            pay_sr      <= fifo_rd_data;
            pay_valid   <= 1'b1;
            pay_fetched <= pay_fetched + 1'b1;
          end
          if (sym_tick) begin
            pay_sr   <= {1'b0, pay_sr[7:1]};
            byte_bit <= byte_bit + 1'b1;
            if (byte_bit == 3'd7) begin
              byte_bit  <= 3'd0;
              pay_valid <= 1'b0;               // request next byte
              pay_done  <= pay_done + 1'b1;
              if ((pay_done + 1'b1) == len_l) begin
                crc_loaded <= 1'b0;
                state      <= S_CRC;
              end
            end
          end
        end

        // ----------------------------------------------------------------
        S_CRC: begin
          if (!crc_loaded) begin
            crc_sr     <= crc_now;   // capture final remainder
            crc_loaded <= 1'b1;
          end else if (sym_tick) begin
            crc_sr  <= {1'b0, crc_sr[23:1]};
            bit_cnt <= bit_cnt + 1'b1;
            if (bit_cnt == 6'd23) begin
              bit_cnt <= 6'd0;
              state   <= S_DONE;
            end
          end
        end

        // ----------------------------------------------------------------
        S_DONE: begin
          tx_active <= 1'b0;
          done      <= 1'b1;
          if (repeat_en) begin
            // re-arm; host must re-stream payload for the next iteration
            len_l       <= {1'b0, cfg_len};
            pre_sr      <= preamble_w;
            aa_sr       <= aa_w;
            hdr_sr      <= header_w;
            bit_cnt     <= 6'd0;
            byte_bit    <= 3'd0;
            pay_fetched <= 9'd0;
            pay_done    <= 9'd0;
            pay_valid   <= 1'b0;
            crc_loaded  <= 1'b0;
            pkt_load    <= 1'b1;
            tx_active   <= 1'b1;
            done        <= 1'b0;
            state       <= S_PREAMBLE;
          end else begin
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
