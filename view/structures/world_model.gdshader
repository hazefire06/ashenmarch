shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// The one material every structure model shares (StructuresView builds one
// per kit surface from its StandardMaterial3D's albedo texture and colour).
// It does to a model what terrain.gdshader does to the ground, in the same
// order: the mission's grade, the fire on the structure's samples, wetness,
// snow on faces that point up, and a glow while it burns. Every uniform but
// the albedo defaults to "no change".

uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// grade_tint multiplies the model (white changes nothing) and
// grade_desaturation drains it toward its own gray (0 changes nothing).
uniform vec4 grade_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float grade_desaturation = 0.0;
// How wet everything is and how much snow lies on it, 0..1.
uniform float wetness = 0.0;
uniform float snow_cover = 0.0;
// The share of the structure's samples burning and burnt out, 0..1.
uniform float burning = 0.0;
uniform float charred = 0.0;

// The ground's colours (terrain.gdshader), so a burnt house matches its yard.
const vec3 CHAR = vec3(0.07, 0.06, 0.05);
const vec3 EMBER = vec3(0.85, 0.32, 0.07);
const vec3 SNOW = vec3(0.92, 0.94, 0.97);
const vec3 WET = vec3(0.66, 0.70, 0.76);
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

void fragment() {
	vec3 color = texture(albedo_texture, UV).rgb * albedo_color.rgb;
	color = mix(color, vec3(dot(color, LUMA)), grade_desaturation) * grade_tint.rgb;
	color = mix(color, CHAR, 0.85 * charred);
	color *= mix(vec3(1.0), WET, wetness);
	// NORMAL is in view space after every transform (a multimesh instance's
	// too), so this is the face's world normal.
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// A burning structure melts its own snow.
	color = mix(color, SNOW, snow_cover * smoothstep(0.55, 0.85, world_normal.y) * (1.0 - burning));
	// Flames flicker unevenly across the model, out of step from place to place.
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float flicker = 0.7 + 0.3 * sin(TIME * 11.0 + world_pos.x * 1.7) * sin(TIME * 7.3 + world_pos.z * 2.3 + world_pos.y);
	color = mix(color, EMBER, 0.6 * burning);
	EMISSION = EMBER * 0.5 * burning * flicker;
	ALBEDO = color;
}
