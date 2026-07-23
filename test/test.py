"""
test.py — cocotb Verification Testbench for BLE Backscatter Radio
Copyright (c) 2026
SPDX-License-Identifier: Apache-2.0

Spec refs: §10 (V-1..V-6).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles
from golden_model import BLEGoldenModel

# Register Map Addresses
A_CTRL = 0x00
A_STATUS = 0x01
A_CHAN = 0x02
A_LEN = 0x03
A_PHASE = 0x04
A_HDR = 0x05
A_PAYLOAD = 0x08


async def spi_transfer_byte(dut, tx_byte: int) -> int:
    """Send and receive one byte over oversampled SPI mode 0."""
    rx_byte = 0
    for bit_idx in range(7, -1, -1):
        mosi_bit = (tx_byte >> bit_idx) & 1
        curr_val = int(dut.ui_in.value)
        dut.ui_in.value = (curr_val & ~0x03) | (mosi_bit << 1)
        await ClockCycles(dut.clk, 4)

        dut.ui_in.value = int(dut.ui_in.value) | 0x01
        await ClockCycles(dut.clk, 4)

        miso_bit = int(dut.uio_out.value) & 1
        rx_byte = (rx_byte << 1) | miso_bit
        dut.ui_in.value = int(dut.ui_in.value) & ~0x01
        await ClockCycles(dut.clk, 4)

    return rx_byte


async def spi_write(dut, addr: int, data: int):
    """SPI write transaction."""
    dut.ui_in.value = int(dut.ui_in.value) & ~0x04
    await ClockCycles(dut.clk, 4)
    cmd = 0x80 | (addr & 0x7F)
    await spi_transfer_byte(dut, cmd)
    await spi_transfer_byte(dut, data)
    dut.ui_in.value = int(dut.ui_in.value) | 0x04
    await ClockCycles(dut.clk, 8)


async def spi_read(dut, addr: int) -> int:
    """SPI read transaction."""
    dut.ui_in.value = int(dut.ui_in.value) & ~0x04
    await ClockCycles(dut.clk, 4)
    cmd = 0x00 | (addr & 0x7F)
    await spi_transfer_byte(dut, cmd)
    val = await spi_transfer_byte(dut, 0x00)
    dut.ui_in.value = int(dut.ui_in.value) | 0x04
    await ClockCycles(dut.clk, 8)
    return val


async def spi_stream_payload(dut, payload: list[int]):
    """Stream payload bytes into FIFO over SPI burst write to 0x08."""
    dut.ui_in.value = int(dut.ui_in.value) & ~0x04
    await ClockCycles(dut.clk, 4)
    cmd = 0x80 | (A_PAYLOAD & 0x7F)
    await spi_transfer_byte(dut, cmd)
    for byte_val in payload:
        await spi_transfer_byte(dut, byte_val)
    dut.ui_in.value = int(dut.ui_in.value) | 0x04
    await ClockCycles(dut.clk, 8)


async def setup_dut(dut):
    """Initialize clock, reset, and default pins."""
    clock = Clock(dut.clk, 16, unit="ns")
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0x04  # cs_n=1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)


def debug_bits(dut) -> dict:
    """Decode uio_out[7:1] = {data_bit, run_fsm, busy, fifo_empty, fifo_full,
    done_int, tx_active_int} (see ble_modem_top.v's `debug` assignment)."""
    uio = int(dut.uio_out.value)
    return {
        "data_bit": (uio >> 7) & 1,
        "run_fsm": (uio >> 6) & 1,
        "busy": (uio >> 5) & 1,
        "fifo_empty": (uio >> 4) & 1,
        "fifo_full": (uio >> 3) & 1,
        "done_int": (uio >> 2) & 1,
        "tx_active_int": (uio >> 1) & 1,
    }


async def capture_packet_bits(dut, n_bits: int, timeout_cycles: int = 500000) -> list[int]:
    """Capture n_bits from uio_out[7] (data_bit) on sym_clk rising edges.

    sym_clk == sym_tick (see ble_modem_top.v), and data_bit is combinational: it
    already reflects the bit for the current symbol for the entire cycle that
    sym_tick is high (the shift registers advance on the *next* edge), so sampling
    it the instant sym_clk rises is correct without any extra hold register.
    """
    captured = []
    prev_sym_clk = 0
    cycles = 0
    while len(captured) < n_bits and cycles < timeout_cycles:
        await ClockCycles(dut.clk, 1)
        cycles += 1
        uo = int(dut.uo_out.value)
        sym_clk = (uo >> 5) & 1
        if sym_clk == 1 and prev_sym_clk == 0:
            bit_val = (int(dut.uio_out.value) >> 7) & 1
            captured.append(bit_val)
        prev_sym_clk = sym_clk
    return captured


@cocotb.test()
async def test_reset_and_idle(dut):
    """V-1: Reset and idle safe state check."""
    await setup_dut(dut)
    uo = int(dut.uo_out.value)
    assert (uo & 0x0F) == 0, f"phase_ctrl should be 0, got {uo & 0x0F}"
    assert (uo & 0x10) == 0, "tx_active should be 0"
    dut._log.info("Reset safe state verified.")


@cocotb.test()
async def test_spi_config_readwrite(dut):
    """V-1: Verify SPI configuration register read/write operations."""
    await setup_dut(dut)
    await spi_write(dut, A_CHAN, 38)
    await spi_write(dut, A_LEN, 10)
    await spi_write(dut, A_HDR, 0x02)
    chan = await spi_read(dut, A_CHAN)
    length = await spi_read(dut, A_LEN)
    hdr = await spi_read(dut, A_HDR)
    assert chan == 38, f"Expected CHAN 38, got {chan}"
    assert length == 10, f"Expected LEN 10, got {length}"
    assert hdr == 0x02, f"Expected HDR 0x02, got {hdr}"
    dut._log.info("SPI config register R/W verified.")


@cocotb.test()
async def test_packet_transmission_ch37(dut):
    """V-2, V-3: Channel 37 full packet & golden model bit matching."""
    await setup_dut(dut)
    hdr0 = 0x02
    payload = [0x11, 0x22, 0x33, 0x44]
    chan = 37
    golden_bits = BLEGoldenModel.generate_packet_bits(chan, hdr0, payload)
    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)  # trigger tx_start via SPI
    captured = await capture_packet_bits(dut, len(golden_bits))
    assert len(captured) == len(golden_bits), f"Only captured {len(captured)} of {len(golden_bits)} bits"
    if captured != golden_bits:
        for i, (c, g) in enumerate(zip(captured, golden_bits)):
            if c != g:
                dut._log.info(f"  DIFF at bit {i}: captured={c} golden={g}")
    assert captured == golden_bits, f"Ch{chan} bitstream mismatch!"
    dut._log.info(f"Channel {chan} bitstream matched golden model!")


@cocotb.test()
async def test_packet_transmission_ch38(dut):
    """V-3: Channel 38 whitening test."""
    await setup_dut(dut)
    hdr0 = 0x00
    payload = [0xAA, 0xBB]
    chan = 38
    golden_bits = BLEGoldenModel.generate_packet_bits(chan, hdr0, payload)
    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)
    captured = await capture_packet_bits(dut, len(golden_bits))
    assert captured == golden_bits, f"Ch{chan} bitstream mismatch!"
    dut._log.info(f"Channel {chan} transmission verified!")


@cocotb.test()
async def test_ssb_4phase_modulation(dut):
    """V-6: SSB 4-phase switch control lines rotation."""
    await setup_dut(dut)
    dut.ui_in.value = int(dut.ui_in.value) | 0x10  # mode_sel=SSB
    payload = [0x55]
    await spi_write(dut, A_CHAN, 37)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, 0x02)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)
    await ClockCycles(dut.clk, 50)
    assert (int(dut.uo_out.value) & 0x10) != 0, "tx_active should be high"
    phase_history = []
    for _ in range(100):
        await ClockCycles(dut.clk, 1)
        pc = int(dut.uo_out.value) & 0x0F
        if not phase_history or phase_history[-1] != pc:
            phase_history.append(pc)
    assert len(phase_history) > 4
    dut._log.info("SSB 4-phase rotation verified.")


@cocotb.test()
async def test_dsb_fsk_modulation(dut):
    """V-6: DSB-FSK complementary outputs."""
    await setup_dut(dut)
    payload = [0xFF]
    await spi_write(dut, A_CHAN, 37)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, 0x02)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)
    await ClockCycles(dut.clk, 50)
    assert (int(dut.uo_out.value) & 0x10) != 0
    for _ in range(50):
        await ClockCycles(dut.clk, 1)
        uo = int(dut.uo_out.value)
        p0 = (uo >> 0) & 1
        p1 = (uo >> 1) & 1
        assert p0 ^ p1 == 1 or (p0 == 0 and p1 == 0), "DSB must be complementary"
    dut._log.info("DSB-FSK complementary output verified.")


@cocotb.test()
async def test_config_b_phase_select(dut):
    """FR-18..22: SPI PHASE_CFG (0x04) bit 0 selects Config A vs Config B DSB
    switching dividers at runtime via modulator.v's cfg_phase_sel mux. Config A
    keys between FSK_DIV0_A/FSK_DIV1_A = 2/3 clk cycles per toggle; Config B
    keys between FSK_DIV0_B/FSK_DIV1_B = 1/2 -- faster and numerically distinct
    from Config A, so measuring the actual toggle periods proves the mux (not
    just the register bit) took effect."""
    await setup_dut(dut)
    payload = [0xFF]
    await spi_write(dut, A_CHAN, 37)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, 0x02)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)  # mode_sel=0 (DSB), trigger tx_start
    await ClockCycles(dut.clk, 50)
    assert (int(dut.uo_out.value) & 0x10) != 0, "tx_active should be high"

    async def _measure_toggle_periods(n_cycles):
        periods = []
        prev_bit = int(dut.uo_out.value) & 1
        last_edge = 0
        for cycle in range(1, n_cycles + 1):
            await ClockCycles(dut.clk, 1)
            bit = int(dut.uo_out.value) & 1
            if bit != prev_bit:
                periods.append(cycle - last_edge)
                last_edge = cycle
                prev_bit = bit
        return periods

    periods_a = await _measure_toggle_periods(400)
    assert periods_a, "No DSB toggling observed for Config A"
    assert set(periods_a) <= {2, 3}, f"Config A periods out of range: {sorted(set(periods_a))}"

    await spi_write(dut, A_PHASE, 0x01)  # switch to Config B mid-transmission

    periods_b = await _measure_toggle_periods(400)
    assert periods_b, "No DSB toggling observed for Config B"
    assert set(periods_b) <= {1, 2}, f"Config B periods out of range: {sorted(set(periods_b))}"
    assert max(periods_b) < max(periods_a), "Config B should switch faster than Config A"
    dut._log.info(
        f"Config A periods {sorted(set(periods_a))}, Config B periods {sorted(set(periods_b))} verified."
    )


@cocotb.test()
async def test_payload_fifo_backpressure(dut):
    """§2/§11, FR-29: FIFO underrun stalls symbol timing (run=0) rather than
    emitting garbage, and transmission resumes correctly once more payload
    arrives. Payload (10 bytes) exceeds the 8-byte FIFO depth, and only the
    first 3 bytes are queued before tx_start, forcing a real stall."""
    await setup_dut(dut)
    hdr0 = 0x02
    chan = 37
    payload = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA]
    golden_bits = BLEGoldenModel.generate_packet_bits(chan, hdr0, payload)

    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_stream_payload(dut, payload[:3])   # deliberately under-fill the FIFO
    await spi_write(dut, A_CTRL, 0x01)           # trigger tx_start; completes before forking below

    stall_flag = {"seen": False}

    async def _feed_rest_on_stall():
        cycles = 0
        while cycles < 500000:
            await ClockCycles(dut.clk, 1)
            cycles += 1
            d = debug_bits(dut)
            if d["tx_active_int"] and d["fifo_empty"] and not d["run_fsm"]:
                stall_flag["seen"] = True
                await spi_stream_payload(dut, payload[3:])
                return
        raise TimeoutError("Never observed the expected FIFO-underrun stall")

    feeder = cocotb.start_soon(_feed_rest_on_stall())
    captured = await capture_packet_bits(dut, len(golden_bits))
    await feeder

    assert stall_flag["seen"], "Expected symbol timing to stall (run_fsm low) on FIFO underrun"
    assert captured == golden_bits, "Backpressure-stalled transmission produced the wrong bitstream"
    dut._log.info("Payload FIFO backpressure/stall-and-resume verified.")


@cocotb.test()
async def test_repeat_transmission(dut):
    """FR-23..25: repeat_en re-arms straight back into TX_PREAMBLE after DONE;
    the host must re-stream payload for each iteration (§2 streaming, no full-PDU
    buffer). Verifies two back-to-back iterations match the golden model
    bit-for-bit, then confirms clearing repeat_en stops the FSM cleanly."""
    await setup_dut(dut)
    hdr0 = 0x02
    chan = 37
    payload = [0xDE, 0xAD]
    golden_bits = BLEGoldenModel.generate_packet_bits(chan, hdr0, payload)

    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x05)  # tx_start=1, repeat_en=1; completes before forking below

    stall_flag = {"seen": False}

    async def _feed_second_iteration():
        cycles = 0
        while cycles < 500000:
            await ClockCycles(dut.clk, 1)
            cycles += 1
            d = debug_bits(dut)
            if d["tx_active_int"] and d["fifo_empty"] and not d["run_fsm"]:
                stall_flag["seen"] = True
                await spi_stream_payload(dut, payload)
                await spi_write(dut, A_CTRL, 0x00)  # clear repeat_en so it stops after this iteration
                return
        raise TimeoutError("Second repeat iteration never re-requested its payload")

    feeder = cocotb.start_soon(_feed_second_iteration())
    captured = await capture_packet_bits(dut, len(golden_bits) * 2)
    await feeder

    assert stall_flag["seen"], "Repeat iteration never stalled waiting for re-streamed payload"
    assert captured == golden_bits * 2, "Repeated transmission bitstream mismatch"

    # confirm it actually stops (no third iteration) after repeat_en was cleared
    await ClockCycles(dut.clk, 4000)
    uo = int(dut.uo_out.value)
    assert (uo & 0x10) == 0, "tx_active should drop after repeat_en cleared and final packet finished"
    dut._log.info("Repeat transmission (2 back-to-back iterations) verified; stopped cleanly.")


@cocotb.test()
async def test_max_payload_length(dut):
    """FR-29, §2: full MAX_PAYLOAD_BYTES=37 payload streams correctly even
    though it's far larger than the 8-byte FIFO, by pacing writes against
    fifo_full so no bytes are silently dropped (payload_fifo.v drops writes
    while full rather than blocking/overwriting).

    Bytes are paced one at a time, re-checking fifo_full immediately before
    each: a multi-byte burst only checked at the start of the chunk can still
    overflow mid-burst if the FIFO wasn't fully empty (its exact fill level
    isn't observable, only full/empty), silently dropping the tail bytes.
    """
    await setup_dut(dut)
    hdr0 = 0x02
    chan = 38
    payload = [(i * 7 + 3) & 0xFF for i in range(37)]
    golden_bits = BLEGoldenModel.generate_packet_bits(chan, hdr0, payload)

    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_write(dut, A_CTRL, 0x01)  # trigger tx_start with an empty FIFO; completes before forking below

    async def _paced_feeder():
        for byte_val in payload:
            while debug_bits(dut)["fifo_full"]:
                await ClockCycles(dut.clk, 1)
            await spi_stream_payload(dut, [byte_val])

    feeder = cocotb.start_soon(_paced_feeder())
    captured = await capture_packet_bits(dut, len(golden_bits))
    await feeder

    assert len(captured) == len(golden_bits), f"Only captured {len(captured)} of {len(golden_bits)} bits"
    assert captured == golden_bits, "Max-length (37-byte) payload bitstream mismatch"
    dut._log.info("Max payload length (37 bytes) verified against golden model.")


@cocotb.test()
async def test_reset_mid_transmission(dut):
    """V-1: an async reset asserted mid-packet drops straight back to the safe
    idle state (no latched garbage from partially-shifted registers), and a
    fresh transmission afterwards is unaffected (no residual CRC/whitening/FIFO
    state from the aborted packet)."""
    await setup_dut(dut)
    hdr0 = 0x02
    chan = 37
    payload = [0x11, 0x22, 0x33, 0x44]

    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)

    await ClockCycles(dut.clk, 4500)  # land mid-payload, well before CRC/DONE
    assert (int(dut.uo_out.value) & 0x10) != 0, "expected tx_active to still be high mid-packet"

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    uo = int(dut.uo_out.value)
    assert (uo & 0x0F) == 0, f"phase_ctrl should be 0 during reset, got {uo & 0x0F}"
    assert (uo & 0x10) == 0, "tx_active should be 0 during reset"
    assert (uo & 0x40) == 0, "done should be 0 during reset"

    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    uo = int(dut.uo_out.value)
    assert (uo & 0x1F) == 0, "should remain idle after reset release (no auto-restart)"

    # a fresh transmission must be unaffected by the aborted one
    golden_bits = BLEGoldenModel.generate_packet_bits(chan, hdr0, payload)
    await spi_write(dut, A_CHAN, chan)
    await spi_write(dut, A_LEN, len(payload))
    await spi_write(dut, A_HDR, hdr0)
    await spi_stream_payload(dut, payload)
    await spi_write(dut, A_CTRL, 0x01)
    captured = await capture_packet_bits(dut, len(golden_bits))
    assert captured == golden_bits, "Post-reset transmission bitstream mismatch"
    dut._log.info("Mid-transmission async reset verified: safe idle state + clean subsequent TX.")
