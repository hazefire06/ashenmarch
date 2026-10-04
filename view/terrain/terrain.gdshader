shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Flat-shaded placeholder terrain: banded height colors (TerrainPalette),
// tinted by ground type, darker and greyer where a structure blocks the
// sample, charred where the sim's fire has been, darkened when wet, whitened by
// snow on faces that point up, glowing where it burns now, and the water-depth
// tint on top. TerrainView sets every uniform.
//
// The mission's grade (Atmosphere, via AtmosphereView and TerrainView.set_grade)
// sits on the ground color before any of that: a per-ground-type recolor, then
// a desaturation and a tint. Its uniforms default to "no change", so a terrain
// nobody graded draws exactly as it did before the grade existed.

uniform sampler2D height_ramp : source_color, filter_nearest, repeat_disable;
// One texel per heightmap sample: water tint color, alpha = blend strength.
uniform sampler2D water_tint : source_color, filter_nearest, repeat_disable;
// One texel per sample: ground-type tint, alpha = blend strength.
uniform sampler2D ground_tint : source_color, filter_nearest, repeat_disable;
// One texel per sample, R: 1 where a structure blocks it (a house, a wall),
// else 0. The sim never changes blocked samples, so unlike fire_state this is
// written once.
uniform sampler2D blocked_map : filter_nearest, repeat_disable;
// How a blocked sample is drawn: x how much darker, y how much greyer, both
// 0..1 (TerrainPalette.BLOCKED_DARKEN and BLOCKED_DESATURATE).
uniform vec2 blocked_tint = vec2(0.45, 0.25);
// One texel per sample, R: its Terrain.Ground (0..4), written once.
uniform sampler2D ground_kind : filter_nearest, repeat_disable;
// The grade. grade_tint multiplies the ground (white changes nothing) and
// grade_desaturation drains it toward its own gray (0 changes nothing).
// ground_recolor holds one color per Terrain.Ground, blended over that ground
// type by its alpha; all zeros, the default, is no recolor. water_grade is
// blended over the water tint by its alpha, and only where there is water.
uniform vec4 grade_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float grade_desaturation = 0.0;
uniform vec4 ground_recolor[5] : source_color;
uniform vec4 water_grade : source_color = vec4(0.0, 0.0, 0.0, 0.0);
// One texel per sample, R: 0 unburnt, about 0.5 burning, 1 scorched.
uniform sampler2D fire_state : filter_nearest, repeat_disable;
// How wet the ground is and how much snow lies on it, 0..1.
uniform float wetness = 0.0;
uniform float snow_cover = 0.0;
// Terrain height range in meters, mapped onto the ramp.
uniform float height_min;
uniform float height_max;
// Meters between samples, and the sample counts along x and z.
uniform float cell_size;
uniform vec2 sample_count;

const vec3 CHAR = vec3(0.07, 0.06, 0.05);
const vec3 EMBER = vec3(0.85, 0.32, 0.07);
const vec3 SNOW = vec3(0.92, 0.94, 0.97);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Face normal from screen-space derivatives, so the mesh can share
	// vertices and stay indexed. VERTEX is the view-space position, so a
	// normal facing the camera has a negative dot product with it.
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = dot(n, VERTEX) > 0.0 ? -n : n;

	float t = clamp((world_pos.y - height_min) / max(height_max - height_min, 0.001), 0.0, 1.0);
	vec3 ground = texture(height_ramp, vec2(t, 0.5)).rgb;
	// Texel (i, j) is sample (i, j). Nearest filtering picks the nearest
	// sample, the same rule as the sim's water_depth_at and fire cells.
	vec2 uv = (world_pos.xz / cell_size + 0.5) / sample_count;
	vec4 kind = texture(ground_tint, uv);
	ground = mix(ground, kind.rgb, kind.a);
	int ground_type = clamp(int(texture(ground_kind, uv).r * 255.0 + 0.5), 0, 4);
	vec4 recolor = ground_recolor[ground_type];
	ground = mix(ground, recolor.rgb, recolor.a);
	float luma = dot(ground, vec3(0.2126, 0.7152, 0.0722));
	ground = mix(ground, vec3(luma), grade_desaturation) * grade_tint.rgb;
	float solid = texture(blocked_map, uv).r;
	float grey = dot(ground, vec3(0.2126, 0.7152, 0.0722));
	ground = mix(ground, vec3(grey), blocked_tint.y * solid) * (1.0 - blocked_tint.x * solid);

	float fire = texture(fire_state, uv).r;
	if (fire > 0.75) {
		ground = mix(ground, CHAR, 0.85);
	}

	// Wet ground is darker and a little cooler.
	ground *= mix(vec3(1.0), vec3(0.66, 0.70, 0.76), wetness);
	// Snow settles on faces that point up, not on steep ones. It can cover
	// burnt ground, but a burning cell melts its own.
	float up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
	ground = mix(ground, SNOW, snow_cover * smoothstep(0.55, 0.85, up));
	if (fire > 0.25 && fire <= 0.75) {
		ground = mix(ground, EMBER, 0.6);
		EMISSION = EMBER * 0.5;
	}

	vec4 tint = texture(water_tint, uv);
	ALBEDO = mix(ground, mix(tint.rgb, water_grade.rgb, water_grade.a), tint.a);
}
