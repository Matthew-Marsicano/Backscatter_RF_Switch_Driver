# Project Design Notes — BLE Backscatter Radio Modem

## Parameter Configuration & Clock Budget

- **Target Shuttle / Platform**: TinyTapeout OpenLane 2 (SKY130 PDK).
- **Allocated Tile Budget**: **1x2 tiles** (selected to provide routing slack, timing margin, and low post-synthesis utilization).
- **System Clock (`CLK_FREQ_HZ`)**: `64_000_000` Hz (64 MHz). Stays strictly below the **66 MHz hard maximum** forced by the RP2040 demo-board and `sky130_ef_io_gpiov2_pad` insertion delay (~10 ns).
- **Symbol Rate (`SYMBOL_RATE_HZ`)**: `1_000_000` Hz (1 Mbit/s BLE LE 1M PHY).
- **Subcarrier Frequency (`F_SWITCH_HZ`)**: `16_000_000` Hz (16 MHz).
- **Phase Count (`PHASE_COUNT`)**: `4` (4-phase Single Sideband Harmonic Rejection - Config A).

---

## Derived Clock Divider Math

1. **Symbol Divider (`SYMBOL_DIV`)**:
   $$\text{SYMBOL\_DIV} = \frac{\text{CLK\_FREQ\_HZ}}{\text{SYMBOL\_RATE\_HZ}} = \frac{64,000,000}{1,000,000} = 64$$
   Yields exact 1.000 Mbit/s symbol timing with 0% error.

2. **SSB Phase Divider (`PHASE_DIV`)**:
   $$\text{PHASE\_DIV} = \frac{\text{CLK\_FREQ\_HZ}}{\text{PHASE\_COUNT} \times \text{F\_SWITCH\_HZ}} = \frac{64,000,000}{4 \times 16,000,000} = 1$$
   Phasor rotates by 90° every 1 system clock cycle, creating four 90°-spaced phase outputs at 16 MHz.

3. **DSB FSK Dividers (`FSK_DIV0`, `FSK_DIV1`)**:
   $$\text{FSK\_DIV0} = \frac{64,000,000}{2 \times 16,000,000} = 2 \implies \text{reload} = 1$$
   $$\text{FSK\_DIV1} = \text{FSK\_DIV0} + 1 = 3 \implies \text{reload} = 2$$

---

## Storage & Streaming Strategy

To fit within the tight area budget and avoid requiring 2+ full tiles for register storage, the design uses a **pure streaming datapath**:
- **Full PDU buffer avoided**: A full 37-byte PDU register buffer (~300 flip-flops) is explicitly omitted.
- **On-the-fly serialization**: Shift registers exist only for the immediate field being transmitted.
- **Payload FIFO**: Small 8-byte synchronous byte FIFO (64 flops) buffers host SPI payload bytes.
- **Backpressure mechanism**: If the FIFO underruns, the symbol timing counter freezes (`run = 0`) until more payload bytes arrive, guaranteeing that the emitted bit sequence is completely deterministic and independent of host SPI timing.

---

## Verification & Synthesis Summary

- **cocotb Verification**: All 10 tests in `test/test.py` pass cleanly under Icarus Verilog (`test_reset_and_idle`, `test_spi_config_readwrite`, `test_packet_transmission_ch37`, `test_packet_transmission_ch38`, `test_ssb_4phase_modulation`, `test_dsb_fsk_modulation`, `test_payload_fifo_backpressure`, `test_repeat_transmission`, `test_max_payload_length`, `test_reset_mid_transmission`).
- **Golden Model Bitstream Matching**: Transmitted bitstreams for channels 37 and 38 match the Python `golden_model.py` reference implementation bit-for-bit (V-2), including under FIFO backpressure, `repeat_en` re-arming, and the full 37-byte `MAX_PAYLOAD_BYTES` case.
- **Linting**: Verilator `-Wall` clean (no latches, no multi-driven nets, no unhandled width truncation).

---

## Bit-Sampling Bug (resolved)

`test_packet_transmission_ch37` used to fail its bit-for-bit golden-model comparison, shifted
by one symbol. The root cause was in the **testbench's sampling point**, not the RTL bit
generation:

- `data_bit` in [packet_fsm.v](src/packet_fsm.v) is combinational (`raw_bit ^ whiten_out`).
  Because the state shift registers (`pre_sr`, `aa_sr`, `hdr_sr`, `pay_sr`, `crc_sr`) and the
  whitening LFSR only advance on the clock edge *after* `sym_tick` is sampled high inside
  their own `always @(posedge clk)` blocks, `data_bit` already holds the correct bit for the
  *current* symbol for the entire clock cycle that `sym_tick` is asserted — there is no need
  for (and no correct place to add) a registered "hold" latch.
- An earlier attempt added a `data_bit_held` register that captured `raw_bit` one cycle late,
  which made things worse (introduced a genuine one-symbol shift).
- **Fix**: sample `data_bit` directly on the cycle `sym_tick` is high, rather than on a
  separately-generated 50%-duty scope clock. [ble_modem_top.v](src/ble_modem_top.v) now does
  `assign sym_clk = sym_tick;` so the exposed `sym_clk` pin *is* `sym_tick`, and
  [test.py](test/test.py)'s `capture_packet_bits()` samples `uio_out[7]` (`data_bit`, via
  `debug[6]`) on `sym_clk`'s rising edge — which lands exactly inside the valid window.

---

## Additional Verification Coverage (2026-07-23)

Four tests added to close known coverage gaps, all in `test/test.py`:

- **`test_payload_fifo_backpressure`**: 10-byte payload (> 8-byte FIFO depth), only 3 bytes
  queued before `tx_start`. Confirms `run_fsm` actually drops (real stall, not a lucky race)
  while `fifo_empty` is asserted, then that the remaining bytes fed mid-stall produce a
  bit-exact golden-model match — i.e. backpressure genuinely pauses the bit clock rather than
  emitting garbage or silently corrupting the stream.
- **`test_repeat_transmission`**: enables `repeat_en` (CTRL bit 2), lets iteration 1 drain its
  payload, catches the stall as iteration 2 re-requests payload (proving the FSM really re-armed
  into `TX_PREAMBLE` on its own per [packet_fsm.v](src/packet_fsm.v) `S_DONE`), re-streams the
  same payload, then clears `repeat_en` and confirms it stops cleanly instead of looping forever.
- **`test_max_payload_length`**: full `MAX_PAYLOAD_BYTES = 37` payload against the 8-byte FIFO.
  First attempt at this test had a bug in the *test*, not the RTL: pacing writes by checking
  `fifo_full` only at the start of each 8-byte chunk still overflowed mid-burst whenever the
  FIFO wasn't fully drained, since [payload_fifo.v](src/payload_fifo.v) silently **drops** writes
  while full (`do_wr = wr_en && !full`) rather than blocking or overwriting — so the dropped
  tail bytes desynced the Python-side `remaining` list from the FIFO's actual contents and the
  capture hung until timeout. Fixed by pacing one byte at a time, re-checking `fifo_full`
  immediately before each.
- **`test_reset_mid_transmission`**: asserts `rst_n` ~4500 cycles into an active packet (mid
  payload), confirms all outputs drop to the safe-idle state within a few cycles, confirms no
  auto-restart on reset release, then confirms a following transmission is bit-exact — i.e. no
  residual CRC/whitening/FIFO state survives an abort.

Debug bus decoding (`uio_out[7:1]` = `{data_bit, run_fsm, busy, fifo_empty, fifo_full, done_int,
tx_active_int}`, see [ble_modem_top.v](src/ble_modem_top.v)'s `debug` assignment) is centralized
in test.py's `debug_bits()` helper rather than repeated bit-shift literals.

**Still not covered** (lower priority / needs a differently-parameterized DUT instantiation):
Config B (2-phase DSB @ ~24 MHz `F_SWITCH_HZ`) and non-default `PHASE_COUNT` — the compiled
testbench top hardcodes `PHASE_COUNT=4`/`F_SWITCH_HZ=16 MHz` via
[tt_um_ble_backscatter_modem.v](src/tt_um_ble_backscatter_modem.v), so exercising Config B would
need a second parameterized top-level instance in the testbench, not just a new test case.

---

## Dev Environment: WSL + OneDrive Is Slow

This repo lives under OneDrive (`.../OneDrive - Northeastern University/Documents/...`).
Running `iverilog`/cocotb from WSL directly against `/mnt/c/...` into that path is very slow —
each VPI/file round trip crosses the 9P bridge *plus* OneDrive's on-demand sync/placeholder
hooks. In practice this was slow enough that a `make` run got SIGKILL'd partway through the
third test (see the original failing `test_out.log` before this fix — real infra issue, not a
logic bug).

**Fix**: `rsync` the repo into the WSL distro's native ext4 filesystem (`~/work/...`) and run
`make` there. The whole repo is a few hundred KB, so the sync takes well under a second, and
sims then run at native speed (full 6-test suite: ~4s wall time vs. minutes-to-hang before).

Use [scripts/run_sim.ps1](scripts/run_sim.ps1) from PowerShell:

```powershell
scripts/run_sim.ps1            # RTL sim, all tests
scripts/run_sim.ps1 -Gates     # gate-level sim
```

It rsyncs `src/`, `test/`, and `docs/` (excluding `.git`, `sim_build`, waveform dumps) into
`~/work/BackscatterRadioBaseband` inside WSL, then runs `make` there. Edit source files here
on the Windows/OneDrive side as usual — the script re-syncs on every invocation, so there's
nothing to keep manually in sync.
