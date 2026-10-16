"""Draw chosen layers of a PrusaSlicer G-code as PNGs, one bead = one stroke.

usage: python tools/gcode_draw.py file.gcode out_prefix z1 z2 ...   (z in mm, or "top" / "first")
Docs/PrintLook.md: how the printed look was measured with it.
Colour = feature type; brightness ramps with print order inside the layer,
so the order (monotonic or not) and the start points show.
"""
import math
import re
import struct
import sys
import zlib

PX = 40.0  # pixels a mm

COLOURS = {
    'External perimeter': (230, 120, 40),
    'Perimeter': (240, 200, 60),
    'Overhang perimeter': (200, 80, 200),
    'Top solid infill': (220, 60, 60),
    'Solid infill': (150, 60, 200),
    'Internal infill': (60, 160, 220),
    'Bridge infill': (60, 200, 200),
    'Gap fill': (255, 255, 255),
    'Skirt/Brim': (90, 90, 90),
}


def parse(path):
    layers = {}
    z = 0.0
    x = y = 0.0
    e_rel = False
    kind = ''
    width = 0.45
    for line in open(path, encoding='utf-8', errors='ignore'):
        if line.startswith(';Z:'):
            z = round(float(line[3:]), 3)
            continue
        if line.startswith(';TYPE:'):
            kind = line[6:].strip()
            continue
        if line.startswith(';WIDTH:'):
            width = float(line[7:])
            continue
        if line.startswith('M83'):
            e_rel = True
        if not (line.startswith('G1 ') or line.startswith('G0 ')):
            continue
        code = line.split(';')[0]
        nx, ny, ne = x, y, None
        for tok in code.split()[1:]:
            if tok[0] == 'X':
                nx = float(tok[1:])
            elif tok[0] == 'Y':
                ny = float(tok[1:])
            elif tok[0] == 'E':
                ne = float(tok[1:])
            elif tok[0] == 'Z':
                pass
        if ne is not None and ne > 0 and (nx != x or ny != y):
            layers.setdefault(z, []).append((x, y, nx, ny, kind, width))
        x, y = nx, ny
    return layers


def png(path, w, h, px):
    raw = b''.join(b'\x00' + bytes(px[r * w * 3:(r + 1) * w * 3]) for r in range(h))
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


def draw(segs, out, bounds):
    x0, y0, x1, y1 = bounds
    w = int((x1 - x0) * PX) + 20
    h = int((y1 - y0) * PX) + 20
    px = bytearray([16, 16, 20] * (w * h))
    n = len(segs)
    for i, (ax, ay, bx, by, kind, width) in enumerate(segs):
        base = COLOURS.get(kind, (200, 200, 200))
        k = 0.45 + 0.55 * (i / max(n - 1, 1))
        col = tuple(int(c * k) for c in base)
        r = width * 0.5 * PX * 0.92
        L = math.hypot(bx - ax, by - ay) * PX
        steps = max(int(L / 1.0), 1)
        for s in range(steps + 1):
            t = s / steps
            cx = (ax + (bx - ax) * t - x0) * PX + 10
            cy = (y1 - (ay + (by - ay) * t)) * PX + 10
            ri = int(r) + 1
            for dy in range(-ri, ri + 1):
                yy = int(cy) + dy
                if yy < 0 or yy >= h:
                    continue
                for dx in range(-ri, ri + 1):
                    xx = int(cx) + dx
                    if xx < 0 or xx >= w:
                        continue
                    if (xx + 0.5 - cx) ** 2 + (yy + 0.5 - cy) ** 2 <= r * r:
                        o = (yy * w + xx) * 3
                        px[o:o + 3] = bytes(col)
    # the start of the layer's first external perimeter: the seam
    for (ax, ay, bx, by, kind, width) in segs:
        if kind == 'External perimeter':
            cx = (ax - x0) * PX + 10
            cy = (y1 - ay) * PX + 10
            for dy in range(-6, 7):
                for dx in range(-6, 7):
                    if dx * dx + dy * dy <= 36 and 0 <= int(cy) + dy < h and 0 <= int(cx) + dx < w:
                        o = ((int(cy) + dy) * w + int(cx) + dx) * 3
                        px[o:o + 3] = bytes((0, 255, 0))
            break
    png(out, w, h, px)
    return w, h


def main():
    path, prefix = sys.argv[1], sys.argv[2]
    layers = parse(path)
    zs = sorted(layers)
    allx = [p for z in zs for s in layers[z] for p in (s[0], s[2])]
    ally = [p for z in zs for s in layers[z] for p in (s[1], s[3])]
    # leave the skirt out of the frame
    body = [s for z in zs for s in layers[z] if s[4] != 'Skirt/Brim']
    bx = [p for s in body for p in (s[0], s[2])]
    by = [p for s in body for p in (s[1], s[3])]
    bounds = (min(bx) - 0.3, min(by) - 0.3, max(bx) + 0.3, max(by) + 0.3)
    print('layers', len(zs), 'z', zs[0], '..', zs[-1])
    for want in sys.argv[3:]:
        if want == 'first':
            z = zs[0]
        elif want == 'top':
            z = zs[-1]
        else:
            z = min(zs, key=lambda q: abs(q - float(want)))
        segs = [s for s in layers[z] if s[4] != 'Skirt/Brim']
        kinds = {}
        for s in segs:
            kinds[s[4]] = kinds.get(s[4], 0) + 1
        out = '%s_z%.2f.png' % (prefix, z)
        w, h = draw(segs, out, bounds)
        print(out, w, h, kinds)


main()
