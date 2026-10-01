shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

// One flame per burning cell: a camera-facing quad with a procedural flame
// in the fragment shader (no textures). FireView writes the instances: the
// transform's origin is the point on the ground the flame stands on, and
// INSTANCE_CUSTOM is (phase, scale, 0, 0), both 0..1-ish values that survive
// the 16-bit packing of custom data in the Compatibility renderer.
//
// Added to what is behind it, so overlapping flames in a burning field build
// up from orange to yellow-white, and the order they are drawn in is moot.

// The flame's width and height in meters at scale 1.
uniform vec2 size = vec2(0.9, 1.2);
// Share of the flame's height its quad's middle is raised above the ground
// point. Under half, so the foot of the quad sinks into the ground a little.
uniform float lift = 0.45;
uniform float flicker_speed = 1.0;
uniform float brightness = 0.9;

// 0..1 across the quad and up it (0 at the foot, 1 at the tip).
varying vec2 v_uv;
varying float v_phase;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Smooth value noise, 0..1.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x),
		f.y);
}

void vertex() {
	float scale = INSTANCE_CUSTOM.y;
	v_phase = INSTANCE_CUSTOM.x;
	v_uv = VERTEX.xy + 0.5;
	vec3 anchor = MODEL_MATRIX[3].xyz + vec3(0.0, size.y * scale * lift, 0.0);
	vec3 anchor_view = (VIEW_MATRIX * vec4(anchor, 1.0)).xyz;
	VERTEX = anchor_view + vec3(VERTEX.xy * size * scale, 0.0);
}

void fragment() {
	float h = v_uv.y;
	float x = (v_uv.x - 0.5) * 2.0;
	// Each flame is out of step with its neighbors.
	float t = TIME * flicker_speed + v_phase * 31.0;

	// The flame leans and swings more toward its tip, and a band of noise
	// climbing it tears its edge.
	float sway = (vnoise(vec2(h * 1.5 - t * 0.6, v_phase * 17.0)) - 0.5) * 0.9 * h;
	float n = vnoise(vec2(x * 2.2 + v_phase * 11.0, h * 3.0 - t * 2.4));
	float width = mix(0.95, 0.1, pow(h, 1.3));
	float d = abs(x - sway) / width;
	float body = smoothstep(1.0, 0.3, d + (n - 0.5) * 0.7);
	float tip = smoothstep(1.0, 0.45, h + (n - 0.5) * 0.5);
	float a = body * tip * smoothstep(0.0, 0.12, h);

	// Hottest low and in the middle: yellow core, orange body, red edge and
	// tip. The noise moves the colors around inside the flame.
	float heat = clamp(1.15 - h * 1.1 - d * 0.55 + (n - 0.5) * 0.4, 0.0, 1.0);
	vec3 color = mix(vec3(0.85, 0.1, 0.02), vec3(1.0, 0.5, 0.05), smoothstep(0.1, 0.5, heat));
	color = mix(color, vec3(1.0, 0.9, 0.5), smoothstep(0.65, 0.95, heat));
	ALBEDO = color * brightness;
	ALPHA = a;
}
