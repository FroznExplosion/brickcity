class_name PartThumbnail
extends RefCounted
## A part's picture for its catalogue card (Docs/ModularParts.md section 7: the package carries
## it as thumb.png). Drawn in a viewport of its own: the part from three quarters above, framed
## to fit, on a clear background. It needs a window to draw in: headless there is none, and
## `render` gives null.
##
##     var img: Image = await PartThumbnail.render(scene, self)
##     if img: img.save_png(dir + "thumb.png")

const SIZE := 256
const FILE := "thumb.png"


static func can_render() -> bool:
	return DisplayServer.get_name() != "headless"


## The picture of `scene` (a part's PackedScene), drawn under `host` (any node in the tree),
## or null with no window to draw in.
static func render(scene: PackedScene, host: Node, size: int = SIZE) -> Image:
	if scene == null or host == null or not host.is_inside_tree() or not can_render():
		return null
	var vp := SubViewport.new()
	vp.size = Vector2i(size, size)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.85)
	e.ambient_light_energy = 0.6
	env.environment = e
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.7, 0.0)
	vp.add_child(sun)
	var part := scene.instantiate() as Node3D
	vp.add_child(part)
	var box := bounds(part)
	var cam := Camera3D.new()
	cam.fov = 35.0
	var centre := box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.05)
	var dist := radius / sin(deg_to_rad(cam.fov * 0.5)) * 1.05
	cam.position = centre + Vector3(1.0, 0.8, 1.2).normalized() * dist
	cam.near = maxf(dist - radius * 2.0, 0.01)
	cam.far = dist + radius * 2.0
	vp.add_child(cam)
	cam.look_at(centre)
	cam.current = true
	for i in 3:
		await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


## Render the part in folder `dir` and keep its picture there. True if one was written.
static func make_for(dir: String, host: Node) -> bool:
	var ps := ResourceLoader.load(dir + "part.scn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var img: Image = await render(ps, host)
	if img == null or img.is_empty():
		return false
	return img.save_png(dir + FILE) == OK


## A part's picture as a texture for a list, or null.
static func texture_for(dir: String) -> Texture2D:
	if dir == "" or not FileAccess.file_exists(dir + FILE):
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(dir + FILE))
	return ImageTexture.create_from_image(img) if img != null and not img.is_empty() else null


## What a part's meshes take up, in its own frame.
static func bounds(part: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in part.find_children("*", "MeshInstance3D", true, false):
		var m := (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var t := Transform3D.IDENTITY
		var c: Node = mi
		while c != null and c != part:
			t = (c as Node3D).transform * t
			c = c.get_parent()
		var b := t * m.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out
