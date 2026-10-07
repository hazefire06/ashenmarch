#!/usr/bin/env bash
# Fails if sim/ breaks the determinism or sim/view separation rules in
# CLAUDE.md: no Nodes, no frame callbacks, no wall clock, no unseeded
# randomness, no Godot physics, no transcendental float math (libm differs in
# the last bit between platforms; use FixedMath), and no float vectors (use
# ints or Vector2i). Also fails if the enemy AI, the mission triggers, or a
# skirmish's scoring (sim/ai, sim/missions, sim/skirmish) touch the world's
# seeded RNG at all: they draw no random numbers, so their choices follow from
# sim state alone and the RNG draw-order tables in docs/architecture.md stay
# valid. Comment lines are ignored.
#
# Phase 10 added the float rules: no float type or cast, no float rounding,
# interpolation or float-only math functions, no float literals or constants
# (INF, NAN, PI, TAU), no float-based Godot types (Basis, Transform*, Quaternion,
# Rect2, AABB, Plane, Projection, Color, PackedFloat*Array), and no float RNG
# calls on any generator. A line that must break one of these, and is safe,
# says why with an inline "# purity-ok: <reason>"; the marker exempts a line
# from the float rules only, never from the others.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
	'extends[[:space:]]+Node'
	'get_tree\(|get_node\('
	'_(physics_)?process\('
	'Time\.|OS\.get_ticks|OS\.get_unix_time'
	'(^|[^.[:alnum:]_])(randf|randi|randf_range|randi_range|randfn|randomize|seed)\('
	'PhysicsServer[23]D|RigidBody[23]D|CharacterBody[23]D|Area[23]D'
	'(^|[^.[:alnum:]_])(sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|exp|log|pow)\('
	'(^|[^[:alnum:]_])Vector[234]([^i[:alnum:]]|$)'
)

float_patterns=(
	'(^|[^[:alnum:]_])float([^[:alnum:]_]|$)'
	'(^|[^.[:alnum:]_])(sqrt|floor|ceil|round|lerp|snapped|floorf|ceilf|roundf|floori|ceili|roundi|lerpf|snappedf|snappedi|fmod|fposmod|absf|signf|minf|maxf|clampf|inverse_lerp|remap|smoothstep|move_toward|deg_to_rad|rad_to_deg|is_equal_approx|is_zero_approx)\('
	'(^|[^[:alnum:]_])(Basis|Transform2D|Transform3D|Quaternion|AABB|Plane|Projection|Color|PackedFloat32Array|PackedFloat64Array)([^[:alnum:]_]|$)'
	'(^|[^[:alnum:]_])Rect2([^i[:alnum:]_]|$)'
	'\.(randf|randf_range|randfn)\('
	'(^|[^[:alnum:]_])(INF|NAN|PI|TAU)([^[:alnum:]_]|$)'
	'(^|[^[:alnum:]_.%"])[0-9]+\.[0-9]+'
)

status=0
for pattern in "${float_patterns[@]}"; do
	hits=$(grep -rnE --include='*.gd' "$pattern" sim/ | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '# purity-ok:' || true)
	if [[ -n "$hits" ]]; then
		echo "sim purity violation (float rule /$pattern/; add '# purity-ok: <reason>' only if it is safe):"
		echo "$hits"
		status=1
	fi
done

for pattern in "${patterns[@]}"; do
	hits=$(grep -rnE --include='*.gd' "$pattern" sim/ | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
	if [[ -n "$hits" ]]; then
		echo "sim purity violation (/$pattern/):"
		echo "$hits"
		status=1
	fi
done

rng_pattern='(^|[^[:alnum:]_])rng([^[:alnum:]_]|$)'
hits=$(grep -rnE --include='*.gd' "$rng_pattern" sim/ai/ sim/missions/ sim/skirmish/ | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [[ -n "$hits" ]]; then
	echo "sim purity violation (sim/ai, sim/missions and sim/skirmish draw no random numbers; /$rng_pattern/):"
	echo "$hits"
	status=1
fi

if [[ $status -eq 0 ]]; then
	echo "sim purity: ok"
fi
exit $status
