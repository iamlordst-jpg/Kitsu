import zlib, struct, os, json
from math import hypot, sqrt

S = 1024
OUT = "GameBrowser/Assets.xcassets"
ICON = OUT + "/AppIcon.appiconset"
os.makedirs(ICON, exist_ok=True)

with open(OUT + "/Contents.json", "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f)
with open(ICON + "/Contents.json", "w") as f:
    json.dump({"images": [{"filename": "icon.png", "idiom": "universal",
                           "platform": "ios", "size": "1024x1024"}],
               "info": {"author": "xcode", "version": 1}}, f)

C1, C2, PURPLE = (79, 70, 229), (236, 72, 153), (79, 70, 229)

def cov(d):
    return max(0.0, min(1.0, 0.5 - d))

def rrect(x, y, cx, cy, hw, hh, r):
    qx = abs(x - cx) - hw + r
    qy = abs(y - cy) - hh + r
    return min(max(qx, qy), 0) + hypot(max(qx, 0), max(qy, 0)) - r

TRI = [(450, 300), (450, 500), (625, 400)]
EDGES = []
for i in range(3):
    ax, ay = TRI[i]; bx, by = TRI[(i + 1) % 3]
    nx, ny = (by - ay), -(bx - ax)
    n = sqrt(nx * nx + ny * ny)
    EDGES.append((ax, ay, nx / n, ny / n))
# make normals point outward
cx0 = sum(p[0] for p in TRI) / 3; cy0 = sum(p[1] for p in TRI) / 3
EDGES = [(ax, ay, nx, ny) if (cx0 - ax) * nx + (cy0 - ay) * ny < 0 else (ax, ay, -nx, -ny)
         for ax, ay, nx, ny in EDGES]

def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

rows = []
for y in range(S):
    row = bytearray([0])
    for x in range(S):
        col = mix(C1, C2, (x + y) / (2 * S))
        # white circle
        c = cov(hypot(x - 512, y - 400) - 215)
        if c: col = mix(col, (255, 255, 255), c)
        # play triangle
        d = max((x - ax) * nx + (y - ay) * ny for ax, ay, nx, ny in EDGES)
        c = cov(d)
        if c: col = mix(col, PURPLE, c)
        # text box
        c = cov(rrect(x, y, 512, 770, 360, 100, 50)) * 0.93
        if c: col = mix(col, (255, 255, 255), c)
        # text lines
        for (lx, ly, lw) in ((485, 735, 270), (415, 805, 200)):
            c = cov(rrect(x, y, lx, ly, lw, 13, 13)) * 0.55
            if c: col = mix(col, PURPLE, c)
        row += bytes(int(v) for v in col)
    rows.append(bytes(row))

raw = b"".join(rows)
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
with open(ICON + "/icon.png", "wb") as f:
    f.write(png)
print("icon written")
