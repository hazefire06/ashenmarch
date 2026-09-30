shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Flat-shaded placeholder terrain: banded height colors (TerrainPalette) with
// a water-depth tint on top. TerrainView sets every uniform.

uniform sampler2D height_ramp : source_color, filter_nearest, repeat_disable;
// One texel per heightmap sample: water tint color, alpha = blend strength.
uniform sampler2D water_tint : source_color, filter_nearest, repeat_disable;
// Terrain height range in meters, mapped onto the ramp.
uniform float height_min;
uniform float height_max;
// Meters between samples, and the sample counts along x and z.
uniform float cell_size;
uniform vec2 sample_count;

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
	// sample, the same rule as the sim's water_depth_at.
	vec2 uv = (world_pos.xz / cell_size + 0.5) / sample_count;
	vec4 tint = texture(water_tint, uv);
	ALBEDO = mix(ground, tint.rgb, tint.a);
}
