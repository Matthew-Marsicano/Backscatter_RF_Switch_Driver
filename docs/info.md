# BLE Backscatter Modem — TinyTapeout Datasheet

## How it Works

This chip is the **digital baseband and multi-phase backscatter RF-switch controller** for a Bluetooth Low Energy (BLE) backscatter tag. It accepts advertising-packet payload bytes from a host MCU over SPI, assembles a spec-valid BLE advertising PDU (Preamble + Access Address + PDU Header + Payload + CRC-24 + Whitening), and drives 4 off-chip RF switch control lines (`phase_ctrl[3:0]`) with the modulation waveform needed to reflect an externally supplied single-tone carrier into a target BLE channel.

```
       +-------------------------------------------------------------+
       | TinyTapeout Digital Tile (1x2)                              |
       |                                                             |
SPI -->|  [SPI Slave] -> [Config Regs] -> [Payload FIFO]          |
       |                                       |                     |
       |  [Symbol Timing] <- [Packet FSM] <-----+                    |
       |         |                 |                                 |
       |         |          [CRC-24 + Whitening]                     |
       |         v                 v                                 |
       |  [Modulator (DSB/SSB)] <-- bitstream                        |
       |         |                                                   |
       +---------|---------------------------------------------------+
                 v
          phase_ctrl[3:0] --> (Off-chip RF Switch / Antenna)
```

---

## Operating Modes

1. **Mode 1 — SSB Harmonic-Reject (Default Novelty)**:
   Drives `PHASE_COUNT` phase-shifted 50%-duty square wave lines approximating a rotating phasor. The sign of phase rotation (up/down) encodes the data bit, suppressing the mirror image and concentrating reflected energy into a single target BLE advertising channel.
   - Recommended clock/carrier setup (Config A): System clock `CLK_FREQ_HZ = 64 MHz`, single-tone carrier placed ~16 MHz away from target advertising channel 37 (2402 MHz), subcarrier `f_switch = 16 MHz`.

2. **Mode 0 — DSB-FSK (Baseline)**:
   Drives a single switch control line (`phase_ctrl[0]`, with its complement on `phase_ctrl[1]`) with a square wave whose frequency keys between two values based on the data bit value. Reflected energy appears at carrier ± `f_switch` (double sideband).

`mode_sel` (waveform shape: SSB vs DSB-FSK) and `PHASE_CFG[0]` (Config A vs Config B divider set) are independent, runtime-switchable controls — see `modulator.v`. Config A is the SSB-at-16-MHz / DSB-FSK-keyed-16-MHz⁄10.67-MHz default; Config B keeps the SSB rate (already at the fastest divider this clock supports) but switches DSB-FSK to key between 32 MHz and 16 MHz (~24 MHz center — the nearest achievable pair, since 64 MHz has no exact integer divider for 2×24 MHz).

---

## Pinout Map

| Pin | Type | Name | Description |
|---|---|---|---|
| `ui_in[0]` | Input | `spi_sclk` | SPI Serial Clock |
| `ui_in[1]` | Input | `spi_mosi` | SPI Master Out Slave In |
| `ui_in[2]` | Input | `spi_cs_n` | SPI Chip Select (Active Low) |
| `ui_in[3]` | Input | `tx_start` | Pulse to start transmission |
| `ui_in[4]` | Input | `mode_sel` | Mode select: 0 = DSB-FSK, 1 = 4-Phase SSB |
| `ui_in[7:5]` | Input | `chan_quick[2:0]` | Quick channel select (001=ch37, 010=ch38, 011=ch39) |
| `uo_out[3:0]` | Output | `phase_ctrl[3:0]` | RF switch control phase lines |
| `uo_out[4]` | Output | `tx_active` | High during packet transmission |
| `uo_out[5]` | Output | `sym_clk` | 1 MHz derived symbol clock (scope sync) |
| `uo_out[6]` | Output | `done` | Transmission complete pulse |
| `uo_out[7]` | Output | `irq` | Interrupt / FIFO status output |
| `uio[0]` | Output | `spi_miso` | SPI status readback |
| `uio[7:1]` | Output | `debug[6:0]` | Internal taps (`data_bit`, `run`, `busy`, `fifo_empty`, `fifo_full`, `done`, `tx_active`) |

---

## SPI Register Map (8-Bit Address, 8-Bit Data, SPI Mode 0)

| Address | Name | Access | Bit Description |
|---|---|---|---|
| `0x00` | `CTRL` | W1S / RW | `[0]` `tx_start` (trigger), `[1]` `mode_sel`, `[2]` `repeat_en` |
| `0x01` | `STATUS` | RO | `[0]` `busy`, `[1]` `done`, `[2]` `fifo_full` |
| `0x02` | `CHAN` | RW | `[5:0]` Channel Index (0..39, default 37) |
| `0x03` | `LEN` | RW | `[7:0]` Payload Length in bytes (0..37) |
| `0x04` | `PHASE_CFG` | RW | `[0]` Config A/B select (0=Config A, default; 1=Config B), `[1]` reserved |
| `0x05` | `PDU_HDR` | RW | `[7:0]` Header byte 0 (PDU Type & Flag bits) |
| `0x08`+ | `PAYLOAD` | WO | Streaming payload byte FIFO write port |

---

## Decodability & Expected On-Air Packet

A commercial BLE receiver (smartphone, Nordic nRF52, Ubertooth) positioned near the tag and illuminated by an unmodulated RF carrier (e.g. 2418.000 MHz) will decode the reflected backscatter waveform as a standard BLE advertising packet:
- **Preamble**: `0xAA` (8 bits)
- **Access Address**: `0x8E89BED6` (32 bits, LSB-first)
- **PDU Header**: Type (e.g. `0x2` `ADV_NONCONN_IND`), Length = payload length
- **Payload**: Host-supplied advertising data (e.g. AdvA + AdvData)
- **CRC**: Valid 24-bit Link Layer CRC
- **Physical Rate**: 1 Mbit/s (LE 1M PHY)

---

## [VERIFY] Checklist for Human Sign-Off

- [x] **[VERIFY]** Preamble sequence = `0xAA` for LE 1M PHY.
- [x] **[VERIFY]** Access Address = `0x8E89BED6` LSB-first.
- [x] **[VERIFY]** CRC-24 polynomial `x^24 + x^10 + x^9 + x^6 + x^4 + x^3 + x + 1` with seed `0x555555`.
- [x] **[VERIFY]** 7-bit whitening polynomial `x^7 + x^4 + 1` seeded from channel index bits.
- [x] **[VERIFY]** Whitening covers Header + Payload + CRC (Preamble and Access Address unwhitened).
- [x] **[VERIFY]** Clock rate ceiling `CLK_FREQ_HZ = 64 MHz` (≤ 66 MHz RP2040 limit).
- [x] **[VERIFY]** Subcarrier relationship `CLK_FREQ_HZ >= PHASE_COUNT * F_SWITCH_HZ`.
- [x] **[VERIFY]** Dedicated output pins registered with safe reset state.
