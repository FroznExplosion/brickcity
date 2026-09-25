// elemental_overlay.gdshader
// ONE ShaderMaterial shared by every enemy, assigned as `material_overlay`.
// All per-enemy state lives in `instance uniform`s (scalars/colors only —
// textures must be regular uniforms, which is fine: everyone shares the noise).
//
// Drives: ICE crust/freeze, FIRE embers, CORROSIVE/SLAG coat, RADIATION pulse.
// Cost control: this is a second pass over the mesh — enemies with no active
// element have material_overlay = null (toggled by ElementalTarget), so the
// pass simply doesn't exist for them.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_disabled;

// ---- shared (set once on the material) ----
uniform sampler2D noise_tex : hint_default_white, repeat_enable;   // RGB noise (NoiseTexture2D)
uniform sampler2D crack_tex : hint_default_white, repeat_enable;   // voronoi/cracks
uniform float triplanar_scale = 0.8;

// ---- per-enemy (set via set_instance_shader_parameter) ----
instance uniform vec4 element_color : source_color = vec4(1.0);
instance uniform float coat_amount = 0.0;    // corrosive/slag goo & drips
instance uniform float freeze_amount = 0.0;  // 0..1 icing over, 1 = popsicle
instance uniform float burn_amount = 0.0;    // 0..1 creeping embers
instance uniform float pulse_speed = 0.0;    // radiation/slag throb

varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Ice shell: inflate slightly along normals so the crust reads as a
	// physical layer around the character (the "popsicle" silhouette).
	VERTEX += NORMAL * freeze_amount * 0.035;
}

// Cheap triplanar so Synty's atlas UVs (which are tiny islands) don't matter.
float triplanar_noise(sampler2D tex, vec3 p, vec3 n) {
	vec3 an = abs(n); an /= (an.x + an.y + an.z);
	float x = texture(tex, p.zy * triplanar_scale).r;
	float y = texture(tex, p.xz * triplanar_scale).r;
	float z = texture(tex, p.xy * triplanar_scale).r;
	return x * an.x + y * an.y + z * an.z;
}

void fragment() {
	float n = triplanar_noise(noise_tex, world_pos, world_nrm);
	float fres = pow(1.0 - clamp(dot(normalize(-VIEW), -NORMAL), 0.0, 1.0), 2.5);
	float alpha = 0.0;
	vec3 col = element_color.rgb;
	vec3 emis = vec3(0.0);

	// ---------- coat (corrosive / slag): goo creeping down from the top ----------
	if (coat_amount > 0.001) {
		// world-space "drip" mask: more coat higher up + noise breakup
		float drip = smoothstep(1.0 - coat_amount * 1.4, 1.0, n * 0.6 + fract(world_pos.y * 0.35) * 0.4);
		float coat = max(drip, coat_amount * n);
		alpha = max(alpha, coat * 0.85);
		emis += col * coat * 0.6;   // wet glisten
	}

	// ---------- freeze: frost -> solid ice crust ----------
	if (freeze_amount > 0.001) {
		float frost = smoothstep(0.55 - freeze_amount * 0.55, 0.9, n + fres * 0.5);
		float crust = smoothstep(0.35, 1.0, freeze_amount);       // late phase = solid
		float ice = max(frost * freeze_amount, crust * 0.92);
		float cracks = triplanar_noise(crack_tex, world_pos * 2.0, world_nrm);
		alpha = max(alpha, ice);
		col = mix(col, vec3(0.85, 0.95, 1.0), crust * cracks);
		emis += vec3(0.4, 0.7, 1.0) * fres * freeze_amount * 0.8; // rim glow
		ROUGHNESS = 0.05;
		METALLIC = 0.1;
	}

	// ---------- burn: embers crawl through noise, edges glow ----------
	if (burn_amount > 0.001) {
		float front = n - (1.0 - burn_amount);        // noise-driven fire front
		float char_mask = smoothstep(0.0, 0.15, front);           // blackened
		float ember = smoothstep(0.0, 0.06, front) - smoothstep(0.06, 0.18, front);
		float flicker = 0.75 + 0.25 * sin(TIME * 9.0 + world_pos.y * 6.0);
		alpha = max(alpha, char_mask * 0.9);
		col = mix(col, vec3(0.03), char_mask);                    // charred skin
		emis += vec3(1.0, 0.35, 0.05) * ember * 6.0 * flicker;    // hot edge
		emis += vec3(1.0, 0.5, 0.1) * fres * burn_amount * 1.5;   // heat haze rim
	}

	// ---------- pulse (radiation throb / slag shimmer) ----------
	if (pulse_speed > 0.001) {
		float pulse = 0.5 + 0.5 * sin(TIME * pulse_speed + world_pos.y * 2.0);
		emis += col * pulse * fres * 2.0;
		alpha = max(alpha, fres * 0.35 * pulse);
	}

	ALBEDO = col;
	EMISSION = emis;
	ALPHA = clamp(alpha, 0.0, 1.0) * element_color.a;
}
