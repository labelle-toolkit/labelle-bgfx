#!/usr/bin/env python3
"""Render the real art and reject static fallback / layer-order regressions.

Uses only Python's standard library. Run from the repository root.
"""
from pathlib import Path
import struct
import subprocess


def capture(time, *, fallback=False, level=0.8, scale=8):
    subprocess.run([
        "zig", "build", "condenser-capture", "-Dgamepad_enabled=false",
        f"-Dcondenser-time={time}", f"-Dcondenser-level={level}",
        f"-Dcondenser-scale={scale}", f"-Dcondenser-fallback={str(fallback).lower()}",
    ], check=True)
    data = Path("zig-out/condenser.tga").read_bytes()
    assert data[1] == 0 and data[2] == 2 and data[16] == 32, "expected raw BGRA TGA"
    width, height = struct.unpack_from("<HH", data, 12)
    offset = 18 + data[0]
    pixels = data[offset:offset + width * height * 4]
    assert len(pixels) == width * height * 4
    if not data[17] & 32:
        rows = [pixels[y * width * 4:(y + 1) * width * 4] for y in range(height)]
        pixels = b"".join(reversed(rows))
    assert (width, height) == (103 * scale, 55 * scale)
    return pixels


def pixel(image, x, y, scale=8):
    index = (y * 103 * scale + x) * 4
    return image[index:index + 3]


def changed(a, b, rect, scale=8):
    x0, y0, x1, y1 = rect
    return sum(pixel(a, x, y, scale) != pixel(b, x, y, scale)
               for y in range(y0 * scale, y1 * scale)
               for x in range(x0 * scale, x1 * scale))


water_a = capture(1.4)
water_b = capture(1.8)
assert water_a == capture(1.4), "fixed simulation time must reproduce identical pixels"
static_a = capture(1.4, fallback=True)
static_b = capture(1.8, fallback=True)
region = (31, 50, 97, 54)  # Water body, clear of the cooler and falling drop heads.
motion = changed(water_a, water_b, region)
assert motion > 0, "the reservoir must animate"
assert changed(static_a, static_b, region) == 0, "negative control must have static water"
assert changed(water_a, static_a, region) > 0, "water must differ from the painted fallback"
assert changed(water_a, static_a, (17, 32, 31, 55)) == 0, "cooler must occlude water and splashes"
for y in range(55 * 8):
    for x in range(103 * 8):
        # The only extra draws are masked water and one-cell impact glints
        # immediately above its surface. Mist and drops are identical controls.
        if 4 * 8 <= x < 97 * 8 and 47 * 8 <= y < 54 * 8:
            continue
        assert pixel(water_a, x, y) == pixel(static_a, x, y), "effect escaped the reservoir"

native = capture(1.4, scale=1)
for y in range(55 * 8):
    for x in range(103 * 8):
        assert pixel(water_a, x, y) == pixel(native, x // 8, y // 8, 1), "integer scaling blurred or shifted the grid"
low = capture(1.4, level=0.3)
assert changed(water_a, low, (31, 48, 97, 54)) > 0, "fill level must change visible water"
print(f"CONDENSER_VERIFY: PASS, animated water pixels={motion}; deterministic, fallback, occlusion, mask and 1x/8x scaling checked")
