shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform;

// Rain streaks and snow flakes, falling entirely on the GPU: one quad per
// particle in a MultiMesh, no per-frame work on the CPU per particle.
// PrecipitationView sets every uniform each frame.
//
// A particle's instance data is INSTANCE_CUSTOM: xyz is where it sits in the
// box, 0..1 on each axis, and w is a random phase. Custom data is packed to
// 16 bits in the Compatibility renderer, so it only ever holds values in
// 0..1 (a 60 m box is then good to about 3 cm), and the quad is placed from
// the uniforms alone: the instance transform is unused.
//
// The particle's world position falls with TIME and is wrapped into the box
// with mod() in WORLD space, relative to the box's corner. Moving the box
// with the camera therefore doesn't drag the weather along: a drop stays
// where it is in the world, and the box only decides which repeat of the
// pattern is drawn.

// Snow flakes (camera-facing discs that sway) instead of rain streaks.
uniform bool snow = false;
// The box: its lowest corner in world meters, and its size.
uniform vec3 box_origin = vec3(0.0);
uniform vec3 box_size = vec3(60.0, 30.0, 60.0);
// Wind in m/s, which tilts the rain's fall direction, and how far the wind
// has carried everything so far in meters. The view integrates the drift
// itself: making it TIME * wind would shove every particle by (change in
// wind) * TIME whenever the wind changed.
uniform vec2 wind = vec2(0.0);
uniform vec2 drift = vec2(0.0);
// Meters per second straight down.
uniform float fall_speed = 9.0;
uniform vec4 tint : source_color = vec4(0.7, 0.78, 0.9, 0.5);
// Rain: streak width and length in meters. Snow: flake size in x.
uniform vec2 size = vec2(0.03, 0.9);
// Particles never draw smaller than this many radians of view: at RTS
// distances a true-size drop would be a flicker under one pixel.
uniform vec2 min_angle = vec2(0.0025, 0.012);
// How far in from the box's faces particles fade out, so the wrap and the
// box's edge don't show: horizontally and vertically, meters.
uniform vec2 edge_fade = vec2(8.0, 5.0);
// Particles also fade out between these distances from the camera, meters:
// the camera often sits inside the box, and a drop a meter from the lens is
// a giant streak across the screen.
uniform vec2 near_fade = vec2(3.0, 10.0);

// Quad coordinates, -1..1 across and along; along grows toward the streak's
// head (down the fall direction).
varying vec2 v_local;
varying float v_fade;

void vertex() {
	vec3 unit = INSTANCE_CUSTOM.xyz;
	float phase = INSTANCE_CUSTOM.w;
	// Each particle falls a little faster or slower than the next.
	float speed = fall_speed * (0.75 + 0.5 * fract(phase * 17.0));

	vec3 motion = vec3(drift.x, -speed * TIME, drift.y);
	vec3 rel = mod(unit * box_size + motion - box_origin, box_size);
	vec3 center = box_origin + rel;
	if (snow) {
		// A flake wanders sideways a little as it falls.
		float t = TIME * 0.9 + phase * 40.0;
		center.xz += 0.35 * vec2(sin(t), cos(t * 0.83 + phase * 9.0));
	}

	vec3 from_edge = min(rel, box_size - rel);
	v_fade = clamp(min(min(from_edge.x / edge_fade.x, from_edge.z / edge_fade.x), from_edge.y / edge_fade.y), 0.0, 1.0);

	vec3 center_view = (VIEW_MATRIX * vec4(center, 1.0)).xyz;
	float dist = length(center_view);
	v_fade *= smoothstep(near_fade.x, near_fade.y, dist);
	v_local = vec2(VERTEX.x, -VERTEX.y) * 2.0;

	if (snow) {
		float flake = max(size.x, dist * min_angle.x * 1.8);
		VERTEX = center_view + vec3(VERTEX.xy * flake, 0.0);
	} else {
		float width = max(size.x, dist * min_angle.x);
		float len = max(size.y, dist * min_angle.y);
		// The streak lies along the fall direction as the camera sees it,
		// and is as wide as the camera can see it edge-on.
		vec3 fall_dir = normalize(vec3(wind.x, -speed, wind.y));
		vec3 axis = (VIEW_MATRIX * vec4(fall_dir * len, 0.0)).xyz;
		vec3 across = cross(axis, center_view);
		float across_len = length(across);
		// Looking straight along the fall leaves no "across"; any will do.
		across = across_len > 0.0001 ? across / across_len : vec3(1.0, 0.0, 0.0);
		VERTEX = center_view + axis * -VERTEX.y + across * VERTEX.x * width;
	}
}

void fragment() {
	ALBEDO = tint.rgb;
	if (snow) {
		ALPHA = tint.a * v_fade * smoothstep(1.0, 0.4, length(v_local));
	} else {
		// Soft across, and brightest at the head, fading back to the tail.
		float head = v_local.y * 0.5 + 0.5;
		ALPHA = tint.a * v_fade * smoothstep(1.0, 0.1, abs(v_local.x)) * smoothstep(0.0, 0.8, head);
	}
}
