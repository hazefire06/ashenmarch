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
	## An escort stopped where it stands, (x, z) the members' centroid, because
	## its friend fell behind or an enemy came near; `value` is the index of
	## the waypoint it was walking to.
	ESCORT_WAIT,
	## An escort set off again toward waypoint `value`, at (x, z).
	ESCORT_GO,
	## A skirmish commander thought (SkirmishCommander): group_id is its main
	## group, (x, z) its objective, `value` its Posture, and unit_id the
	## objective flag's index + 1 (0 when the objective is a point).
	COMMANDER,
}

## What happened.
var kind: Kind
## The AiGroup it happened to.
var group_id: int
## The unit the event is about; 0 when it is about the whole group.
var unit_id: int = 0
## Where, in milli-units, as the kind says; 0 when the kind names no place.
var x: int = 0
## See x.
var z: int = 0
## A count, index, behavior or flag, as the kind says.
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
