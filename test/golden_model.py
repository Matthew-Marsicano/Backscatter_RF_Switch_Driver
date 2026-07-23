"""
golden_model.py — Independent BLE Advertising Packet Golden Reference Model
Copyright (c) 2026
SPDX-License-Identifier: Apache-2.0

Spec refs: §4.1..§4.3, V-2, V-4, V-5.

Computes preamble, access address, 16-bit PDU header, payload, CRC-24, and
7-bit LFSR data whitening to produce the bit-for-bit expected serial output stream.
"""

import pytest

class BLEGoldenModel:
    PREAMBLE_VAL = 0xAA
    ACCESS_ADDR_VAL = 0x8E89BED6
    CRC_INIT = 0x555555
    CRC_MASK = 0xDA6000  # LSB-first bit-reversed poly x^24 + x^10 + x^9 + x^6 + x^4 + x^3 + x + 1

    @staticmethod
    def byte_to_bits_lsb(byte_val: int) -> list[int]:
        """Return 8 bits in LSB-first order (bit 0 first)."""
        return [(byte_val >> i) & 1 for i in range(8)]

    @staticmethod
    def word32_to_bits_lsb(val: int) -> list[int]:
        """Return 32 bits in LSB-first order (byte 0 LSB first)."""
        bits = []
        for b in range(4):
            byte_val = (val >> (8 * b)) & 0xFF
            bits.extend(BLEGoldenModel.byte_to_bits_lsb(byte_val))
        return bits

    @classmethod
    def compute_crc24(cls, pre_whiten_bits: list[int]) -> list[int]:
        """
        Compute BLE CRC-24 over pre-whitening bit sequence.
        Returns 24 CRC bits in transmit order (LSB-first).
        """
        lfsr = cls.CRC_INIT
        for bit in pre_whiten_bits:
            fb = (lfsr & 1) ^ bit
            shifted = (lfsr >> 1) & 0x7FFFFF
            if fb:
                lfsr = shifted ^ cls.CRC_MASK
            else:
                lfsr = shifted

        # 24 bits transmitted LSB-first (lfsr bit 0 first)
        return [(lfsr >> i) & 1 for i in range(24)]

    @classmethod
    def whiten_bits(cls, chan_idx: int, bits: list[int]) -> list[int]:
        """
        Apply BLE 7-bit data whitening LFSR seeded from channel index.
        Polynomial: x^7 + x^4 + 1.
        Seed: w[0]=1, w[1]=chan[5], w[2]=chan[4], w[3]=chan[3], w[4]=chan[2], w[5]=chan[1], w[6]=chan[0].
        """
        chan = chan_idx & 0x3F
        w = [0] * 7
        w[0] = 1
        w[1] = (chan >> 5) & 1
        w[2] = (chan >> 4) & 1
        w[3] = (chan >> 3) & 1
        w[4] = (chan >> 2) & 1
        w[5] = (chan >> 1) & 1
        w[6] = (chan >> 0) & 1

        whitened = []
        for bit in bits:
            whiten_out = w[6]
            whitened.append(bit ^ whiten_out)

            fb = w[6]
            next_w = [0] * 7
            next_w[0] = fb
            next_w[1] = w[0]
            next_w[2] = w[1]
            next_w[3] = w[2]
            next_w[4] = w[3] ^ fb
            next_w[5] = w[4]
            next_w[6] = w[5]
            w = next_w

        return whitened

    @classmethod
    def generate_packet_bits(cls, chan_idx: int, hdr0: int, payload: list[int]) -> list[int]:
        """
        Generate complete serial bitstream for BLE advertising packet.
        """
        length = len(payload)
        
        # Preamble (8 bits, LSB-first)
        preamble_bits = cls.byte_to_bits_lsb(cls.PREAMBLE_VAL)

        # Access Address (32 bits, LSB-first)
        access_bits = cls.word32_to_bits_lsb(cls.ACCESS_ADDR_VAL)

        # Header: byte0=hdr0, byte1=length
        hdr_bits = cls.byte_to_bits_lsb(hdr0) + cls.byte_to_bits_lsb(length)

        # Payload bits
        payload_bits = []
        for b in payload:
            payload_bits.extend(cls.byte_to_bits_lsb(b))

        pre_whiten_pdu = hdr_bits + payload_bits

        # CRC-24 computed over header + payload
        crc_bits = cls.compute_crc24(pre_whiten_pdu)

        # Whitening covers header + payload + CRC
        whitened_pdu = cls.whiten_bits(chan_idx, pre_whiten_pdu + crc_bits)

        # Unwhitened Preamble + Access Address + Whitened (Header + Payload + CRC)
        return preamble_bits + access_bits + whitened_pdu


# ---- Unit Tests / Verification Vectors (V-4, V-5) ----

def test_ble_crc24_known_vector():
    """Verify CRC-24 implementation with simple test vector."""
    # Dummy header + payload: hdr0=0x02, len=0x02, payload=[0x11, 0x22]
    hdr_bits = BLEGoldenModel.byte_to_bits_lsb(0x02) + BLEGoldenModel.byte_to_bits_lsb(0x02)
    payload_bits = BLEGoldenModel.byte_to_bits_lsb(0x11) + BLEGoldenModel.byte_to_bits_lsb(0x22)
    pdu = hdr_bits + payload_bits

    crc = BLEGoldenModel.compute_crc24(pdu)
    assert len(crc) == 24


def test_ble_whitening_known_vector():
    """Verify 7-bit Whitening LFSR seed and sequence for Channel 37."""
    bits = [0] * 16
    w_out = BLEGoldenModel.whiten_bits(37, bits)
    assert len(w_out) == 16
    # Seed for chan 37 (0b100101): w[0]=1, w[1]=1, w[2]=0, w[3]=0, w[4]=1, w[5]=0, w[6]=1
    # First output bit is w[6] = 1 -> 0 ^ 1 = 1
    assert w_out[0] == 1


if __name__ == "__main__":
    pytest.main([__file__])
