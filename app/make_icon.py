#!/usr/bin/env python3
"""Rounded square + swap arrows."""
import math
import os
import sys

SIZE = 1024
path = sys.argv[1] if len(sys.argv) > 1 else "icon.ppm"
bg = (16, 24, 40)
fg = (110, 190, 255)
pixels = bytearray(SIZE * SIZE * 3)

def setp(x, y, rgb):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        i = (y * SIZE + x) * 3
        pixels[i:i + 3] = bytes(rgb)

def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

radius = 220
for y in range(SIZE):
    for x in range(SIZE):
        dx = dy = 0
        if x < radius:
            dx = radius - x
        elif x >= SIZE - radius:
            dx = x - (SIZE - radius - 1)
        if y < radius:
            dy = radius - y
        elif y >= SIZE - radius:
            dy = y - (SIZE - radius - 1)
        if dx and dy:
            dist = math.hypot(dx, dy)
            if dist > radius + 1:
                setp(x, y, (0, 0, 0))
                continue
            if dist > radius - 1:
                t = max(0.0, min(1.0, radius + 1 - dist))
                setp(x, y, mix((0, 0, 0), bg, t))
                continue
        setp(x, y, bg)

def fill_rect(x0, y0, x1, y1, rgb):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            setp(x, y, rgb)

def fill_tri(x1, y1, x2, y2, x3, y3, rgb):
    minx, maxx = int(min(x1, x2, x3)), int(max(x1, x2, x3))
    miny, maxy = int(min(y1, y2, y3)), int(max(y1, y2, y3))
    def sign(ax, ay, bx, by, cx, cy):
        return (ax - cx) * (by - cy) - (bx - cx) * (ay - cy)
    for y in range(miny, maxy + 1):
        for x in range(minx, maxx + 1):
            b1 = sign(x, y, x1, y1, x2, y2) < 0
            b2 = sign(x, y, x2, y2, x3, y3) < 0
            b3 = sign(x, y, x3, y3, x1, y1) < 0
            if b1 == b2 == b3:
                setp(x, y, rgb)

# top arrow right
fill_rect(220, 360, 720, 430, fg)
fill_tri(700, 300, 860, 395, 700, 490, fg)
# bottom arrow left
fill_rect(300, 600, 800, 670, fg)
fill_tri(320, 530, 160, 635, 320, 740, fg)

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "wb") as f:
    f.write(f"P6\n{SIZE} {SIZE}\n255\n".encode("ascii"))
    f.write(pixels)
print(path)
