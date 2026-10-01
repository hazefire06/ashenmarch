shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

// Smoke over a burning cell: a big soft grey puff that rises, grows, and
// fades out, then starts again at the bottom. FireView writes the instances:
// the transform's origin is the ground point, INSTANCE_CUSTOM is (phase,
// size variation, 0, 0), where the phase keeps neighbors out of step.
//
// A puff's whole life is a function of TIME, so nothing is stored or
// updated per frame. The wind carries it sideways as it climbs.

// Seconds per loop, and meters climbed in one.
uniform float period = 4.0;
uniform float rise = 7.0;
// Meters above the ground a puff starts, and its size at birth and at death.
uniform float start_height = 0.8;
uniform vec2 size_range = vec2(1.6, 3.2);
// Wind in m/s (the weather's), and how much of it the smoke takes up.
uniform vec2 wind = vec2(0.0);
uniform float wind_share = 0.6;
uniform vec4 tint : source_color = vec4(0.32, 0.32, 0.34, 0.45);

varying vec2 v_local;
varying float v_life;
varying float v_phase;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

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
	v_phase = INSTANCE_CUSTOM.x;
	// 0 at birth, 1 at death.
	float life = fract(TIME / period + v_phase);
	v_life = life;
	v_local = VERTEX.xy * 2.0;
	vec3 anchor = MODEL_MATRIX[3].xyz + vec3(0.0, start_height + rise * life, 0.0);
	anchor.xz += wind * wind_share * life * period;
	vec3 anchor_view = (VIEW_MATRIX * vec4(anchor, 1.0)).xyz;
	float puff = mix(size_range.x, size_range.y, life) * INSTANCE_CUSTOM.y;
	VERTEX = anchor_view + vec3(VERTEX.xy * puff, 0.0);
}

void fragment() {
	float d = length(v_local);
	float n = vnoise(v_local * 1.6 + v_phase * 13.0 + vec2(0.0, -TIME * 0.3));
	// A lumpy disc with a soft edge.
	float puff = smoothstep(1.0, 0.25, d + (n - 0.5) * 0.5);
	// Quick to appear, slow to thin out.
	float fade = smoothstep(0.0, 0.12, v_life) * (1.0 - v_life);
	ALBEDO = tint.rgb * mix(0.7, 1.25, n);
	ALPHA = tint.a * puff * fade;
}
