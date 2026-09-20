class_name MeshRetirer
extends RefCounted

## Hold a replaced mesh for a few frames before letting it go.
##
## An `ArrayMesh` is reference-counted, so `instance.mesh = new_mesh` drops the
## last reference to the old one and frees its GPU buffers **this frame**. That
## is fine while the renderer only ever draws what it was handed this frame.
##
## It stops being fine the moment `physics_interpolation` is on. Interpolation
## renders between physics ticks, which means it still holds the previous
## frame's mesh when the new one arrives -- and freeing the old one out from
## under it produces, once per remesh:
##
##     ERROR: Buffer argument is not a valid buffer of any type.
##            at: buffer_update (servers/rendering/rendering_device.cpp:477)
##
## Thirteen of those per collapse, which is what kept interpolation switched off
## and therefore what kept 30 Hz looking like 30 Hz. The fix is not clever: keep
## the reference for a couple of frames and let the renderer finish with it.

## Frames to hold. Interpolation needs one; two is free and leaves room for a
## renderer that ever buffers deeper.
const HOLD_FRAMES := 2

var _held: Array = []   ## [frame_released, mesh]


## Take ownership of a mesh that has just been replaced. Null is accepted and
## ignored, so callers do not have to check.
func retire(mesh: Mesh) -> void:
	if mesh == null:
		return
	_held.append([Engine.get_frames_drawn(), mesh])


## Let go of anything the renderer has certainly finished with. Cheap: the list
## is in release order, so it only ever inspects the front.
func drain() -> void:
	var now := Engine.get_frames_drawn()
	while not _held.is_empty():
		var entry: Array = _held[0]
		if now - int(entry[0]) < HOLD_FRAMES:
			break
		_held.pop_front()


func pending() -> int:
	return _held.size()
