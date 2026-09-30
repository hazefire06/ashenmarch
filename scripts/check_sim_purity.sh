#!/usr/bin/env bash
# Fails if sim/ breaks the determinism or sim/view separation rules in
# CLAUDE.md: no Nodes, no frame callbacks, no wall clock, no unseeded
# randomness, no Godot physics. Comment lines are ignored.
set -euo pipefail
cd "$(dirname "$0")/.."

patterns=(
	'extends[[:space:]]+Node'
	'get_tree\(|get_node\('
	'_(physics_)?process\('
	'Time\.|OS\.get_ticks|OS\.get_unix_time'
	'(^|[^.[:alnum:]_])(randf|randi|randf_range|randi_range|randfn|randomize|seed)\('
	'PhysicsServer[23]D|RigidBody[23]D|CharacterBody[23]D|Area[23]D'
)

status=0
for pattern in "${patterns[@]}"; do
	hits=$(grep -rnE --include='*.gd' "$pattern" sim/ | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
	if [[ -n "$hits" ]]; then
		echo "sim purity violation (/$pattern/):"
		echo "$hits"
		status=1
	fi
done

if [[ $status -eq 0 ]]; then
	echo "sim purity: ok"
fi
exit $status
