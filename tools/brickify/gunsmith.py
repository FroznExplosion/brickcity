"""Build a gun from our own drawn shapes: brick-built parts, custom parts, studs, sockets.

    blender --background --factory-startup --python tools/brickify/gunsmith.py -- \
        <build sheet .json> <absolute out dir>

Docs/Parts/custom.md. Nothing here comes from a bought model: every shape is an outline
drawn in the build sheet, on the nano grid, so what it makes is ours to publish.

A part is one of three kinds:

  bricks   an outline in side view, so many studs wide: filled with nano bricks by the packer
           of brickify.py. Its top is tiled smooth except where the sheet leaves studs.
  profile  an outline in side view, so thick, its edges cut back: one closed solid, a custom
           piece. It may carry stud patches on its sides and the underside of a brick below.
  turned   round about a line along the gun, eight-sided: a barrel, a muzzle piece.

Lengths are mm at print size: x along the gun from the muzzle, z up, y across with the centre
plane at 0. The lattice is the nano grid from (0, 0, 0): stud lines every 4 mm along x and
across y, plate lines every 1.6 mm up z.

Writes <name>.parts.json and <name>_side.png / _iso.png / _under.png / _parts.png.

Not yet: slopes and curves on the brick-built parts, the connectors' own shapes at a mount,
STLs, a scene the game loads.
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
sys.path.insert(0, HERE)
import brickify  # noqa: E402  (the packer)

## mm of flat face left round a stud.
LIP = 0.3


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    sheet = json.load(open(args[0], encoding="utf-8"))
    out_dir = args[1]
    std = json.load(open(os.path.join(PARTS_DIR, "standards.json"), encoding="utf-8"))
    grid = std["grids"][std["classes"][sheet["class"]]["grid"]]
    bpy.ops.wm.read_factory_settings(use_empty=True)

    doc = {"name": sheet["name"], "class": sheet["class"], "platform": sheet.get("platform", ""),
           "reference": sheet.get("reference", ""), "stud_d": grid["stud_d"], "stud_h": grid["stud_h"],
           "parts": []}
    objects = {}
    for spec in sheet["parts"]:
        part = {"name": spec["name"], "kind": spec["kind"], "slot": spec["slot"],
                "role": spec.get("role", "bare"), "studs": [], "sockets": []}
        if "module" in spec:
            part["module"] = spec["module"]
        if "mount" in spec:
            part["mount"] = joint(spec["mount"])
        part["sockets"] = [joint(s) for s in spec.get("sockets", [])]
        if spec["kind"] == "bricks":
            bm = bricks(spec, part, grid)
        elif spec["kind"] == "profile":
            bm = profile(spec, part, grid)
        else:
            bm = turned(spec, part)
        for b in spec.get("boxes", []):
            _box(bm, [b[0][0], b[1][0], b[2][0]], [b[0][1], b[1][1], b[2][1]])
        for s in part["studs"]:
            _stud(bm, Vector(s["at"]), Vector(s["normal"]), grid["stud_d"] * 0.5, grid["stud_h"])
        me = bpy.data.meshes.new(spec["name"])
        bm.to_mesh(me)
        bm.free()
        ob = bpy.data.objects.new(spec["name"], me)
        ob.color = tuple(spec.get("colour", [0.5, 0.5, 0.5])) + (1.0,)
        bpy.context.scene.collection.objects.link(ob)
        objects[spec["name"]] = ob
        if spec.get("grip_core"):
            part["grip_core"] = grip_core(ob, std["held_grip"])
        lo = [min(v.co[k] for v in me.vertices) for k in range(3)]
        hi = [max(v.co[k] for v in me.vertices) for k in range(3)]
        part["box_mm"] = [[round(c, 2) for c in lo], [round(c, 2) for c in hi]]
        doc["parts"].append(part)
        print("  %-12s %-8s %s" % (spec["name"], spec["kind"], part.get("summary", "")))

    lo = [min(p["box_mm"][0][k] for p in doc["parts"]) for k in range(3)]
    hi = [max(p["box_mm"][1][k] for p in doc["parts"]) for k in range(3)]
    doc["print_mm"] = [round(hi[k] - lo[k], 1) for k in range(3)]
    held = std["scale"]["held_scale"]
    doc["game_m"] = [round(c * std["scale"]["game_m_per_mm"] * held, 3) for c in doc["print_mm"]]
    print("%s: %.1f x %.1f x %.1f mm printed (%.2f in long), %.2f m long in the game"
          % (sheet["name"], *doc["print_mm"], doc["print_mm"][0] / 25.4, doc["game_m"][0]))
    doc["check"] = check(doc, std, grid)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, sheet["name"] + ".parts.json")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)
    print("wrote", path)
    render(os.path.join(out_dir, sheet["name"]), doc, objects, lo, hi)


def joint(spec):
    x, z = spec["at"]
    return {"slot": spec.get("slot", ""), "interface": spec["interface"], "at": [x, 0.0, z]}


# ---------------------------------------------------------------------------------- bricks

def bricks(spec, part, grid):
    """An outline filled with nano bricks, `wide` studs across, centred on the centre plane."""
    pitch, plate = grid["stud_pitch"], grid["plate"]
    poly = spec["outline"]
    x0 = math.floor(min(p[0] for p in poly) / pitch)
    x1 = math.ceil(max(p[0] for p in poly) / pitch)
    z0 = math.floor(min(p[1] for p in poly) / plate + 1e-6)
    z1 = math.ceil(max(p[1] for p in poly) / plate - 1e-6)
    wide = spec["wide"]
    solid = np.zeros((x1 - x0, wide, z1 - z0), dtype=bool)
    for i in range(x1 - x0):
        for k in range(z1 - z0):
            if _inside(poly, (x0 + i + 0.5) * pitch, (z0 + k + 0.5) * plate, 0.0):
                solid[i, :, k] = True
    boxes = brickify.box_parts(grid["part_prefix"])
    best = None
    for course in range(3):
        got, own = brickify.pack(solid, boxes, course)
        got, own = brickify.repair(solid, boxes, course, got, own)
        loose = brickify.connectivity(got, own)
        if best is None or (len(loose), len(got)) < (len(best[1]), len(best[0])):
            best = (got, loose)
    placed, loose = best
    origin = np.array([x0 * pitch, -wide * pitch * 0.5, z0 * plate])
    cell = np.array([pitch, pitch, plate])
    bm = bmesh.new()
    gap = pitch * 0.012
    part["bricks"] = []
    for p in placed:
        lo = origin + np.array(p["min"]) * cell
        hi = lo + np.array(p["size"]) * cell
        _box(bm, [lo[0] + gap, lo[1] + gap, lo[2]], [hi[0] - gap, hi[1] - gap, hi[2] - gap * 0.4])
        part["bricks"].append({"part": p["part"], "turn": p["turn"],
                               "min_mm": [round(float(c), 3) for c in lo],
                               "size": [int(c) for c in p["size"]]})
        # Studs only on open tops, and only where the sheet leaves them: the rest is tiled.
        top = p["min"][2] + p["size"][2]
        for i in range(p["min"][0], p["min"][0] + p["size"][0]):
            for j in range(p["min"][1], p["min"][1] + p["size"][1]):
                if top < solid.shape[2] and solid[i, j, top]:
                    continue
                at = origin + np.array([i + 0.5, j + 0.5, top]) * cell
                if any(a <= at[0] <= b for a, b in spec.get("studs_x", [])):
                    part["studs"].append({"at": [round(float(c), 4) for c in at],
                                          "normal": [0.0, 0.0, 1.0], "on": "top"})
    part["loose"] = len(loose)
    part["summary"] = "%d bricks, %d loose, %d studs left on top" % (len(placed), len(loose), len(part["studs"]))
    return bm


# ---------------------------------------------------------------------------------- profile

def profile(spec, part, grid):
    """An outline in side view, `thick` across, edges cut back by `bevel`: one closed solid.
    With stud patches on its sides and, if asked, the underside of a brick below."""
    thick, bevel = spec["thick"], spec.get("bevel", 0.0)
    bm = _extrude(spec["outline"], thick, bevel)
    for extra in spec.get("extras", []):
        other = _extrude(extra["outline"], extra["thick"], extra.get("bevel", 0.0))
        tmp = bpy.data.meshes.new("tmp")
        other.to_mesh(tmp)
        other.free()
        bm.from_mesh(tmp)
        bpy.data.meshes.remove(tmp)
    part["closed"] = all(len(e.link_faces) == 2 for e in bm.edges)
    pitch, r = grid["stud_pitch"], grid["stud_d"] * 0.5
    for patch in spec.get("studs", []):
        sign = 1.0 if patch["face"] == "+y" else -1.0
        zo = patch["z"][0]
        nx = int(round((patch["x"][1] - patch["x"][0]) / pitch))
        nz = int(round((patch["z"][1] - patch["z"][0]) / pitch))
        ok = np.zeros((nx, nz), dtype=bool)
        for i in range(nx):
            for k in range(nz):
                ok[i, k] = _inside(spec["outline"], patch["x"][0] + (i + 0.5) * pitch,
                                   zo + (k + 0.5) * pitch, bevel + r + LIP)
        rect = _biggest_rectangle(ok)
        if rect is None:
            continue
        for i in range(rect[0], rect[1]):
            for k in range(rect[2], rect[3]):
                part["studs"].append({"at": [patch["x"][0] + (i + 0.5) * pitch, sign * thick * 0.5,
                                             round(zo + (k + 0.5) * pitch, 4)],
                                      "normal": [0.0, sign, 0.0], "on": patch["face"], "z0": zo})
    under = spec.get("under")
    if under:
        bm = _brick_underside(bm, spec, under, grid)
        part["under"] = under
    part["summary"] = "%s solid, %d studs%s" % ("closed" if part["closed"] else "OPEN", len(part["studs"]),
                                                ", brick underside" if under else "")
    return bm


def _extrude(outline, thick, bevel):
    bm = bmesh.new()
    face = bm.faces.new([bm.verts.new((x, -thick * 0.5, z)) for x, z in outline])
    got = bmesh.ops.extrude_face_region(bm, geom=[face])
    bmesh.ops.translate(bm, verts=[g for g in got["geom"] if isinstance(g, bmesh.types.BMVert)],
                        vec=(0.0, thick, 0.0))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    if bevel > 0.0:
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=bevel, segments=1, affect="EDGES", profile=0.5)
    return bm


def _brick_underside(bm, spec, under, grid):
    """Hollow the bottom like a brick's: a pocket with a wall round it, and the tubes that
    grip studs along its middle."""
    pitch = grid["stud_pitch"]
    wall = spec.get("bevel", 0.0) + 0.5
    zb = min(p[1] for p in spec["outline"])
    half = spec["thick"] * 0.5 - wall
    me = bpy.data.meshes.new("a")
    bm.to_mesh(me)
    bm.free()
    a = bpy.data.objects.new("a", me)
    cut = bmesh.new()
    _box(cut, [under["x"][0], -half, zb - 1.0], [under["x"][1], half, zb + under["depth"]])
    cme = bpy.data.meshes.new("b")
    cut.to_mesh(cme)
    cut.free()
    b = bpy.data.objects.new("b", cme)
    for ob in (a, b):
        bpy.context.scene.collection.objects.link(ob)
    mod = a.modifiers.new("pocket", "BOOLEAN")
    mod.operation, mod.object, mod.solver = "DIFFERENCE", b, "EXACT"
    done = bpy.data.meshes.new_from_object(a.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    out = bmesh.new()
    out.from_mesh(done)
    for ob in (a, b):
        bpy.data.objects.remove(ob)
    tube_r = grid["stud_d"] * 0.5 * 1.354  # a brick's tube: 6.51 over a 4.8 stud
    x = math.ceil((under["x"][0] + pitch * 0.5) / pitch) * pitch
    while x <= under["x"][1] - pitch * 0.5 + 1e-6:
        bmesh.ops.create_cone(out, cap_ends=False, segments=8, radius1=tube_r, radius2=tube_r,
                              depth=under["depth"],
                              matrix=Matrix.Translation(Vector((x, 0.0, zb + under["depth"] * 0.5)))
                              @ Matrix.Rotation(math.radians(22.5), 4, "Z"))
        x += pitch
    return out


# ---------------------------------------------------------------------------------- turned

def turned(spec, part):
    """Round about a line along the gun at height `axis_z`, eight-sided: a list of
    [x from, x to, radius], and rings (`fins`) alternating two radii."""
    sections = [list(s) for s in spec.get("sections", [])]
    fins = spec.get("fins")
    if fins:
        x, n = fins["x"][0], 0
        while x < fins["x"][1] - 1e-6:
            sections.append([x, min(x + fins["pitch"], fins["x"][1]), fins["r"][n % 2]])
            x += fins["pitch"]
            n += 1
    bm = bmesh.new()
    turn = Matrix.Rotation(math.radians(90.0), 4, "Y")
    for x0, x1, r in sections:
        bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=r, radius2=r, depth=x1 - x0,
                              matrix=Matrix.Translation(Vector(((x0 + x1) * 0.5, 0.0, spec["axis_z"])))
                              @ turn @ Matrix.Rotation(math.radians(22.5), 4, "Z"))
    part["closed"] = True
    part["summary"] = "%d sections" % len(sections)
    return bm


# ---------------------------------------------------------------------------------- helpers

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
        if margin > 0.0 and math.hypot(a - (x0 + t * dx), b - (y0 + t * dy)) < margin:
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


def grip_core(ob, held):
    """The round core a hand closes on: along the grip's own long line, centred in it, and
    how much of the grip is left round it over the middle three fifths of its length."""
    me = ob.data
    me.calc_loop_triangles()
    co = np.array([v.co[:] for v in me.vertices])
    tris = co[np.array([t.vertices[:] for t in me.loop_triangles], dtype=int)]
    # The grip itself is the thickest run of the part: leave thin extras (a guard) out.
    wide = np.abs(tris[..., 1]).max(axis=1) >= np.abs(co[:, 1]).max() - 0.9
    pts = tris[wide].reshape(-1, 3)
    bvh = BVHTree.FromPolygons([Vector(v) for v in tris.reshape(-1, 3)],
                               [(3 * t, 3 * t + 1, 3 * t + 2) for t in range(len(tris))])
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
    centre = Vector((float(mid[0]), 0.0, float(mid[2])))

    def reach(c, d):
        hit = bvh.ray_cast(c, d)
        return hit[3] if hit[0] is not None else 0.0

    stations = [float(s) for s in np.linspace(a + (b - a) * 0.2, b - (b - a) * 0.2, 5)]
    centre += across * float(np.mean([(reach(centre + axis * s, across) - reach(centre + axis * s, -across)) * 0.5
                                      for s in stations]))
    side = min(min(reach(centre + axis * s, up), reach(centre + axis * s, -up)) for s in stations) - r
    fore_aft = min(min(reach(centre + axis * s, across), reach(centre + axis * s, -across))
                   for s in stations) - r
    return {"d": held["core_d"], "length": round(b - a, 3),
            "spare_side": round(float(side), 3), "spare_fore_aft": round(float(fore_aft), 3)}


def _box(bm, lo, hi) -> None:
    centre = Vector([(lo[k] + hi[k]) * 0.5 for k in range(3)])
    dims = Vector([hi[k] - lo[k] for k in range(3)] + [1.0])
    bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation(centre) @ Matrix.Diagonal(dims))


def _stud(bm, base: Vector, normal: Vector, r: float, h: float) -> None:
    turn = Vector((0.0, 0.0, 1.0)).rotation_difference(normal).to_matrix().to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=8, radius1=r, radius2=r * 0.86, depth=h,
        matrix=Matrix.Translation(base + normal * (h * 0.5)) @ turn
        @ Matrix.Rotation(math.radians(22.5), 4, "Z"))


# ---------------------------------------------------------------------------------- the check

def check(doc, std, grid):
    """Measure what was made against the standards. Reads `doc` only."""
    pitch, plate, tick = grid["stud_pitch"], grid["plate"], grid["tick"]
    lines = []

    def ok(what, good, detail=""):
        lines.append({"ok": bool(good), "what": what, "detail": detail})
        print("  %s  %s%s" % ("ok  " if good else "FAIL", what, ("  -- " + detail) if detail else ""))

    def whole(x):
        return abs(x - round(x)) < 1e-6

    off, count = [], 0
    for part in doc["parts"]:
        for s in part["studs"]:
            count += 1
            x, y, z = s["at"]
            good = whole(x / pitch - 0.5)
            if s["on"] == "top":
                good = good and whole(y / pitch - 0.5) and whole(z / plate)
            else:
                good = good and whole(y / tick) and whole((z - s["z0"]) / pitch - 0.5) and whole(s["z0"] / plate)
            if not good:
                off.append(part["name"])
    ok("every stud is on the lattice (%d studs)" % count, not off, ", ".join(sorted(set(off))))
    built = [p for p in doc["parts"] if p["kind"] == "bricks"]
    ok("every brick is held by studs (%d bricks)" % sum(len(p["bricks"]) for p in built),
       all(p["loose"] == 0 for p in built),
       ", ".join("%s: %d loose" % (p["name"], p["loose"]) for p in built if p["loose"]))
    custom = [p for p in doc["parts"] if p["kind"] != "bricks"]
    ok("every custom part is one closed solid (%d parts)" % len(custom), all(p["closed"] for p in custom),
       ", ".join(p["name"] for p in custom if not p["closed"]))
    points = [j for p in doc["parts"] for j in ([p["mount"]] if "mount" in p else []) + p["sockets"]]
    ok("every mount and socket is on a lattice point (%d)" % len(points),
       all(whole(j["at"][0] / pitch) and whole(j["at"][2] / plate) for j in points))
    known = std.get("gun_interfaces", {})
    ok("every interface is one the standards name", all(j["interface"] in known for j in points),
       ", ".join(sorted({j["interface"] for j in points if j["interface"] not in known})))
    sockets = {(s["slot"], tuple(s["at"])): s["interface"] for p in doc["parts"] for s in p["sockets"]}
    for part in doc["parts"]:
        if "mount" in part:
            m = part["mount"]
            got = sockets.get((part["slot"], tuple(m["at"])))
            ok("%s's mount meets a socket_%s, the same interface (%s)" % (part["name"], part["slot"], m["interface"]),
               got == m["interface"], "" if got == m["interface"] else "socket there: %s" % got)
    platform = std.get("gun_platforms", {}).get(doc.get("platform", ""))
    if platform:
        body = next(p for p in doc["parts"] if p["slot"] == "body" and p["sockets"])
        have = {s["slot"]: s["interface"] for s in body["sockets"]}
        want = platform["sockets"]
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
               "to spare: %.2f mm at the sides, %.2f mm fore and aft" % (core["spare_side"], core["spare_fore_aft"]))
    bad = sum(1 for l in lines if not l["ok"])
    print("check: %d ok, %d FAIL" % (len(lines) - bad, bad))
    return lines


# ---------------------------------------------------------------------------------- pictures

def render(prefix, doc, objects, lo, hi) -> None:
    sc = bpy.context.scene
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
    centre = Vector([(lo[k] + hi[k]) * 0.5 for k in range(3)])
    long = hi[0] - lo[0]

    def shoot(tag, d, at, scale, res=(2200, 900)):
        d = d.normalized()
        sc.render.resolution_x, sc.render.resolution_y = res
        cam.data.ortho_scale = scale
        cam.location = at + d * 800.0
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = "%s_%s.png" % (prefix, tag)
        bpy.ops.render.render(write_still=True)
        print("wrote", sc.render.filepath)

    shoot("side", Vector((0.0, -1.0, 0.0)), centre, long * 1.06)
    shoot("iso", Vector((0.5, -1.0, 0.42)), centre, long * 1.06)
    shoot("under", Vector((-0.35, -0.8, -1.0)), centre, long * 1.06)
    away = {"barrel": (-8, 0), "muzzle": (-16, 0), "underbarrel": (-8, -9), "grip": (0, -9),
            "magazine": (0, -12), "stock": (9, 0), "sight": (0, 8)}
    for part in doc["parts"]:
        dx, dz = away.get(part["slot"], (0, 0)) if "mount" in part else (0, 0)
        objects[part["name"]].location = (dx, 0.0, dz)
    shoot("parts", Vector((0.3, -1.0, 0.3)), centre + Vector((0, 0, -3)), (long + 28) * 1.06)


if __name__ == "__main__":
    main()
