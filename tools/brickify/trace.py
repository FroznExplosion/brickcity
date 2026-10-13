"""Trace a side-view photo of a brick-built gun into a build sheet for gunsmith.py.

    blender --background --factory-startup --python tools/brickify/trace.py -- \
        <trace config .json> <build sheet to write .json> [debug picture .png]

The photo has to be a flat side view with studs in it: the studs are the ruler. The config
gives the photo, how many pixels a stud pitch is, where the muzzle is, and a box round each
part with the colour it is ("tan" for the smooth custom parts, "grey" for the rest).

What is read off the photo:
  loft     a tan part: its top and bottom edge at every few pixels along it (or its front and
           back edge up it), which become the sections of a lofted part
  bricks   a grey part: every cell of the nano grid that is more than half grey
  turned   a grey part round the bore: its radius along its length
  profile  a grey part's box: a magazine

What a side view cannot give, and the config has to: how thick each part is across the gun.

Uses Blender only to read the picture.
"""
import json
import math
import sys

import bpy
import numpy as np

PITCH, PLATE = 4.0, 1.6


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    cfg = json.load(open(args[0], encoding="utf-8"))
    img = bpy.data.images.load(cfg["photo"])
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)[::-1]  # row 0 at the top
    r, g, b = px[..., 0], px[..., 1], px[..., 2]
    tan = ((r - b) > 0.14) & (r > 0.45) & (g > 0.35)
    grey = (np.abs(r - g) < 0.07) & (np.abs(g - b) < 0.09) & (g > cfg.get("grey_from", 0.30)) & (g < 0.80)
    masks = {"tan": tan, "grey": grey}
    s = PITCH / cfg["px_per_stud"]  # mm a pixel
    xm = cfg["muzzle_px"]
    print("photo %d x %d, %.4f mm a pixel" % (w, h, s))

    # Up: put the top of the body on a plate line.
    body = next(p for p in cfg["parts"] if p["kind"] == "bricks")
    bx, by = body["box"]
    cols = grey[by[0]:by[1], bx[0]:bx[1]]
    top_px = by[0] + int(np.median([np.argmax(cols[:, c]) for c in range(cols.shape[1] // 3, 2 * cols.shape[1] // 3)]))
    z_top = cfg["body_top_plates"] * PLATE

    def X(col):
        return (xm - col) * s

    def Z(row):
        return z_top + (top_px - row) * s

    parts = []
    marks = {}
    for p in cfg["parts"]:
        (x0, x1), (y0, y1) = p["box"]
        m = masks[p["colour"]]
        if p.get("close"):
            m = _close(m, p["close"])
        m = m[y0:y1, x0:x1]
        if p.get("fill") == "columns":
            # A brick-built part is solid from its top edge to its bottom edge: what reads as
            # a hole in a photo is a dark brick or a shadow. Another colour's part stays out.
            m = m.copy()
            other = masks["tan"][y0:y1, x0:x1]
            for c in range(m.shape[1]):
                rows = np.flatnonzero(m[:, c])
                if len(rows):
                    m[rows[0]:rows[-1] + 1, c] = True
            m &= ~other
        out = {"name": p["name"], "kind": p["kind"], "slot": p["slot"], "colour": p["paint"]}
        for key in ("role", "module", "grip", "smooth", "arc"):
            if key in p:
                out[key] = p[key]
        if p["kind"] == "loft" and p["axis"] == "x":
            stations = []
            step = p.get("step", 4)
            tops, bots, ts = [], [], []
            for c in range(0, m.shape[1], step):
                run = _run(m[:, c:c + step].any(axis=1))
                if run is None:
                    continue
                ts.append(X(x0 + c + step * 0.5))
                tops.append(Z(y0 + run[0]))
                bots.append(Z(y0 + run[1]))
            tops, bots = _calm(tops, p.get("calm", 5)), _calm(bots, p.get("calm", 5))
            order = np.argsort(ts)
            lo_t, hi_t = min(ts), max(ts)
            for i in order:
                f = (ts[i] - lo_t) / max(hi_t - lo_t, 1e-9)
                stations.append({"t": round(float(ts[i]), 3), "a": [round(float(bots[i]), 3), round(float(tops[i]), 3)],
                                 "w": round(_at(p["width"], f), 3), "round": p["round"]})
            out.update({"axis": "x", "stations": stations})
            marks[p["name"]] = {"x": [lo_t, hi_t], "z": [float(min(bots)), float(max(tops))]}
        elif p["kind"] == "loft":
            stations = []
            step = p.get("step", 4)
            fronts, backs, ts = [], [], []
            for rr in range(0, m.shape[0], step):
                run = _run(m[rr:rr + step, :].any(axis=0))
                if run is None:
                    continue
                ts.append(Z(y0 + rr + step * 0.5))
                fronts.append(X(x0 + run[1]))
                backs.append(X(x0 + run[0]))
            fronts, backs = _calm(fronts, p.get("calm", 5)), _calm(backs, p.get("calm", 5))
            order = np.argsort(ts)
            lo_t, hi_t = min(ts), max(ts)
            for i in order:
                f = (ts[i] - lo_t) / max(hi_t - lo_t, 1e-9)
                stations.append({"t": round(float(ts[i]), 3), "a": [round(float(fronts[i]), 3), round(float(backs[i]), 3)],
                                 "w": round(_at(p["width"], f), 3), "round": p["round"]})
            out.update({"axis": "z", "stations": stations})
            marks[p["name"]] = {"x": [float(min(fronts)), float(max(backs))], "z": [lo_t, hi_t]}
        elif p["kind"] == "bricks":
            cells = []
            ix0, ix1 = math.floor(X(x1) / PITCH), math.ceil(X(x0) / PITCH)
            kz0, kz1 = math.floor(Z(y1) / PLATE), math.ceil(Z(y0) / PLATE)
            for ix in range(ix0, ix1):
                c0 = int(round(xm - (ix + 1) * PITCH / s)) - x0
                c1 = int(round(xm - ix * PITCH / s)) - x0
                for kz in range(kz0, kz1):
                    r0 = int(round(top_px - ((kz + 1) * PLATE - z_top) / s)) - y0
                    r1 = int(round(top_px - (kz * PLATE - z_top) / s)) - y0
                    cell = m[max(r0, 0):max(r1, 0), max(c0, 0):max(c1, 0)]
                    if cell.size and cell.mean() >= 0.5:
                        cells.append([ix, kz])
            out.update({"wide": p["wide"], "cells": cells})
            for key in ("studs_x", "studs_y"):
                if key in p:
                    out[key] = p[key]
            xs = [c[0] for c in cells]
            zs = [c[1] for c in cells]
            marks[p["name"]] = {"x": [min(xs) * PITCH, (max(xs) + 1) * PITCH],
                                "z": [min(zs) * PLATE, (max(zs) + 1) * PLATE]}
        elif p["kind"] == "turned":
            axis_px = p["axis_px"]
            # Round about the bore, one radius for each stretch the config names: the middle
            # radius of the columns where both of the barrel's edges show. A sight above it and
            # a handguard below it are not the barrel.
            sections = []
            for a, b in p["stretches"]:
                radii = []
                for c in range(a - x0, b - x0):
                    rows = np.flatnonzero(m[:, c])
                    if not len(rows):
                        continue
                    above = (axis_px - (y0 + rows[0])) * s
                    below = (y0 + rows[-1] + 1 - axis_px) * s
                    if below > 0.6 * above and above > 0.6 * below:
                        radii.append(min(above, below))
                if radii:
                    last = float(np.median(radii))
                sections.append([round(float(X(b)), 3), round(float(X(a)), 3), round(last, 3)])
            out.update({"axis_z": round(float(Z(axis_px)), 3), "sections": sections})
            marks[p["name"]] = {"x": [min(q[0] for q in sections), max(q[1] for q in sections)],
                                "z": [out["axis_z"], out["axis_z"]]}
        else:  # profile: the box the part fills
            rows = np.flatnonzero(m.any(axis=1))
            cs = np.flatnonzero(m.any(axis=0))
            xa, xb = X(x0 + cs[-1] + 1), X(x0 + cs[0])
            za, zb = Z(y0 + rows[-1] + 1), Z(y0 + rows[0])
            out.update({"thick": p["thick"], "bevel": p.get("bevel", 0.5),
                        "outline": [[round(float(v), 3) for v in q] for q in ((xa, zb), (xb, zb), (xb, za), (xa, za))]})
            marks[p["name"]] = {"x": [float(xa), float(xb)], "z": [float(za), float(zb)]}
        for key in ("studs", "under", "boxes"):
            if key in p:
                out[key] = p[key]
        parts.append(out)
        print("  %-12s %-8s x %.1f..%.1f  z %.1f..%.1f" % (p["name"], p["kind"], *marks[p["name"]]["x"], *marks[p["name"]]["z"]))

    _joints(cfg, parts, marks)
    sheet = {"name": cfg["name"], "note": "Written by trace.py from a photo: do not edit, edit the trace config.",
             "reference": cfg["reference"], "class": "held", "platform": cfg["platform"], "parts": parts}
    with open(args[1], "w", encoding="utf-8", newline="\n") as f:
        json.dump(sheet, f, indent=1)
    print("wrote", args[1])
    if len(args) > 2:
        show = np.zeros((h, w, 4), dtype=np.float32)
        show[..., 3] = 1.0
        show[..., :3] = px[..., :3] * 0.35
        show[tan, :3] = (1.0, 0.8, 0.3)
        show[grey, :3] = (0.5, 0.7, 1.0)
        dbg = bpy.data.images.new("dbg", w, h)
        dbg.pixels = show[::-1].ravel()
        dbg.filepath_raw = args[2]
        dbg.file_format = "PNG"
        dbg.save()


def _run(line, gap: int = 6):
    """The longest run of set places in a line, small gaps in it bridged: a part's own
    extent, not another thing lying further along the line. (from, to), or None."""
    places = np.flatnonzero(line)
    if len(places) < 3:
        return None
    best, start, prev = None, places[0], places[0]
    for q in list(places[1:]) + [None]:
        if q is None or q - prev > gap:
            if best is None or prev - start > best[1] - best[0]:
                best = (int(start), int(prev) + 1)
            start = q
        prev = q
    return best


def _close(mask, n: int):
    """Fill gaps up to about `n` pixels across: seams and shadows between bricks."""
    def grow(a, k):
        out = a.copy()
        for d in range(1, k + 1):
            out[d:, :] |= a[:-d, :]
            out[:-d, :] |= a[d:, :]
        a = out.copy()
        for d in range(1, k + 1):
            out[:, d:] |= a[:, :-d]
            out[:, :-d] |= a[:, d:]
        return out
    return ~grow(~grow(mask, n), n)


def _calm(values, window: int = 5):
    """Take the specks out of an edge read off a photo: a running median."""
    v = np.array(values, dtype=float)
    pad = window // 2
    padded = np.concatenate([np.full(pad, v[0]), v, np.full(pad, v[-1])])
    return np.array([np.median(padded[i:i + window]) for i in range(len(v))])


def _at(keys, f: float) -> float:
    """A value along a part from [[how far along 0..1, value], ...]."""
    for (f0, v0), (f1, v1) in zip(keys, keys[1:]):
        if f0 <= f <= f1:
            return v0 + (v1 - v0) * (f - f0) / max(f1 - f0, 1e-9)
    return keys[-1][1]


def _snap(v, step):
    return round(round(v / step) * step, 4)


def _joints(cfg, parts, marks) -> None:
    """Mounts and sockets where the traced parts meet, on the lattice."""
    by = {p["name"]: p for p in parts}
    body = next(p for p in parts if p["kind"] == "bricks")
    bm = marks[body["name"]]
    body["sockets"] = []
    for j in cfg["joints"]:
        m = marks[j["part"]]
        where = j["at"]
        x = {"body_front": bm["x"][0], "body_back": bm["x"][1], "mid": (m["x"][0] + m["x"][1]) * 0.5}[where[0]]
        z = {"axis": m["z"][0], "top": m["z"][1], "body_bottom": bm["z"][0],
             "body_mid": (bm["z"][0] + bm["z"][1]) * 0.5}[where[1]]
        at = [_snap(x, PITCH), _snap(z, PLATE)]
        by[j["part"]]["mount"] = {"at": at, "interface": j["interface"]}
        host = by[j.get("on", body["name"])]
        host.setdefault("sockets", []).append({"slot": by[j["part"]]["slot"], "at": at, "interface": j["interface"]})
    body["sockets"].append({"slot": "sight", "interface": "rail",
                            "at": [_snap((bm["x"][0] + bm["x"][1]) * 0.5, PITCH), _snap(bm["z"][1], PLATE)]})


main()
