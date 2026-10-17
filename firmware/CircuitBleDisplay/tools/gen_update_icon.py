#!/usr/bin/env python3
"""Draws the firmware-update cog into main/circuit_update_icon.h. No packages needed.

The shape is the Lucide "cog" icon (ISC licence, tools/lucide/cog.svg) on a 24 x 24 grid, stroke 2: spokes
round two circles, with one long spoke pointing right, so it is not symmetric and a full turn needs every
frame. The e-paper redraws about once a second, so twelve frames 30 degrees apart make the cog visibly turn at
every redraw and come back to the start after twelve. Black/white 1-bit images in the format the other icons use.
"""
import math
import re
from pathlib import Path

SIZE = 72      # pixels (3 per grid unit)
STROKE = 2.0   # grid units, as Lucide draws it
SS = 4         # samples per pixel side
FRAMES = 12
STEP = 360 / FRAMES  # degrees between frames

HERE = Path(__file__).resolve().parent
SVG = (HERE / "lucide" / "cog.svg").read_text()


def parse():
    """Lines (as endpoint pairs) and circles (cx, cy, r) from the SVG; only the commands this icon uses."""
    segments, circles = [], []
    for d in re.findall(r'<path d="([^"]+)"', SVG):
        tokens = re.findall(r"[a-zA-Z]|-?\d+\.?\d*", d)
        i, cmd, x, y = 0, "", 0.0, 0.0
        while i < len(tokens):
            if tokens[i].isalpha():
                cmd = tokens[i]
                i += 1
                continue
            if cmd in "ML":
                nx, ny = float(tokens[i]), float(tokens[i + 1]); i += 2
                if cmd == "L": segments.append(((x, y), (nx, ny)))
                x, y = nx, ny
                cmd = "L" if cmd == "M" else cmd
            elif cmd in "ml":
                nx, ny = x + float(tokens[i]), y + float(tokens[i + 1]); i += 2
                if cmd == "l": segments.append(((x, y), (nx, ny)))
                x, y = nx, ny
                cmd = "l" if cmd == "m" else cmd
            elif cmd == "v":
                ny = y + float(tokens[i]); i += 1
                segments.append(((x, y), (x, ny))); y = ny
            elif cmd == "h":
                nx = x + float(tokens[i]); i += 1
                segments.append(((x, y), (nx, y))); x = nx
            elif cmd == "V":
                ny = float(tokens[i]); i += 1
                segments.append(((x, y), (x, ny))); y = ny
            elif cmd == "H":
                nx = float(tokens[i]); i += 1
                segments.append(((x, y), (nx, y))); x = nx
            else:
                raise SystemExit(f"unsupported path command {cmd!r}")
    for cx, cy, r in re.findall(r'<circle cx="([\d.]+)" cy="([\d.]+)" r="([\d.]+)"', SVG):
        circles.append((float(cx), float(cy), float(r)))
    return segments, circles


def dist_to_segment(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = 0 if dx == dy == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def render(angle_deg, segments, circles):
    unit = 24 / SIZE
    cos, sin = math.cos(math.radians(-angle_deg)), math.sin(math.radians(-angle_deg))
    rows = []
    for y in range(SIZE):
        row = ""
        for x in range(SIZE):
            ink = 0
            for sy in range(SS):
                for sx in range(SS):
                    gx = (x + (sx + .5) / SS) * unit - 12
                    gy = (y + (sy + .5) / SS) * unit - 12
                    px, py = gx * cos - gy * sin + 12, gx * sin + gy * cos + 12  # undo the rotation
                    if any(abs(math.hypot(px - cx, py - cy) - r) <= STROKE / 2 for cx, cy, r in circles) or \
                       any(dist_to_segment(px, py, a, b) <= STROKE / 2 for a, b in segments):
                        ink += 1
            row += "#" if ink * 2 >= SS * SS else "."
        rows.append(row)
    return rows


def c_image(name, rows):
    stride = (SIZE + 7) // 8
    data = [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]  # palette: black, white (opaque)
    for row in rows:
        bits = [0 if c == "#" else 1 for c in row] + [1] * (stride * 8 - SIZE)
        for i in range(stride):
            data.append(sum(b << (7 - j) for j, b in enumerate(bits[i * 8:i * 8 + 8])))
    body = ",\n    ".join(", ".join("0x%02X" % v for v in data[i:i + 12]) for i in range(0, len(data), 12))
    return f"""static const uint8_t {name}_data[] = {{
    {body},
}};
static const lv_image_dsc_t {name} = {{
    .header = {{
        .magic = LV_IMAGE_HEADER_MAGIC,
        .cf = LV_COLOR_FORMAT_I1,
        .flags = 0,
        .w = {SIZE},
        .h = {SIZE},
        .stride = {stride},
        .reserved_2 = 0,
    }},
    .data_size = sizeof({name}_data),
    .data = {name}_data,
    .reserved = nullptr,
    .reserved_2 = nullptr,
}};
"""


if __name__ == "__main__":
    segments, circles = parse()
    assert len(segments) == 12 and len(circles) == 2, (len(segments), len(circles))
    images, frames = "", []
    for k in range(FRAMES):
        rows = render(k * STEP, segments, circles)
        if k == 0:
            print("\n".join(rows[::2]))
        images += c_image(f"circuit_update_{k}", rows) + "\n"
        frames.append(f"&circuit_update_{k}")
    header = ('#pragma once\n#include "lvgl.h"\n\n// Generated by tools/gen_update_icon.py (Lucide "cog"). Do not edit.\n'
              + images
              + "static const lv_image_dsc_t *const circuit_update_frames[] = {" + ", ".join(frames) + "};\n"
              + f"static constexpr int circuit_update_frame_count = {FRAMES};\n")
    (HERE.parent / "main" / "circuit_update_icon.h").write_text(header)
    print("wrote main/circuit_update_icon.h")
