#!/usr/bin/env python3
"""Renders the Loop app icon (1024x1024, no alpha) from the loop mark in design/loop.html."""
import math, os
from PIL import Image, ImageDraw

INK, PAPER, ACCENT = (0x12, 0x12, 0x12), (0xF4, 0xF4, 0xF1), (0x5A, 0x78, 0xFF)
OUT = os.path.join(os.path.dirname(__file__), "..", "Loop", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
S = 4096  # supersampled canvas

def loop_points():
    pts, t = [], -3.5
    while t <= 3.4001:
        pts.append((t - 2.6 * math.sin(t), -2.6 * math.cos(t)))
        t += 0.035
    return pts

def main():
    pts = loop_points()
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    pad = 0.19 * S
    sc = (S - 2 * pad) / max(w, h)
    ox, oy = (S - w * sc) / 2, (S - h * sc) / 2
    pts = [(ox + (x - min(xs)) * sc, oy + (y - min(ys)) * sc) for x, y in pts]
    sw = 0.082 * S
    end = pts[-1]
    gone, e = 0.0, len(pts) - 1
    while e > 1 and gone < sw * 1.7:
        gone += math.dist(pts[e], pts[e - 1]); e -= 1
    img = Image.new("RGB", (S, S), INK)
    d = ImageDraw.Draw(img)
    line = pts[: e + 1]
    d.line(line, fill=PAPER, width=int(sw), joint="curve")
    r = sw / 2
    for p in (line[0], line[-1]):  # round caps
        d.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=PAPER)
    for p in line:  # round joins everywhere
        d.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=PAPER)
    dr = sw * 0.8
    d.ellipse((end[0] - dr, end[1] - dr, end[0] + dr, end[1] + dr), fill=ACCENT)
    out = img.resize((1024, 1024), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out.save(OUT, "PNG")
    print(os.path.abspath(OUT), out.size, out.mode)

if __name__ == "__main__":
    main()
