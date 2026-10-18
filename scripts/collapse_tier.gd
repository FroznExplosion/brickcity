class_name CollapseTier
extends RefCounted

## Collapse in three tiers (Docs/Structures.md 2.5): how a building coming
## apart is worked out, by how far it is from the nearest player.
##
##   HOT    nearer than HOT_RANGE: real bricks. Every group the solve lets go
##          is a piece of its own, a landing breaks what lands
##          (IslandManager.FRACTURE_RANGE), small pieces and crumbs fall, a
##          mega building comes down in chunks of CollapseDirector.CHUNK_NEAR.
##   REST   to FAR_RANGE: the same groups, but a landing breaks nothing, a
##          small piece is deleted where it comes loose (SMALL_KEEP_RANGE) and
##          a mega building comes down in chunks of CHUNK_MID.
##   FAR    past FAR_RANGE: any building comes down in a few big chunks
##          (CollapseDirector.CHUNKS_FAR), its furniture written off, and what
##          has settled is put to sleep (IslandManager.SLEEP_RANGE).
##
## These two numbers are what every one of those rules reads, so the tiers
## move together. Measured 2026-10-18 (collapse_probe "far", a 5-storey tower
## undercut): 3-14 pieces watched from 30 m (it varies run to run), 2-3 from
## 100 m, 1 from 260 m.

enum { HOT, REST, FAR }

const HOT_RANGE := 60.0
const FAR_RANGE := 150.0

const NAMES := ["hot", "rest", "far"]


## The tier of something this far from the nearest player. INF -- nobody at
## all -- is FAR.
static func of_distance(d: float) -> int:
	if d < HOT_RANGE:
		return HOT
	if d < FAR_RANGE:
		return REST
	return FAR


## The tier of a world box, from where the players are. With no players at
## all it is HOT: a headless check or a server with nobody on it decides as if
## somebody were watching, which is how the rules behaved before tiers.
static func of_box(box: AABB, points: PackedVector3Array) -> int:
	if points.is_empty():
		return HOT
	var d := INF
	for p in points:
		var q := Vector3(clampf(p.x, box.position.x, box.end.x),
				clampf(p.y, box.position.y, box.end.y),
				clampf(p.z, box.position.z, box.end.z))
		d = minf(d, q.distance_to(p))
	return of_distance(d)
