#!/usr/bin/env python3
"""Rebuild main/circuit_demo_screens.h to match prototypes/circuit-epaper-states.

The baked bitmaps carry only static art: header icons, rule, note-count icons,
the wordmark, state glyphs and the pairing layout. Date, clock, AM/PM, note
counts, record timer, sync percent and the pairing code are LVGL labels drawn by
main.cpp, so their text is blanked here.

Icons come from icon_bitmaps.py (see gen_icons.py). Fonts are macOS system fonts.
Idempotent: running it again on its own output changes nothing.
"""
import math
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from icon_bitmaps import ICONS  # noqa: E402

MAIN = HERE.parent / "main"
SCREENS = MAIN / "circuit_demo_screens.h"
W = H = 200
STRIDE = 25
BASES = ["idle", "record", "saved", "sync", "pair"]
MARKER_FELT = "/System/Library/Fonts/MarkerFelt.ttc"
ARIAL_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

# (x0, y0, x1, y1) exclusive, in 200x200 panel pixels.
HEADER_TEXT_BOX = (0, 0, 135, 28)
HEADER_ICON_BOX = (134, 0, 200, 28)
CLOCK_BOX = (6, 36, 130, 84)  # clock digits and AM/PM
COUNT_BOX = (100, 36, 200, 84)
BODY_TOP = 32  # everything under the header rule

# Header icons, left to right.
HEADER_ICONS = [("wifi", 138, 3), ("phone", 161, 5), ("hard-drive", 181, 5)]
# Icons that are separate LVGL images placed at run time (note counts beside
# their numbers, header icons by connection state). Emitted as circuit_icon_<name>
# with dashes turned into underscores.
COUNT_ICONS = ["clock", "check", "wifi", "wifi-off", "wifi-low", "wifi-high", "wifi-zero", "phone", "hard-drive"]

# Record animation: (dot radius, expanding ring radius or None) per frame.
RECORD_CENTER = (68, 137)
RECORD_FRAMES = [(14, None), (12, 36), (10, 40), (12, None)]
RECORD_BOX = (20, 92, 116, 182)

# The sync glyph is the prototype's refresh-cw icon stepped through rotations
# (it is 2-fold symmetric, so 0-150 covers a full turn).
SYNC_ANGLES = [0, 30, 60, 90, 120, 150]
SYNC_BOX = (33, 102, 113, 182)


def parse(path):
    text = path.read_text()
    return {m.group(1): bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", m.group(2)))
            for m in re.finditer(r"circuit_(\w+?)_data\[\] = \{(.*?)\};", text, re.S)}


def decode(raw):
    pal, px = raw[:8], raw[8:]
    black_bit = 0 if pal[:4] == bytes([0, 0, 0, 255]) else 1
    return [[((px[y * STRIDE + x // 8] >> (7 - x % 8)) & 1) == black_bit for x in range(W)] for y in range(H)]


def encode(grid):
    pal = bytes([0, 0, 0, 255, 255, 255, 255, 255])  # index0 black, index1 white
    px = bytearray(b"\xff" * (STRIDE * H))
    for y in range(H):
        for x in range(W):
            if grid[y][x]:
                px[y * STRIDE + x // 8] &= ~(1 << (7 - x % 8))
    return pal + bytes(px)


def clear(grid, box):
    x0, y0, x1, y1 = box
    for y in range(max(y0, 0), min(y1, H)):
        for x in range(max(x0, 0), min(x1, W)):
            grid[y][x] = False


def paste_rows(grid, rows, x0, y0):
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == "#" and 0 <= y0 + y < H and 0 <= x0 + x < W:
                grid[y0 + y][x0 + x] = True


def paste_mask(grid, mask, x0, y0):
    for y, row in enumerate(mask):
        for x, ink in enumerate(row):
            if ink and 0 <= y0 + y < H and 0 <= x0 + x < W:
                grid[y0 + y][x0 + x] = True


def disc(grid, cx, cy, r):
    for y in range(int(cy - r) - 1, int(cy + r) + 2):
        for x in range(int(cx - r) - 1, int(cx + r) + 2):
            if math.hypot(x + .5 - cx, y + .5 - cy) <= r:
                grid[y][x] = True


def ring(grid, cx, cy, r, stroke):
    for y in range(int(cy - r - stroke) - 1, int(cy + r + stroke) + 2):
        for x in range(int(cx - r - stroke) - 1, int(cx + r + stroke) + 2):
            if abs(math.hypot(x + .5 - cx, y + .5 - cy) - r) <= stroke / 2:
                grid[y][x] = True


def text_mask(text, size, spacing=0.0, font_path=ARIAL_BOLD):
    """Return a bool mask of `text` set in `font_path` with optional letter spacing."""
    font = ImageFont.truetype(font_path, size)
    widths = [font.getlength(c) + spacing for c in text]
    w, h = math.ceil(sum(widths)) + 2, size + 6
    im = Image.new("L", (w, h), 255)
    dr = ImageDraw.Draw(im)
    x = 0.0
    for c, cw in zip(text, widths):
        dr.text((x, 1), c, font=font, fill=0)
        x += cw
    ys = [y for y in range(h) if any(im.getpixel((x, y)) < 128 for x in range(w))]
    xs = [x for x in range(w) if any(im.getpixel((x, y)) < 128 for y in range(h))]
    return [[im.getpixel((x, y)) < 128 for x in range(min(xs), max(xs) + 1)] for y in range(min(ys), max(ys) + 1)]


def mask_size(mask):
    return len(mask[0]), len(mask)


def wordmark_mask(size=40):
    """'circuit' in Marker Felt Wide, tilted -3 degrees with a hand-drawn underline, as in the prototype."""
    ss = 4
    font = ImageFont.truetype(MARKER_FELT, size * ss, index=1)
    text_w = math.ceil(font.getlength("circuit"))
    pad = 8 * ss
    canvas = Image.new("L", (text_w + pad * 2, size * ss * 2), 255)
    dr = ImageDraw.Draw(canvas)
    dr.text((pad, pad // 2), "circuit", font=font, fill=0)
    base = pad // 2 + int(size * ss * 1.02)
    dr.rectangle((pad - 2 * ss, base, pad + text_w + 2 * ss, base + 3 * ss), fill=0)
    canvas = canvas.rotate(3, resample=Image.BICUBIC, fillcolor=255, expand=True)  # +3 = counter-clockwise
    canvas = canvas.resize((canvas.width // ss, canvas.height // ss), Image.LANCZOS)
    mask = [[canvas.getpixel((x, y)) < 140 for x in range(canvas.width)] for y in range(canvas.height)]
    ys = [y for y, r in enumerate(mask) if any(r)]
    xs = [x for x in range(canvas.width) if any(r[x] for r in mask)]
    return [r[min(xs):max(xs) + 1] for r in mask[min(ys):max(ys) + 1]]


def sync_icon(angle):
    """Rasterise the refresh-cw icon (24-unit grid, 2.3 stroke) rotated about its centre."""
    def arc(p0, p1, r, steps=24):
        mx, my = (p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2
        dx, dy = p1[0] - p0[0], p1[1] - p0[1]
        d = math.hypot(dx, dy)
        h = math.sqrt(max(r * r - d * d / 4, 0))
        for sign in (1, -1):
            cx, cy = mx + sign * h * -dy / d, my + sign * h * dx / d
            a0 = math.atan2(p0[1] - cy, p0[0] - cx)
            sweep = (math.atan2(p1[1] - cy, p1[0] - cx) - a0) % (2 * math.pi)
            if sweep < math.pi:
                return [(cx + r * math.cos(a0 + sweep * i / steps), cy + r * math.sin(a0 + sweep * i / steps))
                        for i in range(steps + 1)]
        raise ValueError("no arc")

    half = arc((3, 12), (12, 3), 9) + arc((12, 3), (18.74, 5.74), 9.75) + [(21, 8)]
    head = [(21, 3), (21, 8), (16, 8)]
    strokes = [half, head] + [[(24 - x, 24 - y) for x, y in s] for s in (half, head)]
    ss, size, stroke = 8, 80, 2.3
    unit = size / 32 * ss  # viewBox is 32 units wide, origin at -4
    rad = math.radians(angle)

    def px(pt):
        x, y = pt[0] - 12, pt[1] - 12
        x, y = x * math.cos(rad) - y * math.sin(rad), x * math.sin(rad) + y * math.cos(rad)
        return ((x + 16) * unit, (y + 16) * unit)

    im = Image.new("L", (size * ss, size * ss), 255)
    dr = ImageDraw.Draw(im)
    w = round(stroke * unit)
    for pts in ([px(p) for p in s] for s in strokes):
        dr.line(pts, fill=0, width=w, joint="curve")
        for x, y in (pts[0], pts[-1]):
            dr.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=0)
    im = im.resize((size, size), Image.LANCZOS)
    return [[im.getpixel((x, y)) < 128 for x in range(size)] for y in range(size)]


def fmt(raw):
    return "\n".join("    " + ", ".join(f"0x{b:02X}" for b in raw[i:i + 24]) + "," for i in range(0, len(raw), 24))


def header(g, label=None):
    clear(g, HEADER_TEXT_BOX)
    clear(g, HEADER_ICON_BOX)
    # Header icons are LVGL images so they can follow connection state.
    if label:
        paste_mask(g, text_mask(label, 11, 1.2), 8, 9)


def build_pair(g):
    clear(g, (0, BODY_TOP, W, H))
    header(g, "PAIRING")
    title = text_mask("PAIR WITH PHONE", 11, 1.5)
    tw, th = mask_size(title)
    group = 18 + 8 + tw
    x0 = (W - group) // 2
    paste_rows(g, ICONS["bluetooth"], x0, 52)
    paste_mask(g, title, x0 + 26, 52 + (18 - th) // 2)
    # Rounded code box; the six-digit code is an LVGL label centred inside it.
    bx0, by0, bx1, by1, r, t = 22, 84, 178, 138, 10, 3
    def inside(x, y, x0, y0, x1, y1, rad):
        cx = min(max(x, x0 + rad), x1 - rad)
        cy = min(max(y, y0 + rad), y1 - rad)
        return x0 <= x <= x1 and y0 <= y <= y1 and math.hypot(x - cx, y - cy) <= rad

    for y in range(by0, by1):
        for x in range(bx0, bx1):
            px_, py_ = x + .5, y + .5
            if inside(px_, py_, bx0, by0, bx1, by1, r) and not inside(px_, py_, bx0 + t, by0 + t, bx1 - t, by1 - t, r - t):
                g[y][x] = True
    hint = text_mask("Enter this code in the app", 11, 0.4)
    hw, hh = mask_size(hint)
    paste_mask(g, hint, (W - hw) // 2, 154)


def main():
    src = parse(SCREENS)
    wm = wordmark_mask()
    jobs = [("idle", "idle", 0), ("saved", "saved", 0), ("pair", "pair", 0), ("splash", "splash", 0)]
    jobs += [("record" if i == 0 else f"record_{i}", "record", i) for i in range(len(RECORD_FRAMES))]
    jobs += [("sync" if i == 0 else f"sync_{i}", "sync", a) for i, a in enumerate(SYNC_ANGLES)]

    parts = ["#pragma once\n\n#include \"lvgl.h\"\n\n"
             "// 200x200 indexed monochrome Circuit screens (generated by tools/relayout_screens.py).\n"
             "// Static art only: dynamic text is drawn by LVGL labels in main.cpp.\n"]
    for name, base, arg in jobs:
        g = decode(src[base]) if base != "splash" else [[False] * W for _ in range(H)]
        if base == "splash":
            # Boot screen: only the wordmark, centred, as large as fits the panel.
            big = max((sz for sz in range(40, 80, 2) if mask_size(wordmark_mask(sz))[0] <= W - 28), default=40)
            mark = wordmark_mask(big)
            mw, mh = mask_size(mark)
            paste_mask(g, mark, (W - mw) // 2, (H - mh) // 2)
        elif base == "pair":
            build_pair(g)
        else:
            header(g)
            clear(g, CLOCK_BOX)
            clear(g, COUNT_BOX)
        if base == "idle":
            clear(g, (0, 84, W, H))
            ww, wh = mask_size(wm)
            paste_mask(g, wm, (W - ww) // 2, 84 + (H - 84 - wh) // 2)
        elif base == "record":
            clear(g, RECORD_BOX)
            cx, cy = RECORD_CENTER
            ring(g, cx, cy, 33, 3)
            dot, outer = RECORD_FRAMES[arg]
            disc(g, cx, cy, dot)
            if outer:
                ring(g, cx, cy, outer, 3)
        elif base == "sync":
            clear(g, SYNC_BOX)
            paste_mask(g, sync_icon(arg), SYNC_BOX[0], SYNC_BOX[1])
        parts.append(f"static const uint8_t circuit_{name}_data[] = {{\n{fmt(encode(g))}\n}};\n"
                     f"static const lv_image_dsc_t circuit_{name}_screen = {{\n"
                     "    .header = {\n        .magic = LV_IMAGE_HEADER_MAGIC,\n        .cf = LV_COLOR_FORMAT_I1,\n"
                     f"        .flags = 0,\n        .w = {W},\n        .h = {H},\n        .stride = {STRIDE},\n        .reserved_2 = 0,\n    }},\n"
                     f"    .data_size = sizeof(circuit_{name}_data),\n    .data = circuit_{name}_data,\n"
                     "    .reserved = nullptr,\n    .reserved_2 = nullptr,\n};\n\n")
    for icon in COUNT_ICONS:
        rows = ICONS[icon]
        size, stride = len(rows), (len(rows) + 7) // 8
        px = bytearray(b"\xff" * (stride * size))
        for y, row in enumerate(rows):
            for x, c in enumerate(row):
                if c == "#":
                    px[y * stride + x // 8] &= ~(1 << (7 - x % 8))
        raw = bytes([0, 0, 0, 255, 255, 255, 255, 255]) + bytes(px)
        parts.append(f"static const uint8_t circuit_icon_{icon.replace('-', '_')}_data[] = {{\n{fmt(raw)}\n}};\n"
                     f"static const lv_image_dsc_t circuit_icon_{icon.replace('-', '_')} = {{\n"
                     "    .header = {\n        .magic = LV_IMAGE_HEADER_MAGIC,\n        .cf = LV_COLOR_FORMAT_I1,\n"
                     f"        .flags = 0,\n        .w = {size},\n        .h = {size},\n        .stride = {stride},\n        .reserved_2 = 0,\n    }},\n"
                     f"    .data_size = sizeof(circuit_icon_{icon.replace('-', '_')}_data),\n    .data = circuit_icon_{icon.replace('-', '_')}_data,\n"
                     "    .reserved = nullptr,\n    .reserved_2 = nullptr,\n};\n\n")
    SCREENS.write_text("".join(parts).rstrip() + "\n")


if __name__ == "__main__":
    main()
