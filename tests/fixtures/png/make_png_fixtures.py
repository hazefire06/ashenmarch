#!/usr/bin/env python3
"""Writes PNG fixtures for tests/sim/test_png_codec.gd.

This is a second, independent PNG encoder (standard library only) so a bug
that is symmetric in PngCodec's encoder and decoder can't pass the tests.
Rows cycle through filter types 0-4 so every unfilter path is exercised.
Pixel values come from sample_value(), which the GDScript test recomputes.

Run from the repo root: python3 tests/fixtures/png/make_png_fixtures.py
"""

import os
import struct
import zlib

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# (file name, width, height, channels, bit depth)
FIXTURES = [
    ("gray16_filters.png", 37, 23, 1, 16),
    ("rgb8_filters.png", 19, 11, 3, 8),
    ("rgba8_filters.png", 13, 7, 4, 8),
    ("rgb16_filters.png", 11, 9, 3, 16),
]

COLOR_TYPE = {1: 0, 2: 4, 3: 2, 4: 6}


def sample_value(x, y, c, depth):
    return (x * 1789 + y * 4093 + c * 7919 + (x * y * 31) % 977) % (1 << depth)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def filter_row(ftype, row, prior, bpp):
    out = bytearray()
    for i, x in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prior[i] if prior is not None else 0
        c = prior[i - bpp] if prior is not None and i >= bpp else 0
        pred = [0, a, b, (a + b) // 2, paeth(a, b, c)][ftype]
        out.append((x - pred) & 0xFF)
    return out


def chunk(ctype, data):
    body = ctype + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def encode(width, height, channels, depth):
    bpp = channels * depth // 8
    raw = bytearray()
    prior = None
    for y in range(height):
        row = bytearray()
        for x in range(width):
            for c in range(channels):
                v = sample_value(x, y, c, depth)
                row += struct.pack(">H", v) if depth == 16 else bytes([v])
        ftype = y % 5
        raw.append(ftype)
        raw += filter_row(ftype, row, prior, bpp)
        prior = row
    ihdr = struct.pack(">IIBBBBB", width, height, depth, COLOR_TYPE[channels], 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def main():
    for name, width, height, channels, depth in FIXTURES:
        path = os.path.join(OUT_DIR, name)
        with open(path, "wb") as f:
            f.write(encode(width, height, channels, depth))
        print("wrote", path)


if __name__ == "__main__":
    main()
