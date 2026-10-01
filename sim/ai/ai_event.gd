class_name AiEvent
extends RefCounted
## Something the AI did during a tick, for the view and for tests: a group
## appearing, changing behavior, being sent somewhere. Output only: World
## clears its list at the start of each step, nothing in the sim may read it,
## and events are never part of state_hash(). Determinism tests compare
## to_array() of every event instead.

## What happened. Fields not named for a kind are 0.
enum Kind {
	## A group spawned at (x, z) with `value` units.
	SPAWNED,
	## A group changed behavior; `value` is the AiGroupSpec.Behavior.
	BEHAVIOR,
	## A group (or one unit of it) was sent to (x, z).
	ORDER,
	## A patrolling group reached waypoint `value` at (x, z).
	WAYPOINT_REACHED,
	## A group couldn't reach a waypoint or leg goal; `value` is the waypoint
	## index, or -1 for a retry.
	WAYPOINT_FAILED,
	## An ambush sprang at (x, z) with `value` units.
	AMBUSH_SPRUNG,
	## A flank route was planned; (x, z) is waypoint number `value`.
	FLANK_WAYPOINT,
	## A ranged unit moved to a firing spot at (x, z).
	STANDOFF,
	## A group gave up and fell back toward (x, z).
	RETREAT,
}

var kind: Kind
var group_id: int
## The unit the event is about; 0 when it is about the whole group.
var unit_id: int = 0
var x: int = 0
var z: int = 0
var value: int = 0


func _init(
	event_kind: Kind, group: int, at_x: int = 0, at_z: int = 0, event_value: int = 0, unit: int = 0
) -> void:
	kind = event_kind
	group_id = group
	x = at_x
	z = at_z
	value = event_value
	unit_id = unit


## [kind, group_id, unit_id, x, z, value], the form determinism logs compare.
func to_array() -> PackedInt64Array:
	return PackedInt64Array([kind, group_id, unit_id, x, z, value])
