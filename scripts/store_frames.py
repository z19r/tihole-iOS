#!/usr/bin/env python3
"""Turns UI test screenshots into App Store screenshots.

Each frame is the app's dark surface with a caption on top and the real
screenshot below it, at a size App Store Connect accepts for the device.

Usage: store_frames.py iphone|ipad|header <exported-attachments-dir> <out-dir>

`header` takes the iPhone attachments and writes header.png, the 5244x2950
"universal" creative asset App Store Connect uses for both the product page
header and search results.

The attachments dir is the output of `xcrun xcresulttool export attachments`:
PNGs plus a manifest.json naming them. Frames are written as
01-dashboard.png, 02-queries.png, ... so they upload in order.
"""

import json
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

# Output sizes App Store Connect accepts for the 6.7"/6.9" iPhone and the
# 12.9"/13" iPad slots.
SIZES = {"iphone": (1290, 2796), "ipad": (2048, 2732)}

# The universal asset is cropped to 21:9 for the header and to 3:2 for
# search results, so everything that matters stays inside both crops.
HEADER = (5244, 2950)
HEADER_SAFE = (round(2950 * 3 / 2), round(5244 * 9 / 21))
ICON = pathlib.Path(__file__).resolve().parent.parent / (
    "Tihole/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)

SURFACE = (0x0B, 0x04, 0x12)
TITLE = (0xFF, 0xFF, 0xFF)
SUBTITLE = (0xC9, 0xBE, 0xD8)
ACCENT = (0xFF, 0x2E, 0x93)
BORDER = (0x3A, 0x2A, 0x4A)

# Snapshot name in SmokeTests -> caption. Order is the App Store order.
SHOTS = [
    (
        "14-dashboard-final",
        "Your Pi-hole at a glance",
        "Queries, blocking, upstreams and top domains, live.",
    ),
    (
        "06-queries",
        "Watch every query",
        "Filter the live log, then allow or block with a swipe.",
    ),
    (
        "04-blocking",
        "Pause blocking anytime",
        "For 5, 10 or 15 minutes, or until you turn it back on.",
    ),
    (
        "08-domains",
        "Manage your lists",
        "Allow and deny domains, groups, clients and adlists.",
    ),
    (
        "13-config",
        "Every FTL setting",
        "Search and edit Pi-hole's full configuration.",
    ),
    (
        "11-system-info",
        "Health and maintenance",
        "System info, diagnosis messages, DNS log and tools.",
    ),
]

FONT_PATHS = [
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def font(size, bold):
    for path in FONT_PATHS:
        try:
            face = ImageFont.truetype(
                path, size, index=1 if bold and path.endswith(".ttc") else 0
            )
        except OSError:
            continue
        try:
            wanted = b"Bold" if bold else b"Regular"
            for name in face.get_variation_names():
                if name == wanted:
                    face.set_variation_by_name(name)
                    break
        except OSError:
            pass  # not a variable font
        return face
    return ImageFont.load_default(size)


def wrap(draw, text, face, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=face) <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    lines.append(line)
    return lines


def find_shots(attachments):
    manifest = json.loads((attachments / "manifest.json").read_text())
    found = {}
    for test in manifest:
        for item in test.get("attachments", []):
            name = item.get("suggestedHumanReadableName", "")
            for key, _, _ in SHOTS:
                if name.startswith(key + "_"):
                    found[key] = attachments / item["exportedFileName"]
    return found


def rounded_shot(shot, scale_to_h, max_w=None):
    """The screenshot scaled to a height, with the device's round corners."""
    raw = Image.open(shot).convert("RGB")
    scale = scale_to_h / raw.height
    if max_w:
        scale = min(scale, max_w / raw.width)
    sw, sh = round(raw.width * scale), round(raw.height * scale)
    raw = raw.resize((sw, sh), Image.LANCZOS)
    radius = round(sw * 0.07)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, sw - 1, sh - 1], radius=radius, fill=255
    )
    return raw, mask, radius


def paste_shot(canvas, shot, x, y, border, height, max_w=None):
    raw, mask, radius = rounded_shot(shot, height, max_w)
    ImageDraw.Draw(canvas).rounded_rectangle(
        [
            x - border,
            y - border,
            x + raw.width + border - 1,
            y + raw.height + border - 1,
        ],
        radius=radius + border,
        fill=BORDER,
    )
    canvas.paste(raw, (x, y), mask)
    return raw.width


def frame(shot, title, subtitle, size):
    w, h = size
    canvas = Image.new("RGB", size, SURFACE)
    draw = ImageDraw.Draw(canvas)
    margin = round(w * 0.08)
    title_face = font(round(w * 0.072), bold=True)
    sub_face = font(round(w * 0.036), bold=False)

    y = round(h * 0.06)
    draw.rounded_rectangle(
        [margin, y, margin + round(w * 0.09), y + round(w * 0.012)],
        radius=round(w * 0.006),
        fill=ACCENT,
    )
    y += round(w * 0.05)
    for line in wrap(draw, title, title_face, w - 2 * margin):
        draw.text((margin, y), line, font=title_face, fill=TITLE)
        y += round(title_face.size * 1.15)
    y += round(w * 0.015)
    for line in wrap(draw, subtitle, sub_face, w - 2 * margin):
        draw.text((margin, y), line, font=sub_face, fill=SUBTITLE)
        y += round(sub_face.size * 1.35)
    y += round(w * 0.05)

    # The screenshot fills the rest, keeping its aspect, centred.
    room_h = h - y - round(h * 0.04)
    raw, _, _ = rounded_shot(shot, room_h, w - 2 * margin)
    paste_shot(
        canvas,
        shot,
        (w - raw.width) // 2,
        y,
        max(2, round(w * 0.003)),
        room_h,
        w - 2 * margin,
    )
    return canvas


def header(shots):
    """Icon, name and tagline on the left; three phones on the right."""
    w, h = HEADER
    safe_w, safe_h = HEADER_SAFE
    left, top = (w - safe_w) // 2, (h - safe_h) // 2
    canvas = Image.new("RGB", HEADER, SURFACE)
    draw = ImageDraw.Draw(canvas)

    icon_size = round(safe_h * 0.2)
    icon = (
        Image.open(ICON)
        .convert("RGB")
        .resize((icon_size, icon_size), Image.LANCZOS)
    )
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, icon_size - 1, icon_size - 1],
        radius=round(icon_size * 0.225),
        fill=255,
    )
    x = left + round(safe_w * 0.03)
    y = top + round(safe_h * 0.2)
    canvas.paste(icon, (x, y), mask)
    y += icon_size + round(safe_h * 0.06)

    name_face = font(round(safe_h * 0.13), bold=True)
    tag_face = font(round(safe_h * 0.055), bold=True)
    sub_face = font(round(safe_h * 0.038), bold=False)
    text_w = round(safe_w * 0.46)
    draw.text((x, y), "tihole", font=name_face, fill=TITLE)
    y += round(name_face.size * 1.2)
    draw.rounded_rectangle(
        [x, y, x + round(safe_w * 0.04), y + round(safe_h * 0.012)],
        radius=round(safe_h * 0.006),
        fill=ACCENT,
    )
    y += round(safe_h * 0.04)
    for line in wrap(draw, "Your Pi-hole, in your pocket.", tag_face, text_w):
        draw.text((x, y), line, font=tag_face, fill=TITLE)
        y += round(tag_face.size * 1.2)
    y += round(safe_h * 0.015)
    sub = "Live queries, blocking, lists and every FTL setting."
    for line in wrap(draw, sub, sub_face, text_w):
        draw.text((x, y), line, font=sub_face, fill=SUBTITLE)
        y += round(sub_face.size * 1.35)

    # Two phones behind, the dashboard in front, all inside the safe area.
    border = round(w * 0.002)
    back_h = round(safe_h * 0.8)
    front_h = round(safe_h * 0.92)
    right = left + safe_w - round(safe_w * 0.02)
    back_y = top + (safe_h - back_h) // 2
    probe, _, _ = rounded_shot(shots["06-queries"], back_h)
    back_w = probe.width
    paste_shot(
        canvas, shots["06-queries"], right - back_w, back_y, border, back_h
    )
    probe, _, _ = rounded_shot(shots["14-dashboard-final"], front_h)
    front_x = right - back_w - round(probe.width * 0.62)
    paste_shot(
        canvas,
        shots["04-blocking"],
        front_x - round(back_w * 0.62),
        back_y,
        border,
        back_h,
    )
    paste_shot(
        canvas,
        shots["14-dashboard-final"],
        front_x,
        top + (safe_h - front_h) // 2,
        border,
        front_h,
    )
    return canvas


def main(device, attachments, out):
    out.mkdir(parents=True, exist_ok=True)
    shots = find_shots(attachments)
    missing = [key for key, _, _ in SHOTS if key not in shots]
    if missing:
        sys.exit(f"missing screenshots: {', '.join(missing)}")
    if device == "header":
        path = out / "header.png"
        header(shots).save(path, "PNG")
        print(path)
        return
    size = SIZES[device]
    for index, (key, title, subtitle) in enumerate(SHOTS, start=1):
        name = key.split("-")[1]
        path = out / f"{index:02d}-{name}.png"
        frame(shots[key], title, subtitle, size).save(path, "PNG")
        print(path)


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in (*SIZES, "header"):
        sys.exit(__doc__)
    main(sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
