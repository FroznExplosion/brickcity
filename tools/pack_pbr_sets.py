"""Pack ambientCG sets into the game's texture arrays (Docs/PbrWood.md):
textures/pbr/<material>_albedo_rough.webp -- colour RGB + roughness A, one
slice per set -- and <material>_normal.webp, one slice per set that has
relief. Slices side by side, no blank ones (WebP stops at 16383 px). Prints each
set's linear colour mean, roughness mean and spread, normal spread.

python tools/pack_pbr_sets.py <downloads> textures/pbr

<downloads> holds each set's ambientCG PNG zip unpacked (https://ambientcg.com/get?file=<Id>_2K-PNG.zip;
<Id>_Color.png, _Roughness.png, _NormalGL.png) in the folders named below. Docs/PbrWood.md 1.2."""
import os, sys
from PIL import Image, ImageStat

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

# (material, [(set folder, file prefix, has normal, desaturate, rotate, size)])
ARRAYS = [
    ("wood", 2048, [
        ("dl49_2k", "Wood049_2K-PNG", True, 0.0, False),
        ("sets2/Wood051_2K", "Wood051_2K-PNG", True, 0.0, False),
        ("sets2/Wood066_2K", "Wood066_2K-PNG", True, 0.0, False),
        ("sets2/Wood095_2K", "Wood095_2K-PNG", True, 0.0, False),   # 2048x1024: stacked twice
        ("sets2/Wood096_2K", "Wood096_2K-PNG", True, 0.0, True),    # grain runs down it: turned
        ("sets2/Wood062_2K", "Wood062_2K-PNG", True, 0.0, False),
    ]),
    ("metal", 2048, [
        ("sets/Metal009_2K", "Metal009_2K-PNG", True, 0.0, False),
        ("sets2/Metal055A_2K", "Metal055A_2K-PNG", False, 0.0, False),
        ("sets2/Metal053B_2K", "Metal053B_2K-PNG", False, 0.0, False),
        ("sets2/Metal047A_2K", "Metal047A_2K-PNG", False, 0.0, False),
        ("sets2/Metal058C_2K", "Metal058C_2K-PNG", False, 0.0, False),
    ]),
    ("stone", 2048, [
        ("sets/Marble012_2K", "Marble012_2K-PNG", False, 0.0, False),
        ("sets2/Marble016_2K", "Marble016_2K-PNG", False, 0.0, False),
        ("sets2/Granite002A_2K", "Granite002A_2K-PNG", False, 0.0, False),
        ("sets2/Rock058_2K", "Rock058_2K-PNG", True, 0.0, False),
        ("sets2/Travertine009_2K", "Travertine009_2K-PNG", False, 0.0, False),
        ("sets2/Travertine004_2K", "Travertine004_2K-PNG", False, 0.0, False),
        ("sets2/Concrete030_2K", "Concrete030_2K-PNG", True, 0.0, False),
        ("sets2/Clay005_2K", "Clay005_2K-PNG", True, 0.0, False),
    ]),
    # Autumn leaves: mostly their light and dark, a little of their hue, so a
    # leaf brick's own green carries the colour.
    ("leaf", 1024, [
        ("sets/ScatteredLeaves008_1K", "ScatteredLeaves008_1K-PNG", True, 0.75, False),
    ]),
]

lut = [(v / 255 / 12.92 if v / 255 <= 0.04045 else ((v / 255 + 0.055) / 1.055) ** 2.4) for v in range(256)]


def fit(im, size, turn):
    if turn:
        im = im.transpose(Image.Transpose.ROTATE_90)
    if im.size[1] * 2 == im.size[0]:
        full = Image.new(im.mode, (im.size[0], im.size[0]))
        full.paste(im, (0, 0))
        full.paste(im, (0, im.size[1]))
        im = full
    if im.size != (size, size):
        im = im.resize((size, size), Image.Resampling.LANCZOS)
    return im


def sheet(tiles, size):
    # No blank slices: the widest row of at most 7 that divides the count
    # (WebP stops at 16383 px; an empty slice is memory for nothing).
    n = len(tiles)
    cols = max(c for c in range(1, min(7, n) + 1) if n % c == 0)
    rows = n // cols
    s = Image.new(tiles[0].mode, (cols * size, rows * size))
    for i, t in enumerate(tiles):
        s.paste(t, ((i % cols) * size, (i // cols) * size))
    return s, cols, rows


for mat, size, sets in ARRAYS:
    ar_tiles, n_tiles = [], []
    for folder, pre, has_n, desat, turn in sets:
        base = f"{src}/{folder}/{pre}"
        c = fit(Image.open(base + "_Color.png").convert("RGB"), size, turn)
        r = fit(Image.open(base + "_Roughness.png").convert("L"), size, turn)
        n = fit(Image.open(base + "_NormalGL.png").convert("RGB"), size, turn)
        if turn:
            # Turned a quarter anticlockwise: old right is now up, old up
            # now left -- new red (right) = -old green, new green = old red.
            rr, gg, bb = n.split()
            n = Image.merge("RGB", (gg.point(lambda v: 255 - v), rr, bb))
        if desat > 0.0:
            c = Image.blend(c, c.convert("L").convert("RGB"), desat)
        ar_tiles.append(Image.merge("RGBA", (*c.split(), r)))
        h = c.histogram()
        mean = [sum(lut[i] * h[k * 256 + i] for i in range(256)) / sum(h[k * 256:(k + 1) * 256]) for k in range(3)]
        rs = ImageStat.Stat(r)
        ns = ImageStat.Stat(n)
        layer = -1
        if has_n:
            layer = len(n_tiles)
            n_tiles.append(n)
        print("%-14s %s mean vec3(%.4f, %.4f, %.4f) rough %.3f sd %.3f nsd %.3f %.3f normal layer %d" % (
            pre.split("_")[0], mat, *mean, rs.mean[0] / 255, rs.stddev[0] / 255,
            ns.stddev[0] / 127.5, ns.stddev[1] / 127.5, layer))
    for kind, tiles, q in (("albedo_rough", ar_tiles, 92), ("normal", n_tiles, 95)):
        if not tiles:
            continue
        s, cols, rows = sheet(tiles, size)
        p = f"{out}/{mat}_{kind}.webp"
        s.save(p, quality=q, method=4, alpha_quality=100, exact=True)
        print("  ", p, s.size, "slices", cols, "x", rows, "%.1f MB" % (os.path.getsize(p) / 1e6))
