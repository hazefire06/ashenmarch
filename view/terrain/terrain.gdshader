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
// model covers the sample, A the shore (1 at the water, 0 by
// TerrainView.SHORE_REACH_M up the bank). The six weights sum to 1.
uniform sampler2D ground_weights_a : filter_linear, repeat_disable;
uniform sampler2D ground_weights_b : filter_linear, repeat_disable;
// Tiling noise, four independent channels (WorldTextures.detail_noise).
uniform sampler2D detail_noise : filter_linear_mipmap, repeat_enable;
uniform float tile_m = 3.0;
// Anti-tiling: each layer is also read far_scale times larger, turned by
// far_angle (radians), and mixed in from far_near_m to far_far_m from the
// camera, up to far_share, give or take far_noise by place. Two periods at
// an odd ratio and angle, mixed unevenly, show no repeat.
uniform float far_scale = 3.7;
uniform float far_angle = 0.61;
uniform float far_near_m = 12.0;
uniform float far_far_m = 50.0;
uniform float far_share = 0.75;
uniform float far_noise = 0.35;
// Macro variation: over patches about a fifth of macro_m across, the ground
// is lighter or darker by up to macro_value, warmer or cooler by macro_hue,
// and more or less saturated by macro_saturation, so no field is one tone.
uniform float macro_m = 160.0;
uniform float macro_value = 0.12;
uniform float macro_hue = 0.04;
uniform float macro_saturation = 0.12;
// Borders: the weights are read over a spread of +-border_width samples, at a
// place bent by up to bend_large samples (noise repeating every bend_large_m
// meters, a lazy wander) plus bend_fine (a fine breakup). Then height_blend:
// within a border the brighter (higher) texel of two layers wins, by this
// much slack, so dirt shows between grass blades. Larger is plainer.
uniform float border_width = 1.5;
uniform float bend_large = 2.5;
uniform float bend_large_m = 90.0;
uniform float bend_fine = 0.6;
uniform float height_blend = 0.8;
// The mostly-grass palette: one continuous grass, as the reference shows,
// rather than the map's six grounds at full strength.
// - grass_tint darkens and deepens the grass layer, the base everywhere.
// - Brush and forest are that grass, darker (brush_tint, forest_tint), with
//   brush_detail or forest_detail of their own texture (by undergrowth_tint)
//   showing through as undergrowth.
// - Sand shows only near water, where the shore weight passes
//   sand_shore_low..sand_shore_high (banks, beaches), and then only
//   sand_shore_share of it over the grass; inland it is the grass by
//   dry_tint, a faint dry-grass tint.
// - Rock shows on steep faces (triplanar), and on flat rock ground as
//   rock_flat of it over the grass by rock_grass_tint.
// - Mud stays itself, at the water's edge.
uniform vec3 grass_tint = vec3(0.52, 0.7, 0.42);
uniform vec3 brush_tint = vec3(0.86, 0.9, 0.8);
uniform float brush_detail = 0.18;
uniform vec3 forest_tint = vec3(0.68, 0.76, 0.66);
uniform float forest_detail = 0.22;
uniform vec3 undergrowth_tint = vec3(0.55, 0.58, 0.45);
uniform vec3 dry_tint = vec3(1.12, 1.04, 0.8);
uniform float sand_shore_low = 0.35;
uniform float sand_shore_high = 0.75;
uniform float sand_shore_share = 0.5;
uniform float rock_flat = 0.35;
uniform vec3 rock_grass_tint = vec3(0.88, 0.9, 0.84);
// How hard noise pushes one layer over another within a border, 0..1. Any
// value is safe: the push fades to nothing where a layer's weight is 0 or 1.
uniform float border_jitter = 0.35;
// World normal y below which a face turns to rock (0.707 is 45 degrees, the
// walkable limit), fully rock rock_band lower.
uniform float rock_normal_y = 0.707;
uniform float rock_band = 0.1;
// Worn trails (TrailMask): R the wear, G a road's two wheel ruts, over the
// rectangle trail_origin .. trail_origin + trail_size (metres) and clear
// outside it. The wear becomes dirt (mud and sand, by trail_sand) where wear
// plus a fine breakup noise (trail_breakup, repeating every trail_noise_m)
// passes trail_edge_low..trail_edge_high, so grass breaks into the dirt at the
// edges; trail_strength scales it all. The ruts are trail_rut_dark darker.
uniform sampler2D trail_mask : hint_default_black, filter_linear, repeat_disable;
uniform vec2 trail_origin = vec2(0.0, 0.0);
uniform vec2 trail_size = vec2(1.0, 1.0);
uniform float trail_strength = 0.9;
uniform float trail_edge_low = 0.15;
uniform float trail_edge_high = 0.55;
uniform float trail_breakup = 0.45;
uniform float trail_noise_m = 1.7;
uniform float trail_sand = 0.65;
uniform vec4 trail_tint : source_color = vec4(0.95, 0.9, 0.8, 1.0);
uniform float trail_rut_dark = 0.22;
// One texel per heightmap sample: water tint color, alpha = blend strength.
// A dry sample is the shallow water's color at alpha 0, so filtering between
// samples fades the tint out at a bank without darkening it.
uniform sampler2D water_tint : source_color, filter_linear, repeat_disable;
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
// The water tint's colour is multiplied by this on the 3D ground (the overhead
// map keeps the palette's): the bed under the dark water surface (A5) reads
// dark too, not a pale band along each bank.
uniform vec3 bed_tint = vec3(0.45, 0.5, 0.5);
// One texel per sample, R: 0 unburnt, about 0.5 burning, 1 scorched; G: 1
// while burning, else 0. Filtered between samples, so G is how much burns
// and R - 0.5 G how much is scorched.
uniform sampler2D fire_state : filter_linear, repeat_disable;
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
// fire_state's R for a burning cell (TerrainView.FIRE_TEXEL, 128 / 255).
const float FIRE_BURNING_R = 0.502;
const int LAYER_COUNT = 6;
const int SAND = 3;
const int ROCK = 4;
const int MUD = 5;
// Meters per repeat of the fine border noise.
const float BORDER_NOISE_M = 6.0;
// Share of the plain filtered weight kept under the noisy one, so a spot
// where noise pushes every layer down still draws the nearest ground.
const float BORDER_FLOOR = 0.02;
// detail_noise mostly sits within 0.5 +- 1/3; this maps that onto -1..1.
const float NOISE_SPAN = 3.0;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
// The macro hue shift: warm one way, cool the other.
const vec3 WARM = vec3(1.0, 0.2, -1.0);

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
	// Every noise value below comes from these four reads.
	vec4 n_macro = texture(detail_noise, world_pos.xz / macro_m);
	vec4 n_large = texture(detail_noise, world_pos.xz / bend_large_m + vec2(0.31, 0.47));
	vec4 n_fine = texture(detail_noise, world_pos.xz / BORDER_NOISE_M);
	vec4 n_fine2 = texture(detail_noise, world_pos.xz / BORDER_NOISE_M + vec2(0.53, 0.19));

	// Borders: the weights, the water tint and the fire are read where noise
	// bends them to (off the grid, a lazy wander plus a fine breakup),
	// averaged over four reads border_width samples apart, so a border (a
	// bank, the edge of a burn) is a gradient two or three samples wide and a
	// staircase of samples rounds off. Averaging and filtering keep the six
	// weights summing to 1.
	vec2 bend = (n_large.rg - 0.5) * 2.0 * bend_large + (n_fine.rg - 0.5) * 2.0 * bend_fine;
	vec2 weights_uv = uv + bend / sample_count;
	vec2 spread = border_width / sample_count;
	vec4 wa = vec4(0.0);
	vec4 wb = vec4(0.0);
	vec4 tint = vec4(0.0);
	vec2 fire = vec2(0.0);
	for (int corner = 0; corner < 4; corner++) {
		vec2 at = weights_uv + spread * vec2(corner % 2 == 0 ? -1.0 : 1.0, corner < 2 ? -1.0 : 1.0);
		wa += texture(ground_weights_a, at) * 0.25;
		wb += texture(ground_weights_b, at) * 0.25;
		tint += texture(water_tint, at) * 0.25;
		fire += texture(fire_state, at).rg * 0.25;
	}
	float burning = fire.g;
	float scorched = clamp(fire.r - FIRE_BURNING_R * fire.g, 0.0, 1.0);
	float raw[6] = float[6](wa.r, wa.g, wa.b, wa.a, wb.r, wb.g);

	// Within a border, noise pushes each layer up or down, so the gradient
	// breaks into patches. The push scales with raw * (1 - raw): nothing
	// where a layer is absent or alone, whatever border_jitter is, so noise
	// never makes a layer appear.
	float push_noise[6] = float[6](n_fine.b, n_fine.a, n_fine2.r, n_fine2.g, n_fine2.b, n_fine2.a);
	float w[6];
	float total = 0.0;
	for (int i = 0; i < LAYER_COUNT; i++) {
		float push = (push_noise[i] - 0.5) * 2.0 * border_jitter * 4.0 * raw[i] * (1.0 - raw[i]);
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

	// Each layer near and far (anti-tiling). Every layer is read on every
	// fragment: mipmapped reads inside a branch that differs between
	// neighboring pixels pick the wrong mip level. Normal maps only matter
	// close up, so they are read at the near scale alone.
	vec2 near_uv = world_pos.xz / tile_m;
	float turn_c = cos(far_angle);
	float turn_s = sin(far_angle);
	vec2 far_uv = mat2(vec2(turn_c, turn_s), vec2(-turn_s, turn_c)) * world_pos.xz / (tile_m * far_scale)
		+ vec2(0.37, 0.61);
	float view_m = length(CAMERA_POSITION_WORLD - world_pos);
	float far_mix = clamp(smoothstep(far_near_m, far_far_m, view_m) * far_share
		+ (n_large.b - 0.5) * 2.0 * far_noise, 0.0, 1.0);
	vec3 color[6];
	vec3 bump[6];
	for (int i = 0; i < LAYER_COUNT; i++) {
		vec3 near = texture(ground_albedo, vec3(near_uv, float(i))).rgb;
		vec3 far = texture(ground_albedo, vec3(far_uv, float(i))).rgb;
		color[i] = mix(near, far, far_mix);
		bump[i] = texture(ground_normal, vec3(near_uv, float(i))).rgb;
	}
	// Steep rock is triplanar, so a cliff's rock isn't smeared down it, and
	// its flat-ground normal map, wrong on a cliff, is flattened there.
	vec3 side = pow(abs(up_normal), vec3(4.0));
	side /= side.x + side.y + side.z;
	vec3 rock_x = texture(ground_albedo, vec3(world_pos.zy / tile_m, float(ROCK))).rgb;
	vec3 rock_z = texture(ground_albedo, vec3(world_pos.xy / tile_m, float(ROCK))).rgb;
	color[ROCK] = mix(color[ROCK], rock_x * side.x + color[ROCK] * side.y + rock_z * side.z, steep);
	bump[ROCK] = mix(bump[ROCK], FLAT_NORMAL, steep);

	// The mostly-grass palette (see grass_tint). The trails keep the sand
	// layer's own colour for their dirt.
	vec3 sand_color = color[SAND];
	float shore = smoothstep(sand_shore_low, sand_shore_high, wb.a);
	float rocky = max(steep, rock_flat);
	vec3 grass = color[0] * grass_tint;
	color[0] = grass;
	color[1] = mix(grass * brush_tint, color[1] * undergrowth_tint, brush_detail);
	color[2] = mix(grass * forest_tint, color[2] * undergrowth_tint, forest_detail);
	color[SAND] = mix(grass * dry_tint, color[SAND], shore * sand_shore_share);
	color[ROCK] = mix(grass * rock_grass_tint, color[ROCK], rocky);
	bump[1] = mix(bump[0], bump[1], brush_detail);
	bump[2] = mix(bump[0], bump[2], forest_detail);
	bump[SAND] = mix(bump[0], bump[SAND], shore * sand_shore_share);
	bump[ROCK] = mix(bump[0], bump[ROCK], rocky);

	// Height blend: brightness stands in for height. A layer keeps its weight
	// in proportion to how close its weight plus height comes to the top one,
	// within height_blend; a layer of weight 0 stays 0.
	float top = 0.0;
	for (int i = 0; i < LAYER_COUNT; i++) {
		top = max(top, w[i] > 0.0 ? w[i] + dot(color[i], LUMA) : 0.0);
	}
	total = 0.0;
	for (int i = 0; i < LAYER_COUNT; i++) {
		w[i] *= max(w[i] + dot(color[i], LUMA) - top + height_blend, 0.0);
		total += w[i];
	}
	for (int i = 0; i < LAYER_COUNT; i++) {
		w[i] /= max(total, 0.0001);
	}

	// Mud takes the recolor of the ground under it (grass where it is all mud).
	vec4 under = vec4(0.0);
	float under_weight = 0.0;
	for (int i = 0; i < MUD; i++) {
		under += ground_recolor[i] * w[i];
		under_weight += w[i];
	}
	vec4 mud_recolor = under_weight > 0.001 ? under / under_weight : ground_recolor[0];
	vec3 ground = vec3(0.0);
	vec3 normal_map = vec3(0.0);
	for (int i = 0; i < LAYER_COUNT; i++) {
		vec4 recolor = i == MUD ? mud_recolor : ground_recolor[i];
		ground += mix(color[i], recolor.rgb, recolor.a) * w[i];
		normal_map += bump[i] * w[i];
	}
	// Worn trails: dirt where the wear, broken up by fine noise, is high;
	// darker in a road's ruts. Graded as the sand of a road would be.
	vec2 trail = texture(trail_mask, (world_pos.xz - trail_origin) / trail_size).rg;
	float trail_noise = texture(detail_noise, world_pos.xz / trail_noise_m).g;
	float worn = trail_strength * smoothstep(trail_edge_low, trail_edge_high,
		trail.r + (trail_noise - 0.5) * 2.0 * trail_breakup * trail.r * (1.0 - trail.r) * 4.0);
	vec3 dirt = mix(color[MUD], sand_color, trail_sand) * trail_tint.rgb;
	dirt = mix(dirt, ground_recolor[SAND].rgb, ground_recolor[SAND].a);
	dirt *= 1.0 - trail_rut_dark * smoothstep(0.25, 0.7, trail.g);
	ground = mix(ground, dirt, worn);
	normal_map = mix(normal_map, bump[MUD], worn);

	// Under water the bed's relief is drowned: the ground's normal map fades out
	// with the water tint, or a ford's shallow bed shows the layer's tiling
	// bumps as a regular grid through its smooth tint.
	NORMAL_MAP = mix(normal_map, FLAT_NORMAL, tint.a);

	// Macro variation: value, a warm-cool hue shift and saturation.
	vec3 macro = clamp((n_macro.rgb - 0.5) * NOISE_SPAN, -1.0, 1.0);
	ground *= 1.0 + macro_value * macro.x;
	ground *= 1.0 + macro_hue * macro.y * WARM;
	float tone = dot(ground, LUMA);
	ground = max(mix(vec3(tone), ground, 1.0 + macro_saturation * macro.z), vec3(0.0));
	float luma = dot(ground, LUMA);
	ground = mix(ground, vec3(luma), grade_desaturation) * grade_tint.rgb;

	ground = mix(ground, CHAR, 0.85 * scorched);

	// Wet ground is darker and a little cooler.
	ground *= mix(vec3(1.0), vec3(0.66, 0.70, 0.76), wetness);
	// Snow settles on faces that point up, not on steep ones. It can cover
	// burnt ground, but a burning cell melts its own.
	ground = mix(ground, SNOW, snow_cover * smoothstep(0.55, 0.85, up_normal.y));
	ground = mix(ground, EMBER, 0.6 * burning);
	EMISSION = EMBER * 0.5 * burning;

	ground = mix(ground, mix(tint.rgb * bed_tint, water_grade.rgb, water_grade.a), tint.a);

	// A blocked sample reads as solid, unless a structure model stands on it.
	// Both read the nearest sample, the sim's rule for blocked samples.
	ivec2 nearest = ivec2(clamp(floor(world_pos.xz / cell_size + 0.5), vec2(0.0), sample_count - 1.0));
	float bare = texture(blocked_map, uv).r * (1.0 - texelFetch(ground_weights_b, nearest, 0).b);
	float grey = dot(ground, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = mix(ground, vec3(grey), blocked_tint.y * bare) * (1.0 - blocked_tint.x * bare);
}
