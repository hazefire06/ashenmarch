shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

// The ground scatter (A5, view only): grass tufts, plants, bushes and pebbles,
// drawn as MultiMesh instances by ScatterView, one material per kit surface
// and kind. It does to an item what terrain.gdshader does to the ground under
// it, in the same order: the ground's recolor (the instance's custom R is its
// Terrain.Ground), the grade, the fire, wetness and snow. The constants match
// world_model.gdshader's, so a burnt bush matches a burnt house and its yard.
//
// In the vertex stage: grass and plants sway with TIME (cosmetic), every item
// shrinks into the ground over the last fade_margin metres before fade_end
// from the camera, and the sim's fire (fire_state, one texel per sample, read
// at the item's sample) takes grass and plants away once their cell is
// scorched and leaves bushes as charred stumps.

uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// Leaves and flowers are cut out of their cards at this alpha; 0 for the
// solid models (grass blades, mushrooms, pebbles).
uniform float alpha_cutoff = 0.0;
// The kit is bright and saturated; these bring an item toward the ground's
// photographic colours before anything else: a multiplier, then a drain
// toward its own gray.
uniform vec4 kit_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float kit_desaturation = 0.0;
uniform vec4 grade_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float grade_desaturation = 0.0;
// One color per Terrain.Ground, blended over an item by its alpha; all zeros
// (the default) is no recolor.
uniform vec4 ground_recolor[5] : source_color;
uniform float wetness = 0.0;
uniform float snow_cover = 0.0;
// TerrainView's fire texture: R 0 unburnt, about 0.5 burning, 1 scorched; G 1
// while burning.
uniform sampler2D fire_state : hint_default_black, filter_nearest, repeat_disable;
uniform float cell_size = 1.0;
uniform vec2 sample_count = vec2(1.0, 1.0);
// 0: fire leaves it alone (pebbles). 1: gone once scorched (grass, plants).
// 2: a charred stump (bushes).
uniform int burn_mode = 0;
// Sway in model units at one model unit of height (it grows with the square
// of the height, so the base stays put).
uniform float wind = 0.0;
// Metres from the camera at which an item has shrunk away, and over how many
// metres before that it shrinks.
uniform float fade_end = 120.0;
uniform float fade_margin = 25.0;
// How far the lighting normal bends toward straight up, so thin blades and
// leaves light like the ground they grow from rather than flicker by facing.
uniform float normal_up = 0.0;

const vec3 CHAR = vec3(0.07, 0.06, 0.05);
const vec3 EMBER = vec3(0.85, 0.32, 0.07);
const vec3 SNOW = vec3(0.92, 0.94, 0.97);
const vec3 WET = vec3(0.66, 0.70, 0.76);
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
// fire_state's R above this is scorched (burning is about 0.5).
const float SCORCHED_R = 0.75;

varying vec4 v_recolor;
varying float v_burning;
varying float v_charred;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 camera = INV_VIEW_MATRIX[3].xyz;
	float fade = 1.0 - smoothstep(fade_end - fade_margin, fade_end, distance(origin, camera));

	ivec2 cell = ivec2(clamp(floor(origin.xz / cell_size + 0.5), vec2(0.0), sample_count - 1.0));
	vec2 fire = texelFetch(fire_state, cell, 0).rg;
	float scorched = step(SCORCHED_R, fire.r);
	float burning = fire.g;
	float keep = 1.0;
	v_burning = 0.0;
	v_charred = 0.0;
	if (burn_mode == 1) {
		keep = (1.0 - scorched) * (1.0 - 0.4 * burning);
		v_burning = burning;
	} else if (burn_mode == 2) {
		keep = 1.0 - 0.45 * max(scorched, burning);
		v_burning = burning;
		v_charred = scorched;
	}

	int ground = clamp(int(INSTANCE_CUSTOM.r * 255.0 + 0.5), 0, 4);
	v_recolor = ground_recolor[ground];

	float height = max(VERTEX.y, 0.0);
	float phase = TIME * 1.6 + origin.x * 0.31 + origin.z * 0.23;
	VERTEX.xz += vec2(sin(phase), 0.6 * sin(phase * 0.83 + 1.7)) * wind * height * height;
	VERTEX *= fade * keep;
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_up));
}

void fragment() {
	vec4 texel = texture(albedo_texture, UV);
	vec3 color = texel.rgb * albedo_color.rgb;
	color = mix(color, vec3(dot(color, LUMA)), kit_desaturation) * kit_tint.rgb;
	color = mix(color, v_recolor.rgb, v_recolor.a);
	color = mix(color, vec3(dot(color, LUMA)), grade_desaturation) * grade_tint.rgb;
	color = mix(color, CHAR, 0.85 * v_charred);
	color *= mix(vec3(1.0), WET, wetness);
	// NORMAL is in view space after every transform (the instance's too).
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	color = mix(color, SNOW, snow_cover * smoothstep(0.3, 0.8, abs(world_normal.y)) * (1.0 - v_burning));
	color = mix(color, EMBER, 0.6 * v_burning);
	EMISSION = EMBER * 0.4 * v_burning;
	ALBEDO = color;
	ALPHA = alpha_cutoff > 0.0 ? texel.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
}
