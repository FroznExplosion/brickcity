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
##
## Drawn with the in-game UI kit (GameUI, ui/): its text follows the player's text
## scale and high contrast, its plates and colours are the HUD's shared ones.

## The key help at the bottom fades after this long.
const HINT_SECONDS := 10.0
const HINT := "WASD move · SHIFT sprint · SPACE jump / climb · C slide · Q grapple · RMB aim · LMB fire · E melee · V leave"
const HINT_2 := "R reload (hold: pick up / alt-fire) · TAB swap (hold: other group) · 1-4 guns · 5 ordnance · G grenade · I backpack / skills"

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
		var col := Color(GameUI.hud_text, 0.9 * a)
		var back := Color(GameUI.hud_back, 0.55 * a)
		if hud.gun.ammo <= 0 and not hud.gun.is_reloading():
			col = Color(GameUI.hud_warn, 0.95 * a)
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
		var ammo_col := Color(GameUI.hud_warn, 1.0) if low else Color(1, 1, 1)
		var big := str(g.ammo)
		var small := " / %d" % mag
		var small_w := GameUI.text_width(small, 22)
		_text(font, small, Vector2(right - small_w, base), 22, GameUI.hud_dim)
		_text(font, big, Vector2(right - small_w - GameUI.text_width(big, 44), base), 44, ammo_col)
		_text(font, g.gun.gun_name, Vector2(right, base - 48.0), 16, Rarity.colour(g.gun.rarity), false, true)
		if g.ammo <= 0 and not g.is_reloading():
			_text(font, "R  RELOAD", Vector2(right, base + 22.0), 16, Color(1.0, 0.45, 0.35), false, true)

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
			GameUI.draw_bar(self, Rect2(x, y, w, 12), f, col)
			y -= 20.0
		_text(font, "%d" % roundi(h.total_current()), Vector2(x + w + 12.0, size.y - 30.0),
				20, GameUI.hud_text)

	## The grapple: a bar above the health filling as it recharges, and a mark on
	## the hook while the line holds.
	func _grapple(font: Font) -> void:
		var mv := hud.pawn.moves
		if mv == null:
			return
		# Another ability in the slot (PlayerLevel.ability): PlayerArsenal draws that one here.
		var pl := hud.pawn.get_meta(PlayerLevel.SOURCE_META) as PlayerLevel \
				if hud.pawn.has_meta(PlayerLevel.SOURCE_META) else null
		if pl != null and pl.ability() != &"grapple":
			return
		var x := 32.0
		var bars := hud.pawn.health.layer_count() if hud.pawn.health != null else 0
		var y := size.y - 44.0 - 20.0 * bars - 6.0
		var cd := mv.grapple_cooldown()
		var col := GameUI.hud_ready if cd <= 0.0 else Color(0.6, 0.6, 0.6, 0.7)
		GameUI.draw_bar(self, Rect2(x, y, 100, 6), 1.0 - cd, col)
		_text(font, "Q GRAPPLE", Vector2(x + 112.0, y + 8.0), 13, col)
		if mv.is_grappling():
			var cam := get_viewport().get_camera_3d()
			if cam != null and not cam.is_position_behind(mv.hook):
				var p := cam.unproject_position(mv.hook)
				draw_circle(p, 4.0, GameUI.hud_ready)

	func _reload(font: Font, c: Vector2) -> void:
		var g := hud.gun
		if g == null or not g.is_reloading():
			return
		var w := 120.0
		var y := c.y + 48.0
		GameUI.draw_bar(self, Rect2(c.x - w * 0.5, y, w, 4), g.reload_progress(), GameUI.hud_text)
		_text(font, "RELOADING", Vector2(c.x, y + 22.0), 13, Color(1, 1, 1, 0.8), true)

	## `px` is the designed size; GameUI scales it by the player's text scale.
	func _text(_font: Font, s: String, at: Vector2, px: int, col: Color, centred := false, right := false) -> void:
		GameUI.draw_text(self, s, at, px, col, HORIZONTAL_ALIGNMENT_CENTER if centred
				else (HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT))
