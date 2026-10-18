"""Print files for a gun from its build sheet (the asset workshop's export, kind "placed"):
each part one watertight solid at print size, to slice and print.

    blender --background --factory-startup --python printkit.py -- <sheet.json> <out dir>

Writes <out dir>/<part>.stl (millimetres) to print the parts apart and plug them together,
<out dir>/<name>_whole.stl to print the gun as one piece, <out dir>/<name>_print_iso.png and
<out dir>/<name>.print.json (each part: watertight or not, pieces, studs, stud holes, size).

How a part is made (Docs/AssetWorkshop.md, "Into the game, stage 3"):
  - its plain bricks as ONE shell: the outside faces of all their cells, so bricks laid
    side by side print as one piece, not a pile of boxes that only touch;
  - its slopes and curves from the catalogue (gunsmith._shaped), welded closed and grown
    by a hair so they overlap the shell instead of touching it face to face;
  - its studs (and the studs put on by hand) sunk a hair into it;
  - all of that unioned into one solid;
  - and where it sits on another part's studs, a stud hole cut up into it (the stud's
    diameter plus the grid's side clearance, a hair deeper than the stud), so the parts
    plug together as the bricks do.
Coplanar faces are what break a boolean (the brick generator's lesson): every overlap
here is a deliberate hair, never a shared face.
"""
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gunsmith as gs  # noqa: E402  (its catalogue, shaped parts, orientation, studs)

HAIR = 0.02          # mm: how far a stud sinks, a slope grows, a hole reaches past a face
SHELL_GROW = 0.08    # mm: how far a shell grows to weld to the parts it meets (asset workshop shells)
HOLE_SEGMENTS = 16


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    sheet = json.load(open(args[0], encoding="utf-8"))
    out_dir = args[1]
    std = json.load(open(os.path.join(gs.PARTS_DIR, "standards.json"), encoding="utf-8"))
    grid = std["grids"][std["classes"][sheet["class"]]["grid"]]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    os.makedirs(out_dir, exist_ok=True)

    parts = [p for p in sheet["parts"] if p["kind"] == "placed"]
    layout = {p["name"]: lay_out(p, grid) for p in parts}
    report = {"name": sheet["name"], "grid": "nano", "stud_d": grid["stud_d"],
              "hole_d": round(grid["stud_d"] + 2 * grid["clearance_side"], 3), "parts": []}
    objects = {}
    for spec in parts:
        name = spec["name"]
        me = layout[name]
        # The studs of the other parts this one sits on: a hole for each.
        holes = []
        for other, them in layout.items():
            if other == name:
                continue
            for at, normal in them["studs"]:
                if normal[2] > 0.99 and covers(me["cells"], at, grid):
                    holes.append(at)
        ob = build(spec, me, holes, grid)
        ob.color = tuple(spec.get("colour", [0.6, 0.6, 0.6])) + (1.0,)
        objects[name] = ob
        info = inspect(ob)
        info.update({"part": name, "studs": len(me["studs"]), "holes": len(holes)})
        path = os.path.join(out_dir, name + ".stl")
        export_stl(ob, path)
        info["stl"] = path
        report["parts"].append(info)
        print("  %-12s %s, %d piece(s), %d studs, %d holes, %.1f x %.1f x %.1f mm%s" % (
            name, "watertight" if info["watertight"] else "NOT WATERTIGHT", info["pieces"],
            info["studs"], info["holes"], *info["size_mm"],
            ("  (%d edge(s) where blocks touch only along a line)" % info["pinched_edges"]) if info["pinched_edges"] else ""))

    lo = [min(o.bound_box[i][k] + o.location[k] for o in objects.values() for i in range(8)) for k in range(3)]
    hi = [max(o.bound_box[i][k] + o.location[k] for o in objects.values() for i in range(8)) for k in range(3)]
    report["print_mm"] = [round(hi[k] - lo[k], 1) for k in range(3)]
    # A part may be more than one piece (a front and a rear sight); a piece no bigger than a
    # stud is a fault -- something meant to join that did not.
    small = grid["stud_d"] * 1.5
    for p in report["parts"]:
        p["loose_bits"] = sum(1 for b in p.get("piece_boxes_mm", [])
                              if max(b[1][k] - b[0][k] for k in range(3)) < small)
    report["ok"] = all(p["watertight"] and p["loose_bits"] == 0 for p in report["parts"])
    prefix = os.path.join(out_dir, sheet["name"] + "_print")
    # gunsmith's pictures; its "parts" one pulls each part (all but the body) off by slot.
    gs.render(prefix, {"parts": [dict({"name": n, "slot": n}, **({} if n == "body" else {"mount": True}))
                                 for n in objects]}, objects, lo, hi)
    # And those parts from underneath, further apart: the stud holes the parts plug in by.
    for n, ob in objects.items():
        ob.location = Vector(ob.location) * 2.5
    under(prefix + "_holes.png", objects)

    # The whole gun as one solid, to print in one go: every part again, without the stud
    # holes between them (each stud fills where its hole would be), all unioned. After the
    # pictures, which are of the parts.
    for ob in objects.values():
        ob.hide_render = True
    whole = None
    rest = []
    for spec in parts:
        ob = build(spec, layout[spec["name"]], [], grid)
        if whole is None:
            whole = ob
            whole.name = sheet["name"] + "_whole"
        else:
            bm = bmesh.new()
            bm.from_mesh(ob.data)
            rest.append(bm)
            bpy.data.objects.remove(ob)
    if whole is not None:
        if rest:
            boolean(whole, rest, "UNION")
        info = inspect(whole)
        path = os.path.join(out_dir, sheet["name"] + "_whole.stl")
        export_stl(whole, path)
        info["stl"] = path
        info["loose_bits"] = sum(1 for b in info.get("piece_boxes_mm", [])
                                 if max(b[1][k] - b[0][k] for k in range(3)) < small)
        report["whole"] = info
        print("  %-12s %s, %d piece(s), %.1f x %.1f x %.1f mm%s" % (
            "WHOLE", "watertight" if info["watertight"] else "NOT WATERTIGHT", info["pieces"], *info["size_mm"],
            ("  (%d edge(s) where blocks touch only along a line)" % info["pinched_edges"]) if info["pinched_edges"] else ""))
        report["ok"] = report["ok"] and info["watertight"] and info["loose_bits"] == 0

    # Last: the workshop takes this file appearing as "done".
    with open(os.path.join(out_dir, sheet["name"] + ".print.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(report, f, indent=1)
    print("%s: %d parts and the whole, %.1f x %.1f x %.1f mm printed, %s" % (
        sheet["name"], len(report["parts"]), *report["print_mm"],
        "every one watertight, no loose bits" if report["ok"] else "SOME NOT CLEAN"))


# ------------------------------------------------------------------------------- layout

def lay_out(spec, grid):
    """A part's cells (key -> True; key = (stud along, half-studs across, plate up)), which
    bricks are plain or shaped, and its studs as [at, normal] in mm."""
    pitch, plate = grid["stud_pitch"], grid["plate"]
    cells = {}
    plain = []
    shaped = []
    turned = []
    for b in spec["bricks"]:
        if "turn" in b:
            # Built in a sideways grid: off this part's cells, laid as a solid of its own.
            turned.append(b)
            continue
        lo = b["min_mm"]
        sx, sy, sz = b["size"]
        base, _yaw, _flip = gs._orientation(b["part"])
        cat = gs._catalogue().get(base)
        is_shaped = cat is not None and cat.get("profiles")
        (shaped if is_shaped else plain).append(b)
        for i in range(sx):
            for j in range(sy):
                for k in range(sz):
                    cells[key_at(lo, i, j, k, grid)] = not is_shaped
    studs = []
    for b in plain:
        lo = b["min_mm"]
        sx, sy, sz = b["size"]
        top = round(lo[2] / plate) + sz
        for i in range(sx):
            for j in range(sy):
                above = key_at(lo, i, j, sz, grid)
                if above in cells:
                    continue
                studs.append([(lo[0] + (i + 0.5) * pitch, lo[1] + (j + 0.5) * pitch, top * plate), (0.0, 0.0, 1.0)])
    for b in shaped:
        base, yaw, flip = gs._orientation(b["part"])
        scratch = bmesh.new()
        for at, normal in gs._shaped(scratch, b, b["part"], base, yaw, flip, spec.get("mirror_along", False), grid):
            studs.append([tuple(at), tuple(normal)])
        scratch.free()
    for st in spec.get("studs_extra", []):
        n = Vector(st["normal"]).normalized()
        studs.append([tuple(st["at"]), tuple(n)])
    for b in turned:
        base, yaw, flip = gs._orientation(b["part"])
        cat = gs._catalogue().get(base)
        if cat is not None and cat.get("profiles"):
            scratch = bmesh.new()
            for at, normal in gs._shaped(scratch, b, b["part"], base, yaw, flip, False, grid):
                studs.append([tuple(at), tuple(normal)])
            scratch.free()
    return {"cells": cells, "plain": plain, "shaped": shaped, "turned": turned, "studs": studs}


def key_at(lo, i, j, k, grid):
    pitch, plate = grid["stud_pitch"], grid["plate"]
    return (round(lo[0] / pitch) + i, round(lo[1] / pitch * 2) + 2 * j, round(lo[2] / plate) + k)


def covers(cells, at, grid):
    """Is the cell just over this stud's foot one of these cells?"""
    pitch, plate = grid["stud_pitch"], grid["plate"]
    i = math.floor(at[0] / pitch + 1e-6)
    j2 = round((at[1] - pitch * 0.5) / pitch * 2)
    k = round(at[2] / plate)
    return (i, j2, k) in cells


# ------------------------------------------------------------------------------- building

def build(spec, me, holes, grid):
    pitch, plate = grid["stud_pitch"], grid["plate"]
    # The plain bricks: one shell, the outside faces of their cells.
    bm = bmesh.new()
    verts = {}

    def v(i, j2, k):
        key = (i, j2, k)
        if key not in verts:
            verts[key] = bm.verts.new((i * pitch, j2 * pitch * 0.5, k * plate))
        return verts[key]

    solid = {c for c, plain in me["cells"].items() if plain}
    shell = None
    if spec.get("shell"):
        # A shelled part (the asset workshop's smooth outside): its own closed surface.
        shell = bmesh.new()
        sv = [shell.verts.new(tuple(p)) for p in spec["shell"]["verts"]]
        t = spec["shell"]["tris"]
        for n in range(0, len(t) - 2, 3):
            try:
                shell.faces.new((sv[t[n]], sv[t[n + 1]], sv[t[n + 2]]))
            except ValueError:
                pass  # a face twice over: the surface is closed without it
        # Corners at one place are one vertex: the game mesh gives each corner its own
        # normal (hard edges), which would leave the solid open along every edge.
        bmesh.ops.remove_doubles(shell, verts=shell.verts, dist=1e-4)
        bmesh.ops.recalc_face_normals(shell, faces=shell.faces)
        # Grown, as a slope is but more: it ends on the next part's face (to within the
        # sampling), and a union of faces that only touch leaves them apart.
        shell.normal_update()
        for p in shell.verts:
            p.co += p.normal * SHELL_GROW
        if not solid:
            bm.free()
            bm = shell
            shell = None
    for (i, j, k) in solid:
        # Each face whose neighbour is not plain brick, wound to face out.
        if (i - 1, j, k) not in solid:
            bm.faces.new([v(i, j, k), v(i, j, k + 1), v(i, j + 2, k + 1), v(i, j + 2, k)])
        if (i + 1, j, k) not in solid:
            bm.faces.new([v(i + 1, j, k), v(i + 1, j + 2, k), v(i + 1, j + 2, k + 1), v(i + 1, j, k + 1)])
        if (i, j - 2, k) not in solid:
            bm.faces.new([v(i, j, k), v(i + 1, j, k), v(i + 1, j, k + 1), v(i, j, k + 1)])
        if (i, j + 2, k) not in solid:
            bm.faces.new([v(i, j + 2, k), v(i, j + 2, k + 1), v(i + 1, j + 2, k + 1), v(i + 1, j + 2, k)])
        if (i, j, k - 1) not in solid:
            bm.faces.new([v(i, j, k), v(i, j + 2, k), v(i + 1, j + 2, k), v(i + 1, j, k)])
        if (i, j, k + 1) not in solid:
            bm.faces.new([v(i, j, k + 1), v(i + 1, j, k + 1), v(i + 1, j + 2, k + 1), v(i, j + 2, k + 1)])
    ob = to_object(spec["name"], bm)

    # Everything that joins it: slopes and curves (welded, grown a hair), studs (sunk a hair).
    # Each its own object: pieces that overlap one another inside ONE operand are not
    # unioned (a stud on a slope came out loose that way).
    extra = [] if shell is None else [shell]
    for b in me["shaped"]:
        base, yaw, flip = gs._orientation(b["part"])
        one = bmesh.new()
        gs._shaped(one, b, b["part"], base, yaw, flip, spec.get("mirror_along", False), grid)
        bmesh.ops.remove_doubles(one, verts=one.verts, dist=1e-4)
        bmesh.ops.recalc_face_normals(one, faces=one.faces)
        centre = sum((p.co for p in one.verts), Vector()) / max(1, len(one.verts))
        for p in one.verts:
            d = p.co - centre
            p.co = centre + Vector((d.x + math.copysign(HAIR, d.x), d.y + math.copysign(HAIR, d.y),
                                    d.z + math.copysign(HAIR, d.z)))
        extra.append(one)
    for b in me.get("turned", []):
        # Sideways bricks: a turned box or a turned catalogue piece, grown a hair to weld.
        base, yaw, flip = gs._orientation(b["part"])
        cat = gs._catalogue().get(base)
        one = bmesh.new()
        if cat is not None and cat.get("profiles"):
            gs._shaped(one, b, b["part"], base, yaw, flip, False, grid)
            bmesh.ops.remove_doubles(one, verts=one.verts, dist=1e-4)
            bmesh.ops.recalc_face_normals(one, faces=one.faces)
            centre = sum((p.co for p in one.verts), Vector()) / max(1, len(one.verts))
            for p in one.verts:
                d = p.co - centre
                p.co = centre + d * (1.0 + HAIR / max(d.length, 1e-6))
        else:
            gs._turned_box(one, b, grid, grow=HAIR)
        extra.append(one)
    r, h = grid["stud_d"] * 0.5, grid["stud_h"]
    for at, normal in me["studs"]:
        n = Vector(normal)
        one = bmesh.new()
        gs._stud(one, Vector(at) - n * HAIR, n, r, h + HAIR)
        extra.append(one)
    if extra:
        boolean(ob, extra, "UNION")

    # The stud holes of the parts it sits on.
    if holes:
        cuts = []
        hr = grid["stud_d"] * 0.5 + grid["clearance_side"]
        # From well below the face (a grown slope's bottom is a hair below it: starting
        # there too made a coplanar face, and the cut came out as solid stubs).
        below = HAIR * 4
        depth = h + 0.15 + below
        for at in holes:
            cut = bmesh.new()
            bmesh.ops.create_cone(cut, cap_ends=True, segments=HOLE_SEGMENTS, radius1=hr, radius2=hr, depth=depth,
                                  matrix=Matrix.Translation(Vector(at) + Vector((0, 0, depth * 0.5 - below))))
            cuts.append(cut)
        boolean(ob, cuts, "DIFFERENCE")
    return ob


def to_object(name, bm, collection=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    (collection or bpy.context.scene.collection).objects.link(ob)
    return ob


def boolean(ob, pieces, op):
    """`ob` with each of `pieces` (bmeshes, each closed) unioned on or cut out, as one
    collection operand: the solver takes each piece as a solid of its own."""
    coll = bpy.data.collections.new(ob.name + "_" + op.lower())
    for n, bm in enumerate(pieces):
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        to_object("%s_%d" % (coll.name, n), bm, coll)
    mod = ob.modifiers.new(op.lower(), "BOOLEAN")
    mod.operation = op
    mod.operand_type = "COLLECTION"
    mod.collection = coll
    try:
        mod.solver = "MANIFOLD"
    except TypeError:
        mod.solver = "EXACT"
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)
    for o in list(coll.objects):
        bpy.data.objects.remove(o)
    bpy.data.collections.remove(coll)


def under(path, objects):
    """One picture of every part from below, framed to them where they now are."""
    sc = bpy.context.scene
    pts = [ob.matrix_world @ Vector(c) for ob in objects.values() for c in ob.bound_box]
    lo = Vector([min(p[k] for p in pts) for k in range(3)])
    hi = Vector([max(p[k] for p in pts) for k in range(3)])
    centre = (lo + hi) * 0.5
    cam = sc.camera
    d = Vector((0.25, 0.6, -1.0)).normalized()
    sc.render.resolution_x, sc.render.resolution_y = 2200, 1100
    cam.data.ortho_scale = max(hi.x - lo.x, (hi.z - lo.z) * 2.0) * 1.35
    cam.location = centre + d * 800.0
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("wrote", path)


# ------------------------------------------------------------------------------- checks

def inspect(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    watertight = all(e.is_manifold for e in bm.edges) and len(bm.edges) > 0
    # Pieces: connected groups of faces.
    seen = set()
    pieces = 0
    boxes = []
    for f in bm.faces:
        if f.index in seen:
            continue
        pieces += 1
        stack = [f]
        seen.add(f.index)
        lo = Vector(f.verts[0].co)
        hi = Vector(f.verts[0].co)
        while stack:
            g = stack.pop()
            for p in g.verts:
                lo = Vector(map(min, lo, p.co))
                hi = Vector(map(max, hi, p.co))
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        stack.append(h)
        boxes.append([[round(c, 1) for c in lo], [round(c, 1) for c in hi]])
    # Edges by where they are, not by vertex: two blocks that touch only along a line come
    # out as one edge with four faces once the file is read back (an STL has no vertices
    # of its own). Printable, but nothing holds there.
    by_place = {}
    for f in bm.faces:
        vs = [tuple(round(c, 4) for c in p.co) for p in f.verts]
        for a, b in zip(vs, vs[1:] + vs[:1]):
            k = (a, b) if a < b else (b, a)
            by_place[k] = by_place.get(k, 0) + 1
    pinched = [[list(k[0]), list(k[1])] for k, c in by_place.items() if c > 2]
    volume = bm.calc_volume(signed=False)
    lo = [min(p.co[k] for p in bm.verts) for k in range(3)] if bm.verts else [0, 0, 0]
    hi = [max(p.co[k] for p in bm.verts) for k in range(3)] if bm.verts else [0, 0, 0]
    bm.free()
    return {"watertight": watertight, "pieces": pieces, "piece_boxes_mm": boxes if pieces > 1 else [],
            "pinched_edges": len(pinched), "pinched_at_mm": pinched[:8],
            "volume_mm3": round(volume, 1),
            "size_mm": [round(hi[k] - lo[k], 2) for k in range(3)]}


def export_stl(ob, path):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.wm.stl_export(filepath=path, export_selected_objects=True, apply_modifiers=True)


if __name__ == "__main__":
    main()
