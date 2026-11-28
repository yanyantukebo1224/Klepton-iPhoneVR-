#!/usr/bin/env python3
"""Generate a crisp, original PopinVR app icon using only the Python standard library."""
import math, os, struct, zlib

SIZE = 1024
pixels = bytearray(SIZE * SIZE * 4)

def rounded_rect(x, y, x0, y0, x1, y1, r):
    qx = max(x0 + r, min(x, x1 - r))
    qy = max(y0 + r, min(y, y1 - r))
    return (x - qx) ** 2 + (y - qy) ** 2 <= r * r

def segment_distance(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px-ax)*dx + (py-ay)*dy) / max(dx*dx + dy*dy, 1e-9)))
    return math.hypot(px - (ax + t*dx), py - (ay + t*dy))

def put(x, y, color):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        i = (y * SIZE + x) * 4
        pixels[i:i+4] = bytes((*color, 255))

def draw_line(ax, ay, bx, by, width, color):
    pad = int(width + 2)
    for y in range(max(0, int(min(ay, by))-pad), min(SIZE, int(max(ay, by))+pad+1)):
        for x in range(max(0, int(min(ax, bx))-pad), min(SIZE, int(max(ax, bx))+pad+1)):
            if segment_distance(x+0.5, y+0.5, ax, ay, bx, by) <= width/2:
                put(x, y, color)

def draw_circle(cx, cy, radius, color):
    for y in range(int(cy-radius-1), int(cy+radius+2)):
        for x in range(int(cx-radius-1), int(cx+radius+2)):
            if (x-cx)**2 + (y-cy)**2 <= radius*radius:
                put(x, y, color)

# Rounded square with a deep blue-to-violet gradient.
for y in range(SIZE):
    for x in range(SIZE):
        if rounded_rect(x, y, 0, 0, SIZE-1, SIZE-1, 218):
            t = (x + y) / (2 * SIZE)
            glow = max(0.0, 1.0 - math.hypot((x-300)/800, (y-160)/760))
            c = (int(7 + 16*t + 8*glow), int(16 + 22*t + 28*glow), int(43 + 60*t + 60*glow))
            put(x, y, c)

white = (238, 250, 255)
cyan = (63, 224, 255)
blue = (85, 133, 255)

# Headset visor: a bright, softly rounded outline.
for y in range(310, 715):
    for x in range(175, 850):
        outer = rounded_rect(x, y, 175, 310, 849, 714, 112)
        inner = rounded_rect(x, y, 220, 355, 804, 669, 78)
        if outer and not inner:
            put(x, y, white)

# Two luminous lenses.
for cx in (390, 635):
    draw_line(cx-65, 505, cx+65, 505, 18, cyan)
    draw_circle(cx, 505, 37, blue)
    draw_circle(cx, 505, 17, white)

# Top halo and lower bridge give the mark a recognizable XR silhouette.
draw_line(300, 290, 512, 215, 20, cyan)
draw_line(512, 215, 725, 290, 20, cyan)
draw_line(420, 710, 512, 770, 18, blue)
draw_line(512, 770, 604, 710, 18, blue)

# Small orbit accents.
draw_circle(155, 480, 13, cyan)
draw_circle(870, 480, 13, cyan)
draw_line(130, 480, 105, 480, 8, blue)
draw_line(895, 480, 920, 480, 8, blue)

def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

raw = b"".join(b"\x00" + pixels[y*SIZE*4:(y+1)*SIZE*4] for y in range(SIZE))
png = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">2I5B", SIZE, SIZE, 8, 6, 0, 0, 0)) + png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b"")
out = os.path.join(os.path.dirname(__file__), "..", "App", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(png)
print("Generated", out)
