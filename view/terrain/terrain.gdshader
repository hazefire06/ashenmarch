shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Smooth-shaded, textured terrain (A5): six tiling ground layers (grass,
// brush, forest floor, sand, rock, mud; WorldTextures) blended by per-sample
// weights, with noise along their borders and rock on steep faces. On top of
// that, in order: the mission's grade, the sim's fire, wetness, snow, the
// water-depth tint, and the darkening of a blocked sample no structure model
// covers. TerrainView sets every uniform.
//
// The grade (Atmosphere, via AtmosphereView and TerrainView.set_grade) is a
// per-ground-type recolor, then a desaturation and a tint. Its uniforms
// default to "no change", so a terrain nobody graded draws ungraded.

// The six layers, in WorldTextures.LAYERS order, tiled every tile_m meters.
uniform sampler2DArray ground_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray ground_normal : hint_normal, filter_linear_mipmap, repeat_enable;
// One texel per heightmap sample, filtered between samples. A: the grass,
// brush, forest and sand weights. B: R rock, G mud, B 1 where a structure
// model covers the sample, A unused. The six weights sum to 1.
uniform sampler2D ground_weights_a : filter_linear, repeat_disable;
uniform sampler2D ground_weights_b : filter_linear, repeat_disable;
// Tiling greyscale noise (WorldTextures.detail_noise).
uniform sampler2D detail_noise : filter_linear_mipmap, repeat_enable;
uniform float tile_m = 3.0;
// How hard noise pushes one layer over another within a border, 0..1. Any
// value is safe: the push fades to nothing where a layer's weight is 0 or 1.
uniform float border_jitter = 0.35;
// World normal y below which a face turns to rock (0.707 is 45 degrees, the
// walkable limit), fully rock rock_band lower.
uniform float rock_normal_y = 0.707;
uniform float rock_band = 0.1;
// One texel per heightmap sample: water tint color, alpha = blend strength.
uniform sampler2D water_tint : source_color, filter_nearest, repeat_disable;
// One texel per sample, R: 1 where a structure blocks it (a house, a wall),
// else 0. The sim never changes blocked samples, so unlike fire_state this is
// written once.
uniform sampler2D blocked_map : filter_nearest, repeat_disable;
// How a blocked sample no model covers is drawn: x how much darker, y how
// much greyer, both 0..1 (TerrainPalette.BLOCKED_DARKEN and BLOCKED_DESATURATE).
uniform vec2 blocked_tint = vec2(0.45, 0.25);
// The grade. grade_tint multiplies the ground (white changes nothing) and
// grade_desaturation drains it toward its own gray (0 changes nothing).
// ground_recolor holds one color per Terrain.Ground, blended over that ground
// type's layer by its alpha; all zeros, the default, is no recolor. Mud takes
// the recolor of the ground it lies on. water_grade is blended over the water
// tint by its alpha, and only where there is water.
uniform vec4 grade_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float grade_desaturation = 0.0;
uniform vec4 ground_recolor[5] : source_color;
uniform vec4 water_grade : source_color = vec4(0.0, 0.0, 0.0, 0.0);
// One texel per sample, R: 0 unburnt, about 0.5 burning, 1 scorched.
uniform sampler2D fire_state : filter_nearest, repeat_disable;
// How wet the ground is and how much snow lies on it, 0..1.
uniform float wetness = 0.0;
uniform float snow_cover = 0.0;
// Meters between samples, and the sample counts along x and z.
uniform float cell_size;
uniform vec2 sample_count;

const vec3 CHAR = vec3(0.07, 0.06, 0.05);
const vec3 EMBER = vec3(0.85, 0.32, 0.07);
const vec3 SNOW = vec3(0.92, 0.94, 0.97);
const vec3 FLAT_NORMAL = vec3(0.5, 0.5, 1.0);
const int LAYER_COUNT = 6;
const int ROCK = 4;
const int MUD = 5;
// Meters per repeat of detail_noise along borders, and for the slow tint.
const float BORDER_NOISE_M = 6.0;
const float TINT_NOISE_M = 48.0;
// Each layer reads the border noise this far (in noise tiles) from the last,
// so neighboring layers push their border in different places.
const vec2 LAYER_NOISE_STEP = vec2(0.37, 0.71);
// How far, in samples, noise bends where the weights are read, so borders
// wander off the sample grid.
const float BORDER_WARP = 0.6;
// Share of the plain filtered weight kept under the noisy one, so a spot
// where noise pushes every layer down still draws the nearest ground.
const float BORDER_FLOOR = 0.02;
// How far the slow noise lightens or darkens the ground, either way.
const float TINT_VARIATION = 0.07;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	// The layers are read at world x and z (u along +x, v along +z). Godot's
	// normal maps point green up the image, toward -v, so the binormal runs
	// along -z. Both are laid onto the surface.
	TANGENT = normalize(vec3(1.0, 0.0, 0.0) - NORMAL * NORMAL.x);
	BINORMAL = normalize(vec3(0.0, 0.0, -1.0) + NORMAL * NORMAL.z);
}

void fragment() {
	vec3 up_normal = normalize(world_normal);
	// Texel (i, j) is sample (i, j), so sample centers sit on texel centers.
	vec2 uv = (world_pos.xz / cell_size + 0.5) / sample_count;
	// Borders: the weights are read where noise bends them to (off the
	// grid), averaged over four reads half a sample apart, so a border is a
	// gradient about two samples wide and a staircase of samples rounds off.
	// Averaging and filtering keep the six summing to 1.
	vec2 noise_uv = world_pos.xz / BORDER_NOISE_M;
	vec2 bend = vec2(texture(detail_noise, noise_uv + vec2(0.5, 0.0)).r,
		texture(detail_noise, noise_uv + vec2(0.0, 0.5)).r) - 0.5;
	vec2 weights_uv = uv + bend * 2.0 * BORDER_WARP / sample_count;
	vec2 half_sample = 0.5 / sample_count;
	vec4 wa = vec4(0.0);
	vec4 wb = vec4(0.0);
	for (int corner = 0; corner < 4; corner++) {
		vec2 at = weights_uv + half_sample * vec2(corner % 2 == 0 ? -1.0 : 1.0, corner < 2 ? -1.0 : 1.0);
		wa += texture(ground_weights_a, at) * 0.25;
		wb += texture(ground_weights_b, at) * 0.25;
	}
	float raw[6] = float[6](wa.r, wa.g, wa.b, wa.a, wb.r, wb.g);

	// Within a border, noise pushes each layer up or down, so the gradient
	// breaks into patches. The push scales with raw * (1 - raw): nothing
	// where a layer is absent or alone, whatever border_jitter is, so noise
	// never makes a layer appear.
	float w[6];
	float total = 0.0;
	for (int i = 0; i < LAYER_COUNT; i++) {
		float n = texture(detail_noise, noise_uv + LAYER_NOISE_STEP * float(i + 1)).r;
		float push = (n - 0.5) * 2.0 * border_jitter * 4.0 * raw[i] * (1.0 - raw[i]);
		w[i] = clamp(raw[i] + push, 0.0, 1.0) + raw[i] * BORDER_FLOOR;
		total += w[i];
	}
	// Rock on faces too steep to walk, over whatever the map says; the
	// weights still sum to 1.
	float steep = 1.0 - smoothstep(rock_normal_y - rock_band, rock_normal_y, up_normal.y);
	for (int i = 0; i < LAYER_COUNT; i++) {
		w[i] = w[i] / max(total, 0.0001) * (1.0 - steep);
	}
	w[ROCK] += steep;

	// Mud takes the recolor of the ground under it (grass where it is all mud).
	vec4 under = vec4(0.0);
	float under_weight = 0.0;
	for (int i = 0; i < MUD; i++) {
		under += ground_recolor[i] * w[i];
		under_weight += w[i];
	}
	vec4 mud_recolor = under_weight > 0.001 ? under / under_weight : ground_recolor[0];

	// Every layer is read on every fragment: mipmapped reads inside a branch
	// that differs between neighboring pixels pick the wrong mip level.
	vec2 tile_uv = world_pos.xz / tile_m;
	vec3 ground = vec3(0.0);
	vec3 normal_map = vec3(0.0);
	for (int i = 0; i < LAYER_COUNT; i++) {
		vec3 color = texture(ground_albedo, vec3(tile_uv, float(i))).rgb;
		vec3 bump = texture(ground_normal, vec3(tile_uv, float(i))).rgb;
		vec4 recolor = i == MUD ? mud_recolor : ground_recolor[i];
		ground += mix(color, recolor.rgb, recolor.a) * w[i];
		normal_map += bump * w[i];
	}
	// Steep rock is triplanar, so a cliff's rock isn't smeared down it, and
	// its flat-ground normal map, wrong on a cliff, is flattened there.
	vec3 side = pow(abs(up_normal), vec3(4.0));
	side /= side.x + side.y + side.z;
	vec3 rock_down = texture(ground_albedo, vec3(tile_uv, float(ROCK))).rgb;
	vec3 rock_x = texture(ground_albedo, vec3(world_pos.zy / tile_m, float(ROCK))).rgb;
	vec3 rock_z = texture(ground_albedo, vec3(world_pos.xy / tile_m, float(ROCK))).rgb;
	vec3 rock_triplanar = rock_x * side.x + rock_down * side.y + rock_z * side.z;
	vec4 rock_recolor = ground_recolor[ROCK];
	ground += (mix(rock_triplanar, rock_recolor.rgb, rock_recolor.a)
		- mix(rock_down, rock_recolor.rgb, rock_recolor.a)) * w[ROCK] * steep;
	vec3 rock_bump = texture(ground_normal, vec3(tile_uv, float(ROCK))).rgb;
	normal_map += (FLAT_NORMAL - rock_bump) * w[ROCK] * steep;
	NORMAL_MAP = normal_map;

	// A slow, gentle light and dark so no patch repeats exactly.
	float slow = texture(detail_noise, world_pos.xz / TINT_NOISE_M).r;
	ground *= mix(1.0 - TINT_VARIATION, 1.0 + TINT_VARIATION, slow);
	float luma = dot(ground, vec3(0.2126, 0.7152, 0.0722));
	ground = mix(ground, vec3(luma), grade_desaturation) * grade_tint.rgb;

	float fire = texture(fire_state, uv).r;
	if (fire > 0.75) {
		ground = mix(ground, CHAR, 0.85);
	}

	// Wet ground is darker and a little cooler.
	ground *= mix(vec3(1.0), vec3(0.66, 0.70, 0.76), wetness);
	// Snow settles on faces that point up, not on steep ones. It can cover
	// burnt ground, but a burning cell melts its own.
	ground = mix(ground, SNOW, snow_cover * smoothstep(0.55, 0.85, up_normal.y));
	if (fire > 0.25 && fire <= 0.75) {
		ground = mix(ground, EMBER, 0.6);
		EMISSION = EMBER * 0.5;
	}

	vec4 tint = texture(water_tint, uv);
	ground = mix(ground, mix(tint.rgb, water_grade.rgb, water_grade.a), tint.a);

	// A blocked sample reads as solid, unless a structure model stands on it.
	// Both read the nearest sample, the sim's rule for blocked samples.
	ivec2 nearest = ivec2(clamp(floor(world_pos.xz / cell_size + 0.5), vec2(0.0), sample_count - 1.0));
	float bare = texture(blocked_map, uv).r * (1.0 - texelFetch(ground_weights_b, nearest, 0).b);
	float grey = dot(ground, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = mix(ground, vec3(grey), blocked_tint.y * bare) * (1.0 - blocked_tint.x * bare);
}
