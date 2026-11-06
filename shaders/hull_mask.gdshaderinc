// The sea cut out of floating hulls (Docs/Hulls.md 6): every water shader asks
// hull_dry(world point) and discards where it is true -- inside a hull's dry
// cells (its bricks and its dry inside air), cell by cell, so the cut follows the
// hull's bricks exactly. Two hulls at once, the nearest the camera (HullMasks
// fills these globals): a byte a cell (255 dry), a world-to-cell transform, and
// the grid's size with w = 1 while the slot is in use.

global uniform sampler3D hull_mask_a : filter_nearest;
global uniform sampler3D hull_mask_b : filter_nearest;
global uniform mat4 hull_xf_a;
global uniform mat4 hull_xf_b;
global uniform vec4 hull_dims_a;
global uniform vec4 hull_dims_b;

bool hull_dry_a(vec3 wp) {
	if (hull_dims_a.w < 0.5) {
		return false;
	}
	vec3 c = (hull_xf_a * vec4(wp, 1.0)).xyz;
	if (any(lessThan(c, vec3(0.0))) || any(greaterThanEqual(c, hull_dims_a.xyz))) {
		return false;
	}
	return texelFetch(hull_mask_a, ivec3(floor(c)), 0).r > 0.5;
}

bool hull_dry_b(vec3 wp) {
	if (hull_dims_b.w < 0.5) {
		return false;
	}
	vec3 c = (hull_xf_b * vec4(wp, 1.0)).xyz;
	if (any(lessThan(c, vec3(0.0))) || any(greaterThanEqual(c, hull_dims_b.xyz))) {
		return false;
	}
	return texelFetch(hull_mask_b, ivec3(floor(c)), 0).r > 0.5;
}

bool hull_dry(vec3 wp) {
	return hull_dry_a(wp) || hull_dry_b(wp);
}
