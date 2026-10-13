"""The part kit, v1: cut a model into bare parts and put the standard features on them.

    blender --background --factory-startup --python tools/brickify/partkit.py -- \
        <build sheet .json> <absolute out dir>

Docs/Parts/custom.md section 5. The build sheet says WHERE: which model, how it splits into
parts, which faces get stud patches, where each part's mount and sockets are, what bricks dress
it. This file makes each feature to the sizes in Docs/Parts/standards.json, on the part's
lattice, and then checks the result it wrote against those standards.

Writes <name>.parts.json (parts, patches with every stud, mounts, sockets, dressing, the check)
and <name>_iso.png / <name>_parts.png.

v1 makes: parts from a model's loose shells, its small details left out, resized about
their mounts, with the hardness taken off their edges; stud patches on tops and sides,
the part's own face moved onto the lattice plane so the studs are moulded into it; mounts and
sockets snapped to the lattice; the grip core; bricks, adapters and sights pressed on patches.
Not yet: one watertight solid per part, socket patches underneath, the connectors' own shapes at a mount, joints, STLs, a
scene the game loads.
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
## A face is moved onto its lattice plane when it is up to this far short of it (mm): a tick.
MAX_GAP = 0.85
AXES = {"+y": (1, 1.0), "-y": (1, -1.0), "+z": (2, 1.0)}


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    sheet = json.load(open(args[0], encoding="utf-8"))
    out_dir = args[1]
    std = json.load(open(os.path.join(PARTS_DIR, "standards.json"), encoding="utf-8"))
    catalogue = json.load(open(os.path.join(PARTS_DIR, "parts.json"), encoding="utf-8"))
    grid = std["grids"][std["classes"][sheet["class"]]["grid"]]

    shells, size = load_shells(sheet["source"], sheet["print_length"])
    cy = round(float(size[1]) * 0.5, 4)
    lat = {"ox": sheet["lattice"]["x"], "cy": cy, "oz": sheet["lattice"]["z"],
           "pitch": grid["stud_pitch"], "plate": grid["plate"], "tick": grid["tick"]}
    print("%s: %d shells, %.1f x %.1f x %.1f mm at print size" % (sheet["name"], len(shells), *size))

    doc = {"name": sheet["name"], "source": sheet["source"], "class": sheet["class"],
           "platform": sheet.get("platform", ""), "print_mm": [round(float(s), 2) for s in size],
           "lattice": lat, "stud_d": grid["stud_d"], "stud_h": grid["stud_h"], "parts": []}
    built = {}
    taken = set()
    for spec in sheet["parts"]:
        tris = take(shells, spec.get("take", "rest"), taken, sheet.get("drop_shells_under", 0.0))
        if tris is None:
            raise SystemExit("part %s: no shell of the model is in its box" % spec["name"])
        # Resized about its mount, so the joint stays where it is; across, about the centre plane.
        scale = spec.get("scale", [1.0, 1.0, 1.0])
        lo, hi = tris.min(axis=(0, 1)), tris.max(axis=(0, 1))
        px, pz = spec["mount"]["at"] if "mount" in spec else ((lo[0] + hi[0]) * 0.5, (lo[2] + hi[2]) * 0.5)
        tris[..., 0] = px + (tris[..., 0] - px) * scale[0]
        tris[..., 1] = cy + (tris[..., 1] - cy) * scale[1]
        tris[..., 2] = pz + (tris[..., 2] - pz) * scale[2]
        if "soften" in sheet:
            tris = soften(tris, sheet["soften"])
        part = {"name": spec["name"], "role": spec.get("role", "bare"), "slot": spec["slot"],
                "scale": scale, "triangles": int(len(tris)), "patches": [], "sockets": []}
        if "module" in spec:
            part["module"] = spec["module"]
        if "mount" in spec:
            part["mount"] = joint_point(spec["mount"], lat)
        for s in spec.get("sockets", []):
            part["sockets"].append(joint_point(s, lat))
        for p in spec.get("patches", []):
            made = stud_patch(tris, p, lat)
            if made:
                part["patches"].append(made)
            else:
                print("  %s/%s: no flat place for studs there" % (spec["name"], p["name"]))
        bvh = _bvh(tris)
        if spec.get("grip_core"):
            part["grip_core"] = grip_core(tris, bvh, std["held_grip"], grid)
        lo, hi = tris.min(axis=(0, 1)), tris.max(axis=(0, 1))
        part["box_mm"] = [[round(float(c), 2) for c in lo], [round(float(c), 2) for c in hi]]
        doc["parts"].append(part)
        built[spec["name"]] = (tris, spec)

    doc["dressing"] = [dress(d, doc, catalogue, grid) for d in sheet.get("dressing", [])]
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
                raw.append(np.array([[ob.matrix_world @ fv.co for fv in f.verts] for f in faces]))
        bm.free()
    if not raw:
        raise SystemExit("no meshes in %s" % path)
    raw = [np.asarray(t, dtype=np.float64) for t in raw]
    every = np.concatenate(raw)
    lo, hi = every.min(axis=(0, 1)), every.max(axis=(0, 1))
    k = print_len / float((hi - lo).max())
    shells = []
    for tris in raw:
        tris = (tris - lo) * k
        shells.append({"tris": tris, "lo": tris.min(axis=(0, 1)), "hi": tris.max(axis=(0, 1))})
    return shells, (hi - lo) * k


def take(shells, box, taken, drop_under=0.0):
    """The triangles of every shell not yet taken that lies wholly inside `box`
    ({"x": [a, b], "z": [a, b]}, either left out for "any"), or of all that are left.
    A shell smaller than `drop_under` mm every way is a detail, and is left out."""
    out = []
    for i, s in enumerate(shells):
        if i in taken:
            continue
        if float((s["hi"] - s["lo"]).max()) < drop_under:
            taken.add(i)
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
    return np.concatenate(out) if out else None


def _bvh(tris):
    return BVHTree.FromPolygons([Vector(v) for v in tris.reshape(-1, 3)],
                                [(3 * t, 3 * t + 1, 3 * t + 2) for t in range(len(tris))])


def soften(tris, how):
    """Take the hardness off a part's edges and leave it low-poly: every edge sharper than
    `angle_deg` is cut back by `bevel` mm, in `segments` steps.

    The shells are kept as they are. Fusing them on a voxel grid was tried and is not the
    way: an asset-pack shell with open edges comes out of it in pieces.
    """
    bm = bmesh.new()
    for t in tris:
        bm.faces.new([bm.verts.new(tuple(v)) for v in t])
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(1.0), verts=bm.verts[:], edges=bm.edges[:])
    me = bpy.data.meshes.new("soft")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("soft", me)
    bpy.context.scene.collection.objects.link(ob)
    bevel = ob.modifiers.new("bevel", "BEVEL")
    bevel.limit_method = "ANGLE"
    bevel.angle_limit = math.radians(how.get("angle_deg", 30.0))
    bevel.width = how.get("bevel", 0.35)
    bevel.segments = how.get("segments", 2)
    ob.modifiers.new("tri", "TRIANGULATE")
    ev = ob.evaluated_get(bpy.context.evaluated_depsgraph_get())
    out = ev.to_mesh()
    out.calc_loop_triangles()
    co = np.array([v.co[:] for v in out.vertices], dtype=np.float64)
    idx = np.array([t.vertices[:] for t in out.loop_triangles], dtype=int)
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    return co[idx]


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


def stud_patch(tris, spec, lat):
    """Studs on one face, inside the sheet's region, wherever the lattice puts them and the
    surface is flat enough to carry them: the biggest whole rectangle of such places.

    The studs stand on a plane of the lattice at or just outside the surface, and the part's
    own face is moved out onto that plane (`tris` is changed): the studs are moulded into
    the part, not set on a slab.
    """
    bvh = _bvh(tris)
    axis, sign = AXES[spec["face"]]
    pitch = lat["pitch"]
    region = spec["region"]
    us = _centres(region["x"], lat["ox"], pitch, half=True)
    if axis == 1:
        vs = _centres(region["z"], lat["oz"], pitch, half=True)
        ref, step = lat["cy"], lat["tick"]
    else:
        vs = _centres(region.get("y", [-0.1, 0.1]), 0.0, pitch, half=False) + lat["cy"]
        ref, step = lat["oz"], lat["tick"]
    if not len(us) or not len(vs):
        return None
    depth = np.full((len(us), len(vs)), np.nan)
    for i, u in enumerate(us):
        for j, v in enumerate(vs):
            o = Vector((u, 0.0, 0.0))
            o[axis] = ref + sign * 1000.0
            o[3 - axis] = v
            d = Vector((0.0, 0.0, 0.0))
            d[axis] = -sign
            hit = bvh.ray_cast(o, d)
            if hit[0] is not None and abs(hit[1][axis]) >= 0.9:
                depth[i, j] = sign * (hit[0][axis] - ref)
    if np.isnan(depth).all():
        return None
    plane = math.ceil((float(np.nanmedian(depth)) - 0.02) / step) * step
    gap = plane - depth
    ok = (gap >= -0.05) & (gap <= MAX_GAP)
    rect = _biggest_rectangle(ok)
    if rect is None:
        return None
    i0, i1, j0, j1 = rect
    # Move the face under the patch onto the plane: every triangle that faces this way and
    # lies in the depths the patch found, and with it every corner that shares a place.
    found = depth[i0:i1, j0:j1]
    near, far = float(np.nanmin(found)) - 0.1, float(np.nanmax(found)) + 0.1
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
    normal = np.cross(b - a, c - a)
    normal /= np.maximum(np.linalg.norm(normal, axis=1, keepdims=True), 1e-12)
    d_all = sign * (tris[..., axis] - ref)
    face = (np.abs(normal[:, axis]) >= 0.9) & (d_all.min(axis=1) >= near) & (d_all.max(axis=1) <= far)
    flat = tris.reshape(-1, 3)
    keys = {tuple(k) for k in np.round(tris[face].reshape(-1, 3) * 1000.0).astype(np.int64)}
    every = np.round(flat * 1000.0).astype(np.int64)
    move = np.array([tuple(k) in keys for k in every])
    flat[move, axis] = ref + sign * plane
    studs = []
    for i in range(i0, i1):
        for j in range(j0, j1):
            p = [float(us[i]), 0.0, 0.0]
            p[axis] = ref + sign * plane
            p[3 - axis] = float(vs[j])
            studs.append([round(c, 4) for c in p])
    return {"name": spec["name"], "face": spec["face"], "plane": round(ref + sign * plane, 4),
            "cells": [i1 - i0, j1 - j0],
            "u": [round(float(us[i0]) - pitch * 0.5, 4), round(float(us[i1 - 1]) + pitch * 0.5, 4)],
            "v": [round(float(vs[j0]) - pitch * 0.5, 4), round(float(vs[j1 - 1]) + pitch * 0.5, 4)],
            "max_gap": round(float(np.nanmax(gap[i0:i1, j0:j1])), 3), "studs": studs}


def _centres(span, origin, pitch, half):
    """Lattice positions inside [span]: cell centres between lines from `origin` (half), or
    the lines themselves."""
    off = 0.5 if half else 0.0
    first = math.ceil((span[0] - origin) / pitch - off - 1e-9)
    last = math.floor((span[1] - origin) / pitch - off + 1e-9)
    return np.array([origin + (n + off) * pitch for n in range(first, last + 1)])


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


def grip_core(tris, bvh, held, grid):
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

    stations = [float(v) for v in np.linspace(a + (b - a) * 0.2, b - (b - a) * 0.2, 5)]
    # Slide the line fore and aft to the middle of the grip, then measure what is left.
    centre += across * float(np.mean([(reach(centre + axis * v, across) - reach(centre + axis * v, -across)) * 0.5
                                      for v in stations]))
    side = min(min(reach(centre + axis * v, up), reach(centre + axis * v, -up)) for v in stations) - r
    fore_aft = min(min(reach(centre + axis * v, across), reach(centre + axis * v, -across))
                   for v in stations) - r
    return {"d": held["core_d"], "sides": held["core_sides"], "length": round(b - a, 3),
            "from": [round(float(c), 4) for c in centre + axis * a],
            "to": [round(float(c), 4) for c in centre + axis * b],
            "spare_side": round(float(side), 3), "spare_fore_aft": round(float(fore_aft), 3)}


def dress(spec, doc, catalogue, grid):
    """Something pressed onto a patch. `cell` is where its corner goes, in studs along the
    patch; `lift` is how many plates of other things are under it.

    A catalogue brick (`brick`, with `turn` to lay its long side across), or a part made
    here (`make`): a "rail" -- a strip with studs on top, as an adapter is -- or a "sight",
    a single piece with no studs.
    """
    out = {"on": spec["on"], "cell": spec["cell"], "lift": spec.get("lift", 0),
           "colour": spec.get("colour", [0.2, 0.22, 0.25]), "role": spec.get("role", "dressing")}
    if "make" in spec:
        out.update({"name": spec["name"], "shape": spec["make"], "studs": spec["studs"],
                    "plates": spec["plates"]})
        for key in ("slot", "mount", "socket"):
            if key in spec:
                out[key] = spec[key]
    else:
        base = spec["brick"][len(grid["part_prefix"]):]
        w, l = catalogue[base]["studs_wl"]
        out.update({"name": spec["brick"], "shape": "brick",
                    "studs": [w, l] if spec.get("turn") else [l, w],
                    "plates": catalogue[base]["plates"]})
    out["breaks_off"] = out["role"] == "dressing"
    return out


def find_patch(doc, on):
    part_name, patch_name = on.split("/")
    for part in doc["parts"]:
        if part["name"] == part_name:
            for p in part["patches"]:
                if p["name"] == patch_name:
                    return p
    return None


# ---------------------------------------------------------------------------------- the check

def check(doc, std, grid):
    """Measure what was written against the standards. Reads `doc` only."""
    lat = doc["lattice"]
    lines = []

    def ok(what, good, detail=""):
        lines.append({"ok": bool(good), "what": what, "detail": detail})
        print("  %s  %s%s" % ("ok  " if good else "FAIL", what, ("  -- " + detail) if detail else ""))

    def whole(x):
        return abs(x - round(x)) < 1e-6

    ok("studs are the grid's: %.2f across, %.2f tall" % (grid["stud_d"], grid["stud_h"]),
       doc["stud_d"] == grid["stud_d"] and doc["stud_h"] == grid["stud_h"])
    count = 0
    off = []
    for part in doc["parts"]:
        for p in part["patches"]:
            axis, sign = AXES[p["face"]]
            for s in p["studs"]:
                count += 1
                good = whole((s[0] - lat["ox"]) / lat["pitch"] - 0.5)
                if axis == 1:
                    good = good and whole((s[2] - lat["oz"]) / lat["pitch"] - 0.5) \
                        and whole((s[1] - lat["cy"]) / lat["tick"])
                else:
                    good = good and whole((s[1] - lat["cy"]) / lat["pitch"]) \
                        and whole((s[2] - lat["oz"]) / lat["tick"])
                if not good:
                    off.append("%s/%s" % (part["name"], p["name"]))
            if p["max_gap"] > MAX_GAP:
                off.append("%s/%s pad %.2f" % (part["name"], p["name"], p["max_gap"]))
    ok("every stud is on its part's lattice (%d studs)" % count, not off, ", ".join(sorted(set(off))))

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
    for d in doc["dressing"]:
        patch = find_patch(doc, d["on"])
        if patch is None:
            ok("%s sits on studs of %s" % (d["name"], d["on"]), False, "there is no such patch")
            continue
        fits =d["cell"][0] >= 0 and d["cell"][1] >= 0 \
            and d["cell"][0] + d["studs"][0] <= patch["cells"][0] \
            and d["cell"][1] + d["studs"][1] <= patch["cells"][1]
        ok("%s sits on studs of %s" % (d["name"], d["on"]), fits)
        for key in ("mount", "socket"):
            if key in d:
                ok("%s's %s is an interface the standards name (%s)" % (d["name"], key, d[key]),
                   d[key] in known)
    bad = sum(1 for l in lines if not l["ok"])
    print("check: %d ok, %d FAIL" % (len(lines) - bad, bad))
    return lines


# ---------------------------------------------------------------------------------- pictures

COLOURS = {"body": (0.40, 0.42, 0.45, 1), "barrel": (0.40, 0.42, 0.45, 1),
           "muzzle": (0.40, 0.42, 0.45, 1), "sight": (0.40, 0.42, 0.45, 1),
           "magazine": (0.40, 0.42, 0.45, 1)}
TAN = (0.80, 0.66, 0.42, 1)


def render(prefix, doc, built, size) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    lat = doc["lattice"]
    pitch = lat["pitch"]
    r, h = doc["stud_d"] * 0.5, doc["stud_h"]
    objects = {}
    for part in doc["parts"]:
        tris, spec = built[part["name"]]
        bm = bmesh.new()
        for t in tris:
            vs = [bm.verts.new(tuple(v)) for v in t]
            bm.faces.new(vs)
        for p in part["patches"]:
            axis, sign = AXES[p["face"]]
            normal = Vector((0.0, 0.0, 0.0))
            normal[axis] = sign
            for s in p["studs"]:
                _stud(bm, Vector(s), normal, r, h)
        core = part.get("grip_core")
        colour = COLOURS.get(part["slot"], TAN)
        objects[part["name"]] = _object(sc, part["name"], bm, colour)
    for n, d in enumerate(doc["dressing"]):
        patch = find_patch(doc, d["on"])
        if patch is None:
            continue
        part_name = d["on"].split("/")[0]
        axis, sign = AXES[patch["face"]]
        normal = Vector((0.0, 0.0, 0.0))
        normal[axis] = sign
        lo = [patch["u"][0] + d["cell"][0] * pitch, 0.0, 0.0]
        hi = [lo[0] + d["studs"][0] * pitch, 0.0, 0.0]
        lo[3 - axis] = patch["v"][0] + d["cell"][1] * pitch
        hi[3 - axis] = lo[3 - axis] + d["studs"][1] * pitch
        foot = patch["plane"] + sign * d["lift"] * lat["plate"]
        thick = (1 if d["shape"] == "sight" else d["plates"]) * lat["plate"]
        outer = foot + sign * thick
        lo[axis], hi[axis] = sorted((foot, outer))
        bm = bmesh.new()
        g = pitch * 0.015
        shrink = [g, g, g]
        shrink[axis] = 0.0
        _box(bm, [lo[k] + shrink[k] for k in range(3)], [hi[k] - shrink[k] for k in range(3)])
        if d["shape"] == "sight":
            # A base and two ears at its back end, a notch between them.
            tall = (d["plates"] - 1) * lat["plate"]
            u0 = lo[0] + (hi[0] - lo[0]) * 0.55
            for side in (0, 1):
                e_lo, e_hi = [u0, 0.0, 0.0], [hi[0] - g, 0.0, 0.0]
                v_lo, v_hi = lo[3 - axis] + g, hi[3 - axis] - g
                wide = (v_hi - v_lo) * 0.28
                e_lo[3 - axis] = v_lo if side == 0 else v_hi - wide
                e_hi[3 - axis] = v_lo + wide if side == 0 else v_hi
                e_lo[axis], e_hi[axis] = sorted((outer, outer + sign * tall))
                _box(bm, e_lo, e_hi)
        else:
            for a in range(d["studs"][0]):
                for b in range(d["studs"][1]):
                    at = [lo[0] + (a + 0.5) * pitch, 0.0, 0.0]
                    at[3 - axis] = lo[3 - axis] + (b + 0.5) * pitch
                    at[axis] = outer
                    _stud(bm, Vector(at), normal, r, h)
        ob = _object(sc, "dress%d" % n, bm, tuple(d["colour"]) + (1,))
        ob.parent = objects[part_name]

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
    shoot("iso", Vector((0.45, -1.0, 0.42)), centre, size[0] * 1.12, (2000, 900))
    # Taken apart: every part moved off along the gun, a grip down as well.
    spread = 9.0
    order = sorted(doc["parts"], key=lambda p: p["box_mm"][0][0] + p["box_mm"][1][0])
    for n, part in enumerate(order):
        ob = objects[part["name"]]
        ob.location.x = (n - (len(order) - 1) * 0.5) * spread
        if part["slot"] in ("grip", "magazine"):
            ob.location.z = -spread
    shoot("parts", Vector((0.25, -1.0, 0.3)), centre + Vector((0, 0, -spread * 0.4)),
          (size[0] + spread * len(order)) * 1.06, (2000, 900))


def _box(bm, lo, hi) -> None:
    centre = Vector([(lo[k] + hi[k]) * 0.5 for k in range(3)])
    dims = Vector([hi[k] - lo[k] for k in range(3)] + [1.0])
    bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation(centre) @ Matrix.Diagonal(dims))


def _stud(bm, base: Vector, normal: Vector, r: float, h: float) -> None:
    """Eight sides, tapering to 86%: the house stud, its foot on `base`."""
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
