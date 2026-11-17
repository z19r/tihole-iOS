#!/usr/bin/env python3
"""Renders the placeholder app icon: a hexagon in the Gloss theme's ramp on
the theme's deep-void surface, with a dark "hole" in the middle.

Usage: python3 scripts/make_icon.py Tihole/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import math
import sys

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 2  # supersample, then downscale for smooth edges
SURFACE = (0x0B, 0x04, 0x12)
RAMP = [
    (0xFF, 0x2E, 0x93),
    (0xE5, 0x33, 0xC9),
    (0x6B, 0x2F, 0xE0),
    (0x2E, 0xE6, 0xFF),
    (0xD6, 0xFF, 0x2E),
]


def ramp_color(t):
    t = min(max(t, 0.0), 1.0) * (len(RAMP) - 1)
    i = min(int(t), len(RAMP) - 2)
    f = t - i
    a, b = RAMP[i], RAMP[i + 1]
    return tuple(round(a[k] + (b[k] - a[k]) * f) for k in range(3))


def hexagon(cx, cy, r):
    return [
        (cx + r * math.cos(math.radians(60 * k - 90)), cy + r * math.sin(math.radians(60 * k - 90)))
        for k in range(6)
    ]


def main(path):
    n = SIZE * SCALE
    gradient = Image.new("RGB", (n, n))
    px = gradient.load()
    for y in range(n):
        for x in range(n):
            px[x, y] = ramp_color((x + y) / (2 * n))

    mask = Image.new("L", (n, n), 0)
    draw = ImageDraw.Draw(mask)
    c = n / 2
    draw.polygon(hexagon(c, c, n * 0.40), fill=255)
    draw.ellipse([c - n * 0.15, c - n * 0.15, c + n * 0.15, c + n * 0.15], fill=0)

    icon = Image.new("RGB", (n, n), SURFACE)
    icon.paste(gradient, (0, 0), mask)
    icon = icon.resize((SIZE, SIZE), Image.LANCZOS)
    icon.save(path, "PNG")


if __name__ == "__main__":
    main(sys.argv[1])
