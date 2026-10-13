"""Turn a 3D model into bricks: stage 1 -- voxelise on a brick grid, pack into parts, preview.

    blender --background --factory-startup --python tools/brickify/brickify.py -- \
        <model.fbx|.glb|.gltf|.obj|.stl> <absolute out dir> [options]

    --class held|entity|world   which grid and scale (Docs/Parts/nano.md section 5); default held
    --print-length MM           the model's longest side when printed; default 116.6 (a 4.6 in gun)
    --studs up|side             which way the studs point: up (the model's +Z), or out of its
                                side (its -Y), so plates stack across its width; default up
    --name NAME                 output file stem; default the model's file name
    --no-render                 skip the preview pictures

Writes <name>.bricks.json (every part, by name and min cell, in the game's axes) and
<name>_side.png / <name>_iso.png (the model above, its bricks below).

The grids, the part list and the held scale are read from Docs/Parts/standards.json and
parts.json: nothing about a brick's size is written here.

Not yet (later stages): colours, slopes and curves, splitting by bone, joints and grips, a
BuildRecipe the game loads, STLs.
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
## Samples across a cell, each way, that decide whether it is solid.
SUB = 4
## A cell is solid when this share of its samples are inside the model.
FILL = 0.5
## Families packed in stage 1: the ones that are plain boxes.
BOX_FAMILIES = ("plate", "brick")
## Too big to be worth trying on an entity.
SKIP_PARTS = ("plate_10x10",)


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1:]
    model, out_dir = args[0], args[1]
    opt = {"class": "held", "print-length": "116.6", "name": "", "studs": "up"}
    flags = set()
    i = 2
    while i < len(args):
        key = args[i].lstrip("-")
        if key in opt:
            opt[key] = args[i + 1]
            i += 2
        else:
            flags.add(key)
            i += 1
    name = opt["name"] or os.path.splitext(os.path.basename(model))[0]
    std = json.load(open(os.path.join(PARTS_DIR, "standards.json"), encoding="utf-8"))
    cls = std["classes"][opt["class"]]
    grid = std["grids"][cls["grid"]]
    cell = np.array([grid["stud_pitch"], grid["stud_pitch"], grid["plate"]])
    print_len = float(opt["print-length"])

    tris = load_triangles(model)
    side = opt["studs"] == "side"
    if side:
        # Turn the model a quarter about X, so its side faces up: (x, y, z) -> (x, z, -y).
        tris = np.stack([tris[..., 0], tris[..., 2], -tris[..., 1]], axis=-1)
    lo, hi = tris.min(axis=(0, 1)), tris.max(axis=(0, 1))
    scale = print_len / float((hi - lo).max())
    tris = (tris - lo) * scale
    size = (hi - lo) * scale
    print("model %s: %d triangles, %.1f x %.1f x %.1f mm at print size (x%.3f)"
          % (name, len(tris), size[0], size[1], size[2], scale))

    fine, origin = sample(tris, size, cell)
    solid, phase = cells_from(fine)
    grid_origin = origin + (np.array(phase) * cell / SUB)
    print("grid %s: %d x %d studs, %d plates; %d solid cells; phase %s"
          % (cls["grid"], solid.shape[0], solid.shape[1], solid.shape[2], int(solid.sum()), phase))

    boxes = box_parts(grid["part_prefix"])
    # Bricks start on shared courses, or neighbouring columns never line up to be bridged.
    # Which plate the courses start on is free: take the one that packs best.
    placed = owner = loose = None
    for course in range(3):
        got, own = pack(solid, boxes, course)
        got, own = repair(solid, boxes, course, got, own)
        lo_parts = connectivity(got, own)
        if placed is None or (len(lo_parts), len(got)) < (len(loose), len(placed)):
            placed, owner, loose = got, own, lo_parts
    report(placed, loose, solid, fine, cell)

    os.makedirs(out_dir, exist_ok=True)
    held = std["scale"]["held_scale"] if cls["game_scale"] == "held_scale" else 1.0
    write_json(os.path.join(out_dir, name + ".bricks.json"), name, model, opt["class"], cls, grid,
               std, held, size, solid, placed, loose, opt["studs"])
    if "no-render" not in flags:
        render(os.path.join(out_dir, name), tris, grid_origin, cell, grid, placed, solid, loose, side)


# ---------------------------------------------------------------------------------- the model

def load_triangles(path: str) -> np.ndarray:
    """Every triangle of every mesh in the file, in world space: (n, 3, 3)."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    ext = os.path.splitext(path)[1].lower()
    if ext == ".fbx":
        bpy.ops.wm.fbx_import(filepath=path)
    elif ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    elif ext == ".stl":
        bpy.ops.wm.stl_import(filepath=path)
    else:
        raise SystemExit("cannot read %s" % ext)
    deps = bpy.context.evaluated_depsgraph_get()
    out = []
    for ob in bpy.context.scene.objects:
        if ob.type != "MESH":
            continue
        ev = ob.evaluated_get(deps)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        co = np.array([ev.matrix_world @ v.co for v in me.vertices])
        idx = np.array([t.vertices[:] for t in me.loop_triangles], dtype=int)
        if len(idx):
            out.append(co[idx])
        ev.to_mesh_clear()
    if not out:
        raise SystemExit("no meshes in %s" % path)
    return np.concatenate(out)


def sample(tris: np.ndarray, size: np.ndarray, cell: np.ndarray):
    """Inside/outside on a lattice SUB times finer than the brick grid.

    The model need not be watertight, and its shells may overlap (asset-pack models are
    rarely one clean solid): a sample's side is voted by three scan directions. Each walks a
    whole lattice line and counts the surfaces still ahead of a sample, facing away (+1) or
    toward it (-1): more than none left to leave through means it is inside. Counting faces
    by the way they point, not just how many, keeps the overlap of two shells solid.
    """
    step = cell / SUB
    pad = SUB  # a cell of margin, so any phase of the brick grid fits
    origin = -pad * step
    n = np.ceil(size / step).astype(int) + 2 * pad
    bvh = BVHTree.FromPolygons([Vector(v) for v in tris.reshape(-1, 3)],
                               [(3 * t, 3 * t + 1, 3 * t + 2) for t in range(len(tris))])
    # Sample centres, nudged off the lattice so a line never runs along an edge.
    nudge = step * np.array([0.0137, 0.0211, 0.0173])
    centre = [origin[a] + (np.arange(n[a]) + 0.5) * step[a] + nudge[a] for a in range(3)]
    votes = np.zeros(tuple(n), dtype=np.int8)
    for axis in range(3):
        u, v = [a for a in range(3) if a != axis]
        d = Vector((0.0, 0.0, 0.0))
        d[axis] = 1.0
        start = origin[axis] - 1.0
        for iu in range(n[u]):
            for iv in range(n[v]):
                o = Vector((0.0, 0.0, 0.0))
                o[axis], o[u], o[v] = start, centre[u][iu], centre[v][iv]
                crossings = []
                facing = []
                travelled = 0.0
                while len(crossings) < 400:
                    hit = bvh.ray_cast(o, d)
                    if hit[0] is None:
                        break
                    travelled += hit[3]
                    crossings.append(start + travelled)
                    facing.append(1 if hit[1][axis] > 0.0 else -1)
                    travelled += 1e-4
                    o = hit[0] + d * 1e-4
                if not crossings:
                    continue
                # ahead[i]: the sum of the facings from crossing i on.
                ahead = np.append(np.cumsum(np.array(facing)[::-1])[::-1], 0)
                inside = (ahead[np.searchsorted(np.array(crossings), centre[axis])] > 0).astype(np.int8)
                sl = [slice(None)] * 3
                sl[u], sl[v] = iu, iv
                votes[tuple(sl)] += inside
    return votes >= 2, origin


def cells_from(fine: np.ndarray):
    """Brick cells from the fine lattice, at the grid phase that leaves the fewest cells
    half full: a model 2.5 studs wide comes out 2 wide and whole, not 3 wide and ragged."""
    best = None
    for px in range(SUB):
        for py in range(SUB):
            for pz in range(SUB):
                f = fine[px:, py:, pz:]
                n = [s // SUB for s in f.shape]
                f = f[:n[0] * SUB, :n[1] * SUB, :n[2] * SUB]
                fill = f.reshape(n[0], SUB, n[1], SUB, n[2], SUB).mean(axis=(1, 3, 5))
                doubt = float(np.minimum(fill, 1.0 - fill).sum())
                if best is None or doubt < best[0] - 1e-9:
                    best = (doubt, fill >= FILL, (px, py, pz))
    return best[1], best[2]


# ---------------------------------------------------------------------------------- packing

def box_parts(prefix: str):
    """(name, studs along X, studs along Y, plates, long axis) for every box part, both ways
    round, biggest first. Blender axes: X and Y are studs, Z is plates."""
    parts = json.load(open(os.path.join(PARTS_DIR, "parts.json"), encoding="utf-8"))
    out = []
    for name, p in parts.items():
        if p["family"] not in BOX_FAMILIES or name in SKIP_PARTS:
            continue
        w, l = p["studs_wl"]
        out.append((prefix + name, l, w, p["plates"], "x" if l != w else ""))
        if l != w:
            out.append((prefix + name, w, l, p["plates"], "z"))
    out.sort(key=lambda b: -(b[1] * b[2] * b[3]))
    return out


def pack(solid: np.ndarray, boxes, course: int):
    """Lay parts bottom up, a layer at a time.

    Each open cell takes the part that scores best there: the most volume, plus a bonus for
    every part underneath it bridges, so seams do not line up. A part taller than a plate
    starts only on a course: every third plate from `course`.

    A part is held by studs only where there is a solid cell right under or right over it.
    One that has neither is loose however well it fits -- the rim of a shape that only one
    layer reaches -- so a part is made to reach from such a cell into cells that are held.
    Which way parts grow across a layer decides whether it can, so every layer is laid from
    each corner and both ways round, and the lay with the fewest unheld parts is kept.
    """
    nx, ny, nz = solid.shape
    owner = -np.ones(solid.shape, dtype=int)
    placed = []
    variants = [(fx, fy, swap) for swap in (False, True) for fx in (False, True) for fy in (False, True)]
    for z in range(nz):
        if not solid[:, :, z].any():
            continue
        best = None
        for v in range(len(variants)):
            # Start from a different corner each layer, so equal lays alternate.
            fx, fy, swap = variants[(v + z) % len(variants)]
            own = owner.copy()
            got = _lay(solid, own, boxes, course, z, len(placed), fx, fy, swap)
            unheld = sum(1 for g in got if not g["held"])
            key = (unheld, len(got), -sum(g["bridges"] for g in got))
            if best is None or key < best[0]:
                best = (key, own, got)
        owner = best[1]
        placed.extend(best[2])
    return placed, owner


def _lay(solid, owner, boxes, course, z, first_id, flip_x, flip_y, swap):
    """One layer: every open solid cell of plate `z`, scanned from one corner."""
    nx, ny, nz = solid.shape
    xs = range(nx - 1, -1, -1) if flip_x else range(nx)
    ys = range(ny - 1, -1, -1) if flip_y else range(ny)
    order = [(x, y) for y in ys for x in xs] if swap else [(x, y) for x in xs for y in ys]
    got = []
    for x, y in order:
        if not solid[x, y, z] or owner[x, y, z] >= 0:
            continue
        best = None
        for name, sx, sy, sz, turn in boxes:
            x0 = x - sx + 1 if flip_x else x
            y0 = y - sy + 1 if flip_y else y
            if x0 < 0 or y0 < 0 or x0 + sx > nx or y0 + sy > ny or z + sz > nz:
                continue
            if sz > 1 and (z - course) % 3 != 0:
                continue
            foot = (slice(x0, x0 + sx), slice(y0, y0 + sy))
            block = foot + (slice(z, z + sz),)
            if not solid[block].all() or (owner[block] >= 0).any():
                continue
            under = set()
            held = False
            if z > 0:
                under = set(owner[foot + (z - 1,)].ravel().tolist()) - {-1}
                held = bool(solid[foot + (z - 1,)].any())
            if not held and z + sz < nz:
                held = bool(solid[foot + (z + sz,)].any())
            score = sx * sy * sz * (1.25 if sz > 1 else 1.0) + 2.0 * len(under) + (0.0 if held else -1000.0)
            if best is None or score > best[0]:
                best = (score, name, x0, y0, sx, sy, sz, turn, held, len(under))
        _, name, x0, y0, sx, sy, sz, turn, held, bridges = best
        owner[x0:x0 + sx, y0:y0 + sy, z:z + sz] = first_id + len(got)
        got.append({"part": name, "turn": turn, "min": (x0, y0, z), "size": (sx, sy, sz),
                    "held": held, "bridges": bridges})
    return got


def repair(solid, boxes, course, placed, owner, rounds: int = 6):
    """Give loose parts another chance to be held.

    A brick laid on a lower layer has already taken the cells beside a rim that turns up two
    plates later, so the rim's own part has nothing to reach into. Take up each loose part
    and the parts beside it in its layers, and lay those cells again in plates only, which
    can reach from the rim into what the brick held. Kept only if fewer parts end up loose.
    """
    plates = [b for b in boxes if b[3] == 1]
    for _ in range(rounds):
        loose = connectivity(placed, owner)
        if not loose:
            break
        nx, ny, nz = solid.shape
        take = set(loose)
        for i in loose:
            x0, y0, z0 = placed[i]["min"]
            sx, sy, sz = placed[i]["size"]
            near = owner[max(x0 - 1, 0):min(x0 + sx + 1, nx), max(y0 - 1, 0):min(y0 + sy + 1, ny),
                         z0:z0 + sz]
            take |= set(near.ravel().tolist()) - {-1}
        trial_owner = owner.copy()
        trial = [None if i in take else p for i, p in enumerate(placed)]
        layers = set()
        for i in take:
            x0, y0, z0 = placed[i]["min"]
            sx, sy, sz = placed[i]["size"]
            trial_owner[x0:x0 + sx, y0:y0 + sy, z0:z0 + sz] = -1
            layers |= set(range(z0, z0 + sz))
        for z in sorted(layers):
            best = None
            for fx, fy, swap in [(a, b, c) for c in (False, True) for a in (False, True) for b in (False, True)]:
                own = trial_owner.copy()
                got = _lay(solid, own, plates, course, z, len(trial), fx, fy, swap)
                key = (sum(1 for g in got if not g["held"]), len(got))
                if best is None or key < best[0]:
                    best = (key, own, got)
            trial_owner = best[1]
            trial.extend(best[2])
        # Close the gaps the taken-up parts left in the numbering.
        remap = {}
        packed = []
        for i, part in enumerate(trial):
            if part is not None:
                remap[i] = len(packed)
                packed.append(part)
        lut = np.full(len(trial) + 1, -1, dtype=int)
        for old, new in remap.items():
            lut[old] = new
        trial_owner = lut[trial_owner]
        if len(connectivity(packed, trial_owner)) >= len(loose):
            break
        placed, owner = packed, trial_owner
    return placed, owner


def connectivity(placed, owner) -> list:
    """Indices of parts no stud joins to the biggest group."""
    parent = list(range(len(placed)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    nz = owner.shape[2]
    for i, p in enumerate(placed):
        x0, y0, z0 = p["min"]
        sx, sy, sz = p["size"]
        top = z0 + sz
        if top >= nz:
            continue
        for j in set(owner[x0:x0 + sx, y0:y0 + sy, top].ravel().tolist()) - {-1}:
            parent[find(i)] = find(j)
    groups = {}
    for i, p in enumerate(placed):
        groups.setdefault(find(i), []).append(i)
    if not groups:
        return []
    main_group = max(groups.values(), key=lambda g: sum(np.prod(placed[i]["size"]) for i in g))
    keep = set(main_group)
    return [i for i in range(len(placed)) if i not in keep]


def report(placed, loose, solid, fine, cell) -> None:
    counts = {}
    for p in placed:
        counts[p["part"]] = counts.get(p["part"], 0) + 1
    print("parts: %d" % len(placed))
    for name in sorted(counts, key=lambda k: -counts[k]):
        print("  %4d  %s" % (counts[name], name))
    model_mm3 = float(fine.sum()) * float(np.prod(cell / SUB))
    brick_mm3 = float(solid.sum()) * float(np.prod(cell))
    print("volume: model %.0f mm3, bricks %.0f mm3 (%.0f%%)"
          % (model_mm3, brick_mm3, 100.0 * brick_mm3 / max(model_mm3, 1e-9)))
    print("not joined to the main group by a stud: %d parts" % len(loose))


def write_json(path, name, model, cls_name, cls, grid, std, held, size, solid, placed, loose,
               studs) -> None:
    """Parts in the build's own axes, the game's (Docs/Parts/README.md section 4): x studs,
    y plates up the studs, z studs, with Blender (x, y, z) -> (x, z, -y). With studs "side"
    the build lies on its side: it is one sideways frame (Docs/BuildMode.md section 2)."""
    ny = solid.shape[1]
    k = std["scale"]["game_m_per_mm"] * held
    parts = []
    for i, p in enumerate(placed):
        x0, y0, z0 = p["min"]
        sx, sy, sz = p["size"]
        parts.append({"part": p["part"], "turn": p["turn"],
                      "cell": [int(x0), int(z0), int(ny - (y0 + sy))],
                      "size": [int(sx), int(sz), int(sy)],
                      "loose": i in set(loose)})
    doc = {
        "name": name, "source": model, "class": cls_name, "grid": cls["grid"],
        "process": cls["process"], "studs": studs,
        "cell_mm": [grid["stud_pitch"], grid["plate"], grid["stud_pitch"]],
        "cells": [int(solid.shape[0]), int(solid.shape[2]), int(solid.shape[1])],
        "print_mm": [round(float(size[0]), 2), round(float(size[2]), 2), round(float(size[1]), 2)],
        "held_scale": held,
        "game_m": [round(float(size[0]) * k, 4), round(float(size[2]) * k, 4), round(float(size[1]) * k, 4)],
        "axes": "x studs, y plates (up), z studs; cell is the part's min corner; size is studs, plates, studs",
        "part_count": len(parts), "loose_count": len(loose), "parts": parts,
    }
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)
    print("wrote", path)


# ---------------------------------------------------------------------------------- preview

def render(prefix, tris, grid_origin, cell, grid, placed, solid, loose, side) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene

    # The bricks, with a hair of gap so the seams show, and studs on every open top.
    bm = bmesh.new()
    gap = cell[0] * 0.015
    r, h = grid["stud_d"] * 0.5, grid["stud_h"]
    nz = solid.shape[2]
    bm_loose = bmesh.new()
    for i, p in enumerate(placed):
        target = bm_loose if i in set(loose) else bm
        mn = grid_origin + np.array(p["min"]) * cell
        sz = np.array(p["size"]) * cell
        centre = mn + sz * 0.5
        mat = Matrix.Translation(Vector(centre)) @ Matrix.Diagonal(
            Vector((sz[0] - 2 * gap, sz[1] - 2 * gap, sz[2] - gap * 0.5, 1.0)))
        bmesh.ops.create_cube(target, size=1.0, matrix=mat)
        x0, y0, z0 = p["min"]
        top = z0 + p["size"][2]
        for x in range(x0, x0 + p["size"][0]):
            for y in range(y0, y0 + p["size"][1]):
                if top < nz and solid[x, y, top]:
                    continue
                at = grid_origin + (np.array([x + 0.5, y + 0.5, top])) * cell
                bmesh.ops.create_cone(
                    target, cap_ends=True, segments=8, radius1=r, radius2=r * 0.86, depth=h,
                    matrix=Matrix.Translation(Vector((at[0], at[1], at[2] + h * 0.5)))
                    @ Matrix.Rotation(math.radians(22.5), 4, "Z"))
    bricks = _object(sc, "bricks", bm, (0.33, 0.36, 0.40, 1.0))
    if loose:
        _object(sc, "loose", bm_loose, (0.85, 0.2, 0.15, 1.0))

    # The model, the same size, above them.
    me = bpy.data.meshes.new("model")
    me.from_pydata([tuple(v) for v in tris.reshape(-1, 3)], [],
                   [(3 * t, 3 * t + 1, 3 * t + 2) for t in range(len(tris))])
    src = bpy.data.objects.new("model", me)
    src.color = (0.75, 0.72, 0.66, 1.0)
    sc.collection.objects.link(src)
    extent = tris.max(axis=(0, 1))
    if side:
        # Stand it back up for the picture: (x, y, z) -> (x, -z, y).
        up = Matrix(((1, 0, 0, 0), (0, 0, -1, extent[2]), (0, 1, 0, 0), (0, 0, 0, 1)))
        for ob in sc.objects:
            ob.matrix_world = up
        extent = np.array([extent[0], extent[2], extent[1]])
    lift = extent[2] + grid["plate"] * 6
    src.matrix_world = Matrix.Translation(Vector((0.0, 0.0, lift))) @ src.matrix_world

    sc.render.engine = "BLENDER_WORKBENCH"
    sh = sc.display.shading
    sh.light, sh.color_type = "STUDIO", "OBJECT"
    sh.show_cavity = sh.show_object_outline = True
    sh.show_shadows = False
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.9, 0.9, 0.9)
    sc.render.film_transparent = False
    sc.render.resolution_x, sc.render.resolution_y = 1800, 1350
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    sc.collection.objects.link(cam)
    sc.camera = cam
    centre = Vector((extent[0] * 0.5, extent[1] * 0.5, (extent[2] + lift) * 0.5))
    tall = extent[2] + lift
    for tag, d, fit in (("side", Vector((0.0, -1.0, 0.0)), max(extent[0], tall * 1.34)),
                        ("iso", Vector((-0.55, -1.0, 0.5)), max(extent[0], tall * 1.34) * 1.05)):
        d.normalize()
        cam.data.ortho_scale = fit * 1.08
        cam.location = centre + d * (extent.max() * 6.0)
        cam.data.clip_end = extent.max() * 20.0
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = "%s_%s.png" % (prefix, tag)
        bpy.ops.render.render(write_still=True)
        print("wrote", sc.render.filepath)


def _object(sc, name, bm, colour):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.color = colour
    sc.collection.objects.link(ob)
    return ob


if __name__ == "__main__":
    main()
