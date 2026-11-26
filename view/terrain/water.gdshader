// The water surface (A5): a translucent sheet over the wet samples, drawn at
// the surface height the map generator recorded.
//
// Compatibility renderer: no depth or screen texture. The shore's softness and
// the color's depth both come from depth_map instead, one half-float texel per
// terrain sample holding (surface - bed) in metres, scaled 0..4 m to 0..1. Linear
// filtering ramps it to zero across the last cell of the bank, so the water
// fades out at the shoreline.
//
// The ripples bend the normal with the shared tiling detail noise, scrolling
// two copies in different directions. ripple_strength grows with rain.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back;

uniform sampler2D depth_map : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D detail_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
// Terrain samples along x and z, and meters between them.
uniform vec2 sample_count = vec2(2.0, 2.0);
uniform float cell_size = 1.0;
// Meters of water at which depth_map reads 1.
uniform float depth_range = 4.0;
// The depth is the average of four reads depth_spread samples apart (the
// terrain's water tint reads its texture the same way), so the bilinear
// filter's creases along the samples don't show through the shallow fade as
// a grid.
uniform float depth_spread = 0.75;

// Colors of shallow and deep water, mixed by depth.
uniform vec4 shallow_color : source_color = vec4(0.27, 0.46, 0.47, 1.0);
uniform vec4 deep_color : source_color = vec4(0.04, 0.17, 0.24, 1.0);
// A mission's grade, blended over the water's own color by its alpha.
uniform vec4 water_grade : source_color = vec4(0.0, 0.0, 0.0, 0.0);
// Opacity at the shore, rising to deep_alpha with depth.
uniform float shallow_alpha : hint_range(0.0, 1.0) = 0.25;
uniform float deep_alpha : hint_range(0.0, 1.0) = 0.88;

// Noise cycles per second of scrolling, and meters per noise tile.
uniform float ripple_speed = 0.03;
uniform float ripple_tile_m = 9.0;
// How far the ripples tilt the normal.
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.3;

varying vec3 world_pos;

float ripple_height(vec2 uv) {
	return texture(detail_noise, uv).r;
}

// The noise's slope at uv, by forward differences.
vec2 ripple_slope(vec2 uv) {
	float e = 0.004;
	float h = ripple_height(uv);
	return vec2(ripple_height(uv + vec2(e, 0.0)) - h, ripple_height(uv + vec2(0.0, e)) - h) / e;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz / ripple_tile_m;
	float t = TIME * ripple_speed;
	vec2 slope = ripple_slope(uv + vec2(t, t * 0.6)) + ripple_slope(uv * 1.7 + vec2(-t * 1.3, t));
	vec3 bend = vec3(-slope.x, 0.0, -slope.y) * ripple_strength * 0.02;
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(bend, 0.0)).xyz);

	vec2 depth_uv = (world_pos.xz / cell_size + 0.5) / sample_count;
	vec2 spread = depth_spread / sample_count;
	float depth = 0.0;
	for (int corner = 0; corner < 4; corner++) {
		vec2 at = depth_uv + spread * vec2(corner % 2 == 0 ? -1.0 : 1.0, corner < 2 ? -1.0 : 1.0);
		depth += texture(depth_map, at).r * 0.25;
	}
	depth = clamp(depth, 0.0, 1.0);
	vec3 color = mix(shallow_color.rgb, deep_color.rgb, sqrt(depth));
	color = mix(color, water_grade.rgb, water_grade.a);
	float glancing = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);

	ALBEDO = color;
	ROUGHNESS = 0.08;
	SPECULAR = 0.7;
	ALPHA = clamp(mix(shallow_alpha, deep_alpha, sqrt(depth)) * smoothstep(0.0, 0.08, depth + 0.001) + glancing * 0.15 * step(0.001, depth), 0.0, 1.0);
}
