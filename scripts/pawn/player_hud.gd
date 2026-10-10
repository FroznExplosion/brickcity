class_name PlayerHud
extends CanvasLayer
## What an FPS shows the player, and nothing a debug build shows: a crosshair that
## opens with the gun's real cone, the gun and its rounds, health, the grapple's
## cooldown, a reload bar, a scope. On foot the city's stats and its blast
## reticle are put away (F1 still shows the stats); this replaces them.
##
## Hitmarkers, damage numbers and the hurt edge are CombatFeedback's, drawn over
## the same crosshair centre -- not repeated here.
##
## Reads; never writes. Everything it shows is polled from the pawn, its moves,
## the gun and the view each frame.

## Rarity tiers 1..6 in the usual loot colours.
const RARITY_COLOURS: Array[Color] = [
	Color(0.92, 0.92, 0.92), Color(0.35, 0.9, 0.35), Color(0.3, 0.6, 1.0),
	Color(0.72, 0.4, 1.0), Color(1.0, 0.6, 0.15), Color(0.95, 0.12, 0.12),
]
## The key help at the bottom fades after this long.
const HINT_SECONDS := 10.0
const HINT := "WASD move · SHIFT sprint · SPACE jump / climb · C slide · Q grapple · RMB aim · LMB fire · E melee · V leave"
const HINT_2 := "R reload (hold: pick up) · TAB swap (hold: other group) · 1-4 guns · 5 ordnance · G grenade · I backpack"

## How solid the HUD is drawn (the Options menu's HUD Opacity).
static var opacity := 1.0

var pawn: Pawn
var gun: GunController
var view: PlayerView
var _hud: Overlay
var _age := 0.0


func setup(p: Pawn, g: GunController, v: PlayerView) -> void:
	pawn = p
	gun = g
	view = v
	layer = 4
	_hud = Overlay.new()
	_hud.hud = self
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud)


func _process(delta: float) -> void:
	_age += delta
	if _hud != null:
		_hud.modulate.a = opacity
		_hud.queue_redraw()


## The crosshair's gap, in pixels: the cone's half-angle at the camera's FOV.
func spread_px() -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null or gun == null:
		return 6.0
	var half_h := float(get_viewport().get_visible_rect().size.y) * 0.5
	var cone := deg_to_rad(gun.current_spread_deg())
	return tan(cone) / tan(deg_to_rad(cam.fov) * 0.5) * half_h


class Overlay extends Control:
	var hud: PlayerHud

	func _draw() -> void:
		if hud.pawn == null or not is_instance_valid(hud.pawn):
			return
		var font := ThemeDB.fallback_font
		var c := size * 0.5
		var v := hud.view
		if v != null and v.is_scoped():
			_scope(c)
		else:
			_crosshair(c)
		_gun_panel(font)
		_health(font)
		_grapple(font)
		_reload(font, c)
		if hud._age < HINT_SECONDS:
			var a := clampf((HINT_SECONDS - hud._age) / 2.0, 0.0, 1.0)
			_text(font, HINT, Vector2(c.x, 34.0), 15, Color(1, 1, 1, 0.8 * a), true)
			_text(font, HINT_2, Vector2(c.x, 54.0), 15, Color(1, 1, 1, 0.8 * a), true)

	## Four ticks round a gap as wide as the cone, dimmed while the gun is down
	## for a sprint, and a dot at the sights.
	func _crosshair(c: Vector2) -> void:
		var v := hud.view
		var ads := v.ads_amount() if v != null else 0.0
		var down := v.sprint_amount() if v != null else 0.0
		var a := (1.0 - down * 0.85) * (1.0 - ads * 0.6)
		var gap := clampf(hud.spread_px(), 3.0, size.y * 0.3) + 3.0
		var tick := 7.0
		var col := Color(1, 1, 1, 0.9 * a)
		var back := Color(0, 0, 0, 0.55 * a)
		if hud.gun.ammo <= 0 and not hud.gun.is_reloading():
			col = Color(1.0, 0.35, 0.3, 0.95 * a)
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
			var n: Vector2 = d
			draw_line(c + n * (gap - 1.0), c + n * (gap + tick + 1.0), back, 4.0)
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
			var n: Vector2 = d
			draw_line(c + n * gap, c + n * (gap + tick), col, 2.0)
		draw_circle(c, 2.2, back)
		draw_circle(c, 1.4, col)

	## A black ring round a clear circle, and a fine cross through it.
	func _scope(c: Vector2) -> void:
		var r := size.y * 0.46
		var black := Color(0, 0, 0, 1)
		draw_rect(Rect2(0, 0, c.x - r, size.y), black)
		draw_rect(Rect2(c.x + r, 0, size.x - c.x - r, size.y), black)
		draw_arc(c, r + size.y * 0.3, 0.0, TAU, 96, black, size.y * 0.6)
		draw_arc(c, r, 0.0, TAU, 96, Color(0, 0, 0, 0.9), 3.0, true)
		var fine := Color(0, 0, 0, 0.85)
		draw_line(Vector2(c.x - r, c.y), Vector2(c.x + r, c.y), fine, 1.5)
		draw_line(Vector2(c.x, c.y - r), Vector2(c.x, c.y + r), fine, 1.5)
		draw_line(Vector2(c.x - r, c.y), Vector2(c.x - r * 0.3, c.y), fine, 4.0)
		draw_line(Vector2(c.x + r * 0.3, c.y), Vector2(c.x + r, c.y), fine, 4.0)
		draw_line(Vector2(c.x, c.y + r * 0.3), Vector2(c.x, c.y + r), fine, 4.0)

	## Bottom right: rounds in the magazine, the magazine, the gun's name in its
	## rarity's colour.
	func _gun_panel(font: Font) -> void:
		var g := hud.gun
		if g == null or g.gun == null:
			return
		var right := size.x - 32.0
		var base := size.y - 40.0
		var mag := g.mag_size()
		var low := g.ammo <= maxi(1, int(mag * 0.25))
		var ammo_col := Color(1.0, 0.35, 0.3) if low else Color(1, 1, 1)
		var big := str(g.ammo)
		var small := " / %d" % mag
		var small_w := font.get_string_size(small, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		var big_w := font.get_string_size(big, HORIZONTAL_ALIGNMENT_LEFT, -1, 44).x
		_text(font, small, Vector2(right - small_w, base), 22, Color(1, 1, 1, 0.7))
		_text(font, big, Vector2(right - small_w - big_w, base), 44, ammo_col)
		var rc := RARITY_COLOURS[clampi(g.gun.rarity - 1, 0, RARITY_COLOURS.size() - 1)]
		var nm := g.gun.gun_name
		var nw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_text(font, nm, Vector2(right - nw, base - 48.0), 16, rc)
		if g.ammo <= 0 and not g.is_reloading():
			var t := "R  RELOAD"
			var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			_text(font, t, Vector2(right - tw, base + 22.0), 16, Color(1.0, 0.45, 0.35))

	## Bottom left: a bar per defence layer, the vital one lowest, the total by
	## it; the grapple's recharge above them.
	func _health(font: Font) -> void:
		var h := hud.pawn.health
		if h == null:
			return
		var x := 32.0
		var y := size.y - 44.0
		var w := 260.0
		for i in range(h.layer_count() - 1, -1, -1):
			var f := clampf(h.get_layer_fraction(i), 0.0, 1.0)
			var col: Color = h.layer_configs[i].display_color
			if h.layer_type_at(i) == &"health" or col == Color.WHITE:
				col = Color(0.95, 0.3, 0.25) if f < 0.3 else Color(0.9, 0.92, 0.9)
			draw_rect(Rect2(x - 2, y - 2, w + 4, 16), Color(0, 0, 0, 0.55))
			draw_rect(Rect2(x, y, w * f, 12), col)
			y -= 20.0
		_text(font, "%d" % roundi(h.total_current()), Vector2(x + w + 12.0, size.y - 30.0),
				20, Color(1, 1, 1, 0.9))

	## The grapple: a bar above the health filling as it recharges, and a mark on
	## the hook while the line holds.
	func _grapple(font: Font) -> void:
		var mv := hud.pawn.moves
		if mv == null:
			return
		var x := 32.0
		var bars := hud.pawn.health.layer_count() if hud.pawn.health != null else 0
		var y := size.y - 44.0 - 20.0 * bars - 6.0
		var cd := mv.grapple_cooldown()
		var col := Color(0.4, 0.85, 1.0, 0.9) if cd <= 0.0 else Color(0.6, 0.6, 0.6, 0.7)
		draw_rect(Rect2(x - 2, y - 2, 104, 10), Color(0, 0, 0, 0.55))
		draw_rect(Rect2(x, y, 100.0 * (1.0 - cd), 6), col)
		_text(font, "Q GRAPPLE", Vector2(x + 112.0, y + 8.0), 13, col)
		if mv.is_grappling():
			var cam := get_viewport().get_camera_3d()
			if cam != null and not cam.is_position_behind(mv.hook):
				var p := cam.unproject_position(mv.hook)
				draw_circle(p, 4.0, Color(0.4, 0.85, 1.0, 0.9))

	func _reload(font: Font, c: Vector2) -> void:
		var g := hud.gun
		if g == null or not g.is_reloading():
			return
		var w := 120.0
		var y := c.y + 48.0
		draw_rect(Rect2(c.x - w * 0.5 - 2, y - 2, w + 4, 8), Color(0, 0, 0, 0.55))
		draw_rect(Rect2(c.x - w * 0.5, y, w * g.reload_progress(), 4), Color(1, 1, 1, 0.9))
		_text(font, "RELOADING", Vector2(c.x, y + 22.0), 13, Color(1, 1, 1, 0.8), true)

	func _text(font: Font, s: String, at: Vector2, px: int, col: Color, centred := false) -> void:
		var p := at
		if centred:
			p.x -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x * 0.5
		draw_string_outline(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, 4, Color(0, 0, 0, col.a * 0.8))
		draw_string(font, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, col)
