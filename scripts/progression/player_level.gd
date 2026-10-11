class_name PlayerLevel
extends RefCounted
## A player's level, XP and skill tree (Docs/Weapons/COMBAT_DESIGN.md 1.3,
## PROGRESSION_SPEC 2): levels 1-100 from XP, a skill point a level, spent in the
## SkillTree. Nothing grows with the level by itself: what the points bought is all of it.
##
## XP comes from kills: `credit_kill`, called by DamageSystem for any hit that kills,
## finds whose it was through its packet's source -- a node the player owns carries
## this under the meta SOURCE_META (the player's pawn for a melee or a grenade, the
## player's GunController, their mech's gun). A target pays out once.
##
## The numbers are placeholders: XP_BASE / XP_POWER for the curve, a kill's worth from
## the health it had (a light enemy at tier 1, 64 health: 20 XP). They grow together
## with the tier, as health does, so a level costs about as many kills all the way up.

signal changed
signal leveled_up(level: int)

const LEVEL_MAX := 100
const XP_BASE := 60.0
const XP_POWER := 1.2
## A kill's XP a point of its whole health, and the most one kill pays.
const XP_PER_HEALTH := 0.3125
const KILL_XP_MAX := 600
## A kill with no HealthPool -- a mech, a tank.
const MACHINE_XP := 300
const SOURCE_META := &"player_level"
const PAID_META := &"xp_paid"

var level := 1
## XP into this level.
var xp := 0
var tree := SkillTree.new()
## The side the player is on: a kill of their own side pays nothing.
var team := 0
## Scrap, the infusion material (Infusion): from kills and guns broken down.
var scrap := 0
## The highest tier of fight the player has reached: what a gun can be infused to.
var story_tier := 1


## XP from `l` to the next level; 0 at the top.
static func xp_to_next(l: int) -> int:
	if l >= LEVEL_MAX:
		return 0
	return roundi(XP_BASE * pow(float(l), XP_POWER))


## XP from level 1 to the start of level `l`.
static func xp_to_reach(l: int) -> int:
	var t := 0
	for i in range(1, clampi(l, 1, LEVEL_MAX)):
		t += xp_to_next(i)
	return t


func points_total() -> int:
	return level - 1


func points_free() -> int:
	return points_total() - tree.spent()


## Add XP; levels up as far as it reaches. Returns the levels gained.
func add_xp(amount: int) -> int:
	if amount <= 0 or level >= LEVEL_MAX:
		return 0
	xp += amount
	var gained := 0
	while level < LEVEL_MAX and xp >= xp_to_next(level):
		xp -= xp_to_next(level)
		level += 1
		gained += 1
	if level >= LEVEL_MAX:
		xp = 0
	if gained > 0:
		leveled_up.emit(level)
	changed.emit()
	return gained


## Straight to the start of level `l` (a debug key, a probe).
func set_level(l: int) -> void:
	level = clampi(l, 1, LEVEL_MAX)
	xp = 0
	if tree.spent() > points_total():
		tree.reset()
	changed.emit()


## One point into node `id`.
func buy(id: StringName) -> bool:
	if not tree.buy(id, points_free()):
		return false
	changed.emit()
	return true


## A fight of `tier` reached: the story tier rises to it, never falls.
func reach_tier(tier: int) -> void:
	if tier > story_tier:
		story_tier = tier
		changed.emit()


## Scrap spent, if there is enough.
func spend_scrap(n: int) -> bool:
	if n < 0 or scrap < n:
		return false
	scrap -= n
	changed.emit()
	return true


func add_scrap(n: int) -> void:
	scrap += maxi(n, 0)
	changed.emit()


## Every point back, to spend again.
func reset_tree() -> void:
	tree.reset()
	changed.emit()


## What a kill of `target` is worth.
static func kill_xp(target: Node) -> int:
	var pool := DamageSystem._find_health_pool(target)
	if pool == null:
		return MACHINE_XP
	var hp := 0.0
	for c in pool.layer_configs:
		hp += c.max_value
	return clampi(roundi(hp * XP_PER_HEALTH), 1, KILL_XP_MAX)


## A hit from `source` killed `target`: the XP to the player whose it was, once.
static func credit_kill(source: Object, target: Node) -> void:
	if source == null or target == null or not is_instance_valid(source) \
			or not is_instance_valid(target) or target.has_meta(PAID_META):
		return
	if not source.has_meta(SOURCE_META):
		return
	var who := source.get_meta(SOURCE_META) as PlayerLevel
	if who == null:
		return
	var pawn := target.get_node_or_null(^"Pawn") as Pawn
	if pawn != null and pawn.team == who.team:
		return
	target.set_meta(PAID_META, true)
	var xp_got := kill_xp(target)
	who.scrap += roundi(xp_got * Infusion.SCRAP_PER_XP)
	who.add_xp(xp_got)


func to_dict() -> Dictionary:
	return {"level": level, "xp": xp, "skills": tree.to_dict(), "scrap": scrap,
			"story_tier": story_tier}


## Become the saved `d` (this object stays: the nodes that carry it keep it).
func take(d: Dictionary) -> void:
	var p := from_dict(d)
	level = p.level
	xp = p.xp
	tree = p.tree
	scrap = p.scrap
	story_tier = p.story_tier
	changed.emit()


static func from_dict(d: Dictionary) -> PlayerLevel:
	var p := PlayerLevel.new()
	p.level = clampi(int(d.get("level", 1)), 1, LEVEL_MAX)
	p.xp = clampi(int(d.get("xp", 0)), 0, maxi(xp_to_next(p.level) - 1, 0))
	p.tree = SkillTree.from_dict(d.get("skills", {}) as Dictionary, p.points_total())
	p.scrap = maxi(int(d.get("scrap", 0)), 0)
	p.story_tier = clampi(int(d.get("story_tier", 1)), 1, Tier.COUNT)
	return p
