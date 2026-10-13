"""The part kit: cut a model into bare parts and put studs on them. Nothing else is changed.

    blender --background --factory-startup --python tools/brickify/partkit.py -- \
        <build sheet .json> <absolute out dir>

Docs/Parts/custom.md section 5. The build sheet says which model, how it splits into parts,
which parts take studs, and where each part's mount and sockets are. This file leaves the
model's shape alone and adds the standard features, to the sizes in Docs/Parts/standards.json,
and then checks the result it wrote against those standards.

Studs go on the model's own faces and stand square to them, whichever way a face points.
A run of facets that is nearly flat counts as one face; a grid of the stud pitch is laid on
it and slid to where the most studs fit; each stud is then dropped onto the facet under it
and stands along that facet's own normal.

Writes <name>.parts.json and <name>_iso.png / <name>_front.png / <name>_parts.png.

Not yet: one watertight solid per part, sockets underneath, the connectors' own shapes at a
mount, joints, STLs, a scene the game loads.
"""
import json
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
PARTS_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "Docs", "Parts"))
## How studs are placed, unless the sheet says otherwise ("studs" at its top level).
STUD_RULES = {
    "min": 2,          # a face takes studs only if this many fit
    "lip": 0.3,        # mm of face left round a stud
    "flat_deg": 8.0,   # facets within this of each other are one face
    "lean_deg": 12.0,  # a stud's own facet may lean this far from its face's average
    "slide": 4,        # grid positions tried each way across a stud pitch
    "skip_under": 0.5,  # leave faces whose normal points down more than this (sockets, later)
    "skip_ends": 0.7,   # leave faces that look along the gun more than this (where parts join)
    "clear": 0.6,      # mm that must be free over a stud's top
}


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    sheet = json.load(open(args[0], encoding="utf-8"))
    out_dir = args[1]
    std = json.load(open(os.path.join(PARTS_DIR, "standards.json"), encoding="utf-8"))
    grid = std["grids"][std["classes"][sheet["class"]]["grid"]]
    rules = dict(STUD_RULES, **sheet.get("studs", {}))

    shells, size = load_shells(sheet["source"], sheet["print_length"])
    cy = round(float(size[1]) * 0.5, 4)
    # x: stud lines along the gun. y: a stud cell centred on the centre plane. z: plate lines.
    lat = {"ox": sheet["lattice"]["x"], "cy": cy, "oz": sheet["lattice"]["z"],
           "pitch": grid["stud_pitch"], "plate": grid["plate"], "tick": grid["tick"]}
    print("%s: %d shells, %.1f x %.1f x %.1f mm at print size" % (sheet["name"], len(shells), *size))

    doc = {"name": sheet["name"], "source": sheet["source"], "class": sheet["class"],
           "platform": sheet.get("platform", ""), "print_mm": [round(float(s), 2) for s in size],
           "lattice": lat, "stud_d": grid["stud_d"], "stud_h": grid["stud_h"], "parts": []}
    built = {}
    taken = set()
    for spec in sheet["parts"]:
        got = take(shells, spec.get("take", "rest"), taken)
        if got is None:
            raise SystemExit("part %s: no shell of the model is in its box" % spec["name"])
        # The one change a sheet may make to a part's shape: wider, about the centre plane.
        got[0][..., 1] = cy + (got[0][..., 1] - cy) * spec.get("widen", 1.0)
        built[spec["name"]] = got
    whole = _bvh(np.concatenate([tris for tris, _ in built.values()]))

    for spec in sheet["parts"]:
        tris, shell_of = built[spec["name"]]
        part = {"name": spec["name"], "role": spec.get("role", "bare"), "slot": spec["slot"],
                "widen": spec.get("widen", 1.0), "triangles": int(len(tris)), "patches": [], "sockets": []}
        if "mount" in spec:
            part["mount"] = joint_point(spec["mount"], lat)
        for s in spec.get("sockets", []):
            part["sockets"].append(joint_point(s, lat))
        if spec.get("studs", True):
            part["patches"] = stud_faces(tris, shell_of, _bvh(tris), whole, lat, grid, rules)
        if spec.get("grip_core"):
            part["grip_core"] = grip_core(tris, _bvh(tris), std["held_grip"])
        lo, hi = tris.min(axis=(0, 1)), tris.max(axis=(0, 1))
        part["box_mm"] = [[round(float(c), 2) for c in lo], [round(float(c), 2) for c in hi]]
        doc["parts"].append(part)
        print("  %-10s %5d triangles, %2d faces with studs, %3d studs"
              % (spec["name"], len(tris), len(part["patches"]), sum(len(p["studs"]) for p in part["patches"])))

    doc["check"] = check(doc, std, grid)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, sheet["name"] + ".parts.json")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)
    print("wrote", path)
    render(os.path.join(out_dir, sheet["name"]), doc, built, size)


# ---------------------------------------------------------------------------------- the model

def load_shells(path: str, print_len: float):
    """The model's loose shells, at print size, its box's min corner at the origin:
    [{"tris": (n, 3, 3), "lo": xyz, "hi": xyz}], and the box's size."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    ext = os.path.splitext(path)[1].lower()
    if ext == ".fbx":
        bpy.ops.wm.fbx_import(filepath=path)
    elif ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    else:
        raise SystemExit("cannot read %s" % ext)
    raw = []
    for ob in bpy.context.scene.objects:
        if ob.type != "MESH":
            continue
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        bm.verts.ensure_lookup_table()
        seen = set()
        for v in bm.verts:
            if v.index in seen:
                continue
            stack, faces = [v], set()
            seen.add(v.index)
            while stack:
                c = stack.pop()
                faces.update(c.link_faces)
                for e in c.link_edges:
                    n = e.other_vert(c)
                    if n.index not in seen:
                        seen.add(n.index)
                        stack.append(n)
            if faces:
                raw.append(np.array([[ob.matrix_world @ fv.co for fv in f.verts] for f in faces],
                                    dtype=np.float64))
        bm.free()
    if not raw:
        raise SystemExit("no meshes in %s" % path)
    every = np.concatenate(raw)
    lo, hi = every.min(axis=(0, 1)), every.max(axis=(0, 1))
    k = print_len / float((hi - lo).max())
    shells = []
    for tris in raw:
        tris = (tris - lo) * k
        shells.append({"tris": tris, "lo": tris.min(axis=(0, 1)), "hi": tris.max(axis=(0, 1))})
    return shells, (hi - lo) * k


def take(shells, box, taken):
    """The triangles of every shell not yet taken that lies wholly inside `box`
    ({"x": [a, b], "z": [a, b]}, either left out for "any"), or of all that are left; and,
    for each triangle, which shell it is of."""
    out, ids = [], []
    for i, s in enumerate(shells):
        if i in taken:
            continue
        if box != "rest":
            inside = True
            for axis, key in ((0, "x"), (2, "z")):
                if key in box and (s["lo"][axis] < box[key][0] - 0.2 or s["hi"][axis] > box[key][1] + 0.2):
                    inside = False
            if not inside:
                continue
        taken.add(i)
        out.append(s["tris"].copy())
        ids.append(np.full(len(s["tris"]), i))
    return (np.concatenate(out), np.concatenate(ids)) if out else None


def _bvh(tris):
    return BVHTree.FromPolygons([Vector(v) for v in tris.reshape(-1, 3)],
                                [(3 * t, 3 * t + 1, 3 * t + 2) for t in range(len(tris))])


# ---------------------------------------------------------------------------------- features

def snap(value: float, origin: float, step: float) -> float:
    return origin + round((value - origin) / step) * step


def joint_point(spec, lat):
    """A mount or a socket, moved onto the lattice: a stud line along the gun, the centre
    plane across it, a plate line up it."""
    x, z = spec["at"]
    return {"slot": spec.get("slot", ""), "interface": spec["interface"],
            "asked": [x, z],
            "at": [round(snap(x, lat["ox"], lat["pitch"]), 4), round(lat["cy"], 4),
                   round(snap(z, lat["oz"], lat["plate"]), 4)]}


def stud_faces(tris, shell_of, own, whole, lat, grid, rules):
    """Studs on a part's own faces, each square to the facet it stands on.

    A face is a run of facets within `flat_deg` of each other. A grid of the stud pitch is
    laid on its average plane, along the gun where the face allows. It starts from the
    lattice and is slid by parts of a pitch to where the biggest whole rectangle of studs
    fits; the lattice's own position wins a tie, so faces that look straight up or sideways
    keep the lattice's studs when it costs nothing.

    A place takes a stud if the whole stud is on the face with a lip to spare, the facet
    under it leans no more than `lean_deg` from the face, and nothing of the gun is over it.
    The stud's foot is on that facet and its axis is that facet's normal.

    A stud never covers a detail. A model's details -- a selector, a catch, a bolt head --
    are shells of their own lying on the part, so the stud's whole rim has to stand on the
    same shell as its middle, with nothing over the rim either.
    """
    rim = [(math.cos(k * math.pi / 4), math.sin(k * math.pi / 4)) for k in range(8)]
    pitch, r, h = lat["pitch"], grid["stud_d"] * 0.5, grid["stud_h"]
    lean = math.cos(math.radians(rules["lean_deg"]))
    bm = bmesh.new()
    for t in tris:
        bm.faces.new([bm.verts.new(tuple(v)) for v in t])
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(rules["flat_deg"]),
                             verts=bm.verts[:], edges=bm.edges[:])
    anchor = Vector((lat["ox"], lat["cy"] - pitch * 0.5, lat["oz"]))
    along = Vector((1.0, 0.0, 0.0))
    patches = []
    for f in bm.faces:
        n = f.normal.copy()
        if n.length < 0.5 or n.z < -rules["skip_under"] or abs(n.x) > rules["skip_ends"]:
            continue
        if f.calc_area() < rules["min"] * (2 * r) ** 2:
            continue
        u = along - n * along.dot(n)
        u.normalize()
        v = n.cross(u)
        origin = anchor - n * (anchor - f.calc_center_median()).dot(n)
        poly = [((p.co - origin).dot(u), (p.co - origin).dot(v)) for p in f.verts]
        best = None
        for sa in range(rules["slide"]):
            for sb in range(rules["slide"]):
                da, db = sa * pitch / rules["slide"], sb * pitch / rules["slide"]
                i0 = math.floor((min(a for a, _ in poly) - da) / pitch)
                i1 = math.ceil((max(a for a, _ in poly) - da) / pitch)
                j0 = math.floor((min(b for _, b in poly) - db) / pitch)
                j1 = math.ceil((max(b for _, b in poly) - db) / pitch)
                if i1 <= i0 or j1 <= j0:
                    continue
                found = {}
                ok = np.zeros((i1 - i0, j1 - j0), dtype=bool)
                for i in range(i0, i1):
                    for j in range(j0, j1):
                        a, b = da + (i + 0.5) * pitch, db + (j + 0.5) * pitch
                        if not _inside(poly, a, b, r + rules["lip"]):
                            continue
                        # Down onto the facet under this place.
                        hit = own.ray_cast(origin + u * a + v * b + n * 3.0, -n)
                        if hit[0] is None or abs(hit[3] - 3.0) > 1.5:
                            continue
                        facet = hit[1] if hit[1].dot(n) > 0 else -hit[1]
                        if facet.dot(n) < lean:
                            continue
                        over = whole.ray_cast(hit[0] + facet * 0.02, facet)
                        if over[0] is not None and over[3] < h + rules["clear"]:
                            continue
                        clean = True
                        for ca, sa_ in rim:
                            q = origin + u * (a + ca * r) + v * (b + sa_ * r)
                            under = own.ray_cast(q + n * 3.0, -n)
                            if under[0] is None or shell_of[under[2]] != shell_of[hit[2]]:
                                clean = False
                                break
                            above = whole.ray_cast(under[0] + facet * 0.02, facet)
                            if above[0] is not None and above[3] < h + rules["clear"]:
                                clean = False
                                break
                        if not clean:
                            continue
                        ok[i - i0, j - j0] = True
                        found[(i - i0, j - j0)] = (hit[0].copy(), facet.copy())
                rect = _biggest_rectangle(ok)
                if rect is None:
                    continue
                area = (rect[1] - rect[0]) * (rect[3] - rect[2])
                if best is None or area > best[0]:
                    best = (area, rect, found, (da, db), (i0, j0))
        if best is None or best[0] < rules["min"]:
            continue
        _, (a0, a1, b0, b1), found, slide, (i0, j0) = best
        studs = [{"at": [round(c, 4) for c in found[(i, j)][0]],
                  "normal": [round(c, 6) for c in found[(i, j)][1]]}
                 for i in range(a0, a1) for j in range(b0, b1)]
        patches.append({"name": "f%d" % len(patches),
                        "normal": [round(c, 6) for c in n], "u": [round(c, 6) for c in u],
                        "v": [round(c, 6) for c in v], "origin": [round(c, 6) for c in origin],
                        "slide": [round(slide[0], 4), round(slide[1], 4)],
                        "first": [i0 + a0, j0 + b0], "cells": [a1 - a0, b1 - b0], "studs": studs})
    bm.free()
    return patches


def _inside(poly, a, b, margin) -> bool:
    """Is (a, b) inside the polygon, and at least `margin` from every edge of it?"""
    inside = False
    n = len(poly)
    for k in range(n):
        (x0, y0), (x1, y1) = poly[k], poly[(k + 1) % n]
        if (y0 > b) != (y1 > b) and a < x0 + (b - y0) * (x1 - x0) / (y1 - y0):
            inside = not inside
        dx, dy = x1 - x0, y1 - y0
        length2 = dx * dx + dy * dy
        t = 0.0 if length2 == 0.0 else max(0.0, min(1.0, ((a - x0) * dx + (b - y0) * dy) / length2))
        if math.hypot(a - (x0 + t * dx), b - (y0 + t * dy)) < margin:
            return False
    return inside


def _biggest_rectangle(ok):
    best, area = None, 0
    nu, nv = ok.shape
    for i0 in range(nu):
        for j0 in range(nv):
            if not ok[i0, j0]:
                continue
            j_end = nv
            for i1 in range(i0, nu):
                j = j0
                while j < j_end and ok[i1, j]:
                    j += 1
                j_end = j
                if j_end == j0:
                    break
                a = (i1 - i0 + 1) * (j_end - j0)
                if a > area:
                    best, area = (i0, i1 + 1, j0, j_end), a
    return best


def grip_core(tris, bvh, held):
    """The round core a hand closes on (Docs/Parts/custom.md section 4): along the grip's
    own long line, centred in it, and how much of the grip is left round it where the hand
    goes -- the middle three fifths of its length."""
    pts = tris.reshape(-1, 3)
    mid = (pts.min(axis=0) + pts.max(axis=0)) * 0.5
    xz = pts[:, [0, 2]] - mid[[0, 2]]
    _, vecs = np.linalg.eigh(np.cov(xz.T))
    along = vecs[:, -1]
    if along[1] < 0:
        along = -along
    t = xz @ along
    r = held["core_d"] * 0.5
    a, b = float(t.min()) + 1.0, float(t.max()) - 1.0
    axis = Vector((along[0], 0.0, along[1]))
    across = Vector((-along[1], 0.0, along[0]))
    up = Vector((0.0, 1.0, 0.0))
    centre = Vector((float(mid[0]), float(mid[1]), float(mid[2])))

    def reach(c, d):
        hit = bvh.ray_cast(c, d)
        return hit[3] if hit[0] is not None else 0.0

    stations = [float(s) for s in np.linspace(a + (b - a) * 0.2, b - (b - a) * 0.2, 5)]
    # Slide the line fore and aft to the middle of the grip, then measure what is left.
    centre += across * float(np.mean([(reach(centre + axis * s, across) - reach(centre + axis * s, -across)) * 0.5
                                      for s in stations]))
    side = min(min(reach(centre + axis * s, up), reach(centre + axis * s, -up)) for s in stations) - r
    fore_aft = min(min(reach(centre + axis * s, across), reach(centre + axis * s, -across))
                   for s in stations) - r
    return {"d": held["core_d"], "sides": held["core_sides"], "length": round(b - a, 3),
            "from": [round(float(c), 4) for c in centre + axis * a],
            "to": [round(float(c), 4) for c in centre + axis * b],
            "spare_side": round(float(side), 3), "spare_fore_aft": round(float(fore_aft), 3)}


# ---------------------------------------------------------------------------------- the check

def check(doc, std, grid):
    """Measure what was written against the standards. Reads `doc` only."""
    lat = doc["lattice"]
    lines = []

    def ok(what, good, detail=""):
        lines.append({"ok": bool(good), "what": what, "detail": detail})
        print("  %s  %s%s" % ("ok  " if good else "FAIL", what, ("  -- " + detail) if detail else ""))

    def whole(x):
        return abs(x - round(x)) < 1e-3

    ok("studs are the grid's: %.2f across, %.2f tall" % (grid["stud_d"], grid["stud_h"]),
       doc["stud_d"] == grid["stud_d"] and doc["stud_h"] == grid["stud_h"])
    count, crooked, off = 0, [], []
    for part in doc["parts"]:
        for p in part["patches"]:
            n, u, v, o = (Vector(p[k]) for k in ("normal", "u", "v", "origin"))
            for s in p["studs"]:
                count += 1
                sn = Vector(s["normal"])
                if abs(sn.length - 1) > 1e-4 or sn.dot(n) < math.cos(math.radians(12.5)):
                    crooked.append("%s/%s" % (part["name"], p["name"]))
                d = Vector(s["at"]) - o
                if not whole((d.dot(u) - p["slide"][0]) / lat["pitch"] - 0.5) \
                        or not whole((d.dot(v) - p["slide"][1]) / lat["pitch"] - 0.5):
                    off.append("%s/%s" % (part["name"], p["name"]))
    ok("every stud stands along the normal of the facet under it (%d studs)" % count, not crooked,
       ", ".join(sorted(set(crooked))))
    ok("every stud is on its face's grid, a stud pitch from the next", not off, ", ".join(sorted(set(off))))
    on_lattice = sum(1 for part in doc["parts"] for p in part["patches"] if p["slide"] == [0.0, 0.0])
    total = sum(len(part["patches"]) for part in doc["parts"])
    print("        %d of %d faces kept the lattice's own grid; the rest were slid to fit" % (on_lattice, total))

    points = []
    for part in doc["parts"]:
        for j in ([part["mount"]] if "mount" in part else []) + part["sockets"]:
            points.append(j)
    ok("every mount and socket is on a lattice point (%d)" % len(points),
       all(whole((j["at"][0] - lat["ox"]) / lat["pitch"]) and j["at"][1] == round(lat["cy"], 4)
           and whole((j["at"][2] - lat["oz"]) / lat["plate"]) for j in points))
    known = std.get("gun_interfaces", {})
    ok("every interface is one the standards name",
       all(j["interface"] in known for j in points),
       ", ".join(sorted({j["interface"] for j in points if j["interface"] not in known})))
    sockets = {}
    for part in doc["parts"]:
        for s in part["sockets"]:
            sockets[(s["slot"], tuple(s["at"]))] = s["interface"]
    for part in doc["parts"]:
        if "mount" not in part:
            continue
        m = part["mount"]
        got = sockets.get((part["slot"], tuple(m["at"])))
        ok("%s's mount meets a socket_%s, the same interface (%s)" % (part["name"], part["slot"], m["interface"]),
           got == m["interface"], "" if got == m["interface"] else "socket there: %s" % got)
    platform = std.get("gun_platforms", {}).get(doc.get("platform", ""))
    if platform:
        body = next(p for p in doc["parts"] if p["slot"] == "body")
        want = platform["sockets"]
        have = {s["slot"]: s["interface"] for s in body["sockets"]}
        ok("the body's sockets are platform %s's" % doc["platform"],
           all(have.get(k) == v for k, v in want.items()),
           ", ".join("%s: %s, not %s" % (k, have.get(k), v) for k, v in want.items() if have.get(k) != v))
    for part in doc["parts"]:
        core = part.get("grip_core")
        if core:
            need = std["held_grip"]["min_length_nano_bricks"] * grid["brick"]
            ok("%s's core is %.1f across and %.1f long (at least %.1f)" % (part["name"], core["d"], core["length"], need),
               core["length"] >= need - 1e-6)
            ok("%s has material all round its core" % part["name"],
               core["spare_side"] >= 0.0 and core["spare_fore_aft"] >= 0.0,
               "to spare: %.2f mm at the sides, %.2f mm fore and aft"
               % (core["spare_side"], core["spare_fore_aft"]))
    bad = sum(1 for l in lines if not l["ok"])
    print("check: %d ok, %d FAIL" % (len(lines) - bad, bad))
    return lines


# ---------------------------------------------------------------------------------- pictures

GREY = (0.40, 0.42, 0.45, 1)
TAN = (0.80, 0.66, 0.42, 1)
COLOURS = {"body": GREY, "barrel": GREY, "muzzle": GREY, "sight": GREY, "magazine": GREY}


def render(prefix, doc, built, size) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    lat = doc["lattice"]
    r, h = doc["stud_d"] * 0.5, doc["stud_h"]
    objects = {}
    for part in doc["parts"]:
        bm = bmesh.new()
        for t in built[part["name"]][0]:
            bm.faces.new([bm.verts.new(tuple(v)) for v in t])
        for p in part["patches"]:
            for s in p["studs"]:
                _stud(bm, Vector(s["at"]), Vector(s["normal"]), r, h)
        objects[part["name"]] = _object(sc, part["name"], bm, COLOURS.get(part["slot"], TAN))

    sc.render.engine = "BLENDER_WORKBENCH"
    sh = sc.display.shading
    sh.light, sh.color_type = "STUDIO", "OBJECT"
    sh.show_cavity = sh.show_object_outline = True
    sh.show_shadows = False
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.9, 0.9, 0.9)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.clip_end = 5000.0
    sc.collection.objects.link(cam)
    sc.camera = cam

    def shoot(tag, d, centre, scale, res):
        d = d.normalized()
        sc.render.resolution_x, sc.render.resolution_y = res
        cam.data.ortho_scale = scale
        cam.location = centre + d * 800.0
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = "%s_%s.png" % (prefix, tag)
        bpy.ops.render.render(write_still=True)
        print("wrote", sc.render.filepath)

    centre = Vector((size[0] * 0.5, lat["cy"], size[2] * 0.5))
    shoot("iso", Vector((0.45, -1.0, 0.42)), centre, size[0] * 1.08, (2000, 800))
    shoot("front", Vector((-0.5, 1.0, 0.55)), centre, size[0] * 1.08, (2000, 800))
    # Taken apart: every part moved off along the gun, a grip down as well.
    spread = 9.0
    order = sorted(doc["parts"], key=lambda p: p["box_mm"][0][0] + p["box_mm"][1][0])
    for n, part in enumerate(order):
        ob = objects[part["name"]]
        ob.location.x = (n - (len(order) - 1) * 0.5) * spread
        if part["slot"] in ("grip", "magazine"):
            ob.location.z = -spread
    shoot("parts", Vector((0.25, -1.0, 0.3)), centre + Vector((0, 0, -spread * 0.4)),
          (size[0] + spread * len(order)) * 1.06, (2000, 800))


def _stud(bm, base: Vector, normal: Vector, r: float, h: float) -> None:
    """Eight sides, tapering to 86%: the house stud, its foot on `base`, along `normal`."""
    turn = Vector((0.0, 0.0, 1.0)).rotation_difference(normal).to_matrix().to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=8, radius1=r, radius2=r * 0.86, depth=h,
        matrix=Matrix.Translation(base + normal * (h * 0.5)) @ turn
        @ Matrix.Rotation(math.radians(22.5), 4, "Z"))


def _object(sc, name, bm, colour):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.color = colour
    sc.collection.objects.link(ob)
    return ob


main()
