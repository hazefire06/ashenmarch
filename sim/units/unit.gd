class_name Unit
extends SimEntity
## A soldier or monster: a SimEntity with a type, a side, hit points, a
## facing, and a movement order. UnitMovement drives it each tick; commands
## give it orders. Velocity is set by steering, so World._integrate moves it.

enum State {
	IDLE,
	MOVING,
	## Entered by combat in Phase 3; nothing enters it yet.
	ATTACKING,
	## Terminal. Dead units ignore orders, don't move, and don't push.
	DEAD,
}

## Bitmask of states each state may change to, indexed by State.
const _ALLOWED: Array[int] = [
	(1 << State.MOVING) | (1 << State.ATTACKING) | (1 << State.DEAD),
	(1 << State.IDLE) | (1 << State.ATTACKING) | (1 << State.DEAD),
	(1 << State.IDLE) | (1 << State.MOVING) | (1 << State.DEAD),
	0,
]

var type: UnitType
## Index of type in the world's UnitCatalog; hashed instead of the resource.
var type_index: int
var faction: UnitType.Faction
var state: State = State.IDLE
var hp: int
## Direction the unit faces, length FixedMath.DIR_ONE.
var facing_x: int = 0
var facing_z: int = -FixedMath.DIR_ONE

## Current order: where to end up and which way to face there.
var goal_x: int = 0
var goal_z: int = 0
var goal_facing_x: int = 0
var goal_facing_z: int = -FixedMath.DIR_ONE
## Milli-units per second the order may not exceed, so a group marches at its
## slowest member's pace. 0 means no cap.
var speed_cap: int = 0
## Remaining waypoints as x, z pairs in milli-units; the last is the goal.
var path: PackedInt64Array = PackedInt64Array()
## Index of the waypoint being walked to (pair index, not array index).
var path_index: int = 0
## True while waiting in UnitMovement's A* queue.
var path_pending: bool = false
## Movement numerator carried to the next tick, so speeds that aren't a whole
## number of milli-units per tick still average out exactly.
var move_carry: int = 0
## Closest the unit has come to its current waypoint, in milli-units, and
## ticks since that last improved. Measured per waypoint, not to the goal:
## walking along a bank to reach a ford moves away from the goal but is
## still progress.
var best_waypoint_distance: int = 0
var stuck_ticks: int = 0


func _init(
	entity_id: int, pos_x: int, pos_y: int, pos_z: int,
	unit_type: UnitType, catalog_index: int, side: UnitType.Faction
) -> void:
	super(entity_id, pos_x, pos_y, pos_z)
	type = unit_type
	type_index = catalog_index
	faction = side
	hp = unit_type.max_hp


func is_alive() -> bool:
	return state != State.DEAD


## Changes state if the transition is allowed. Returns whether it changed.
func transition_to(new_state: State) -> bool:
	if new_state == state:
		return true
	if _ALLOWED[state] & (1 << new_state) == 0:
		return false
	state = new_state
	return true


## Kills the unit outright: hp 0, state DEAD, order cleared.
func kill() -> void:
	hp = 0
	transition_to(State.DEAD)
	clear_order()
	vx = 0
	vy = 0
	vz = 0


## Drops the current path and goal bookkeeping. Does not change state.
func clear_order() -> void:
	path = PackedInt64Array()
	path_index = 0
	path_pending = false
	move_carry = 0
	speed_cap = 0
	stuck_ticks = 0
	best_waypoint_distance = 0


func has_path() -> bool:
	return path_index * 2 < path.size()


func waypoint_x() -> int:
	return path[path_index * 2]


func waypoint_z() -> int:
	return path[path_index * 2 + 1]


func is_last_waypoint() -> bool:
	return (path_index + 1) * 2 >= path.size()


func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = super()
	fields.append_array(PackedInt64Array([
		type_index, faction, state, hp, facing_x, facing_z,
		goal_x, goal_z, goal_facing_x, goal_facing_z, speed_cap,
		path_index, 1 if path_pending else 0, move_carry,
		best_waypoint_distance, stuck_ticks, path.size(),
	]))
	fields.append_array(path)
	return fields
