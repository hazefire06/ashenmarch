class_name Unit
extends SimEntity
## A soldier or monster: a SimEntity with a type, a side, hit points, a
## facing, a standing order, and what it is fighting. Commands give orders;
## MeleeCombat and UnitMovement carry them out each tick. Velocity is set by
## steering, so World._integrate moves it.

## What the unit is doing right now.
enum State {
	IDLE,
	## Walking an order's path, or chasing target_id when that is set.
	MOVING,
	## Engaged: its target is in reach and it stands, facing the target,
	## winding up or recovering between blows.
	ATTACKING,
	## Terminal. Dead units ignore orders, don't move, and don't push. The
	## body stays in the world for the rest of the mission.
	DEAD,
}

## The standing order, as opposed to the current activity (state).
enum Order {
	## Hold here and fight enemies that come adjacent, without straying far
	## from order_x/order_z.
	NONE,
	## Walk to the goal, ignoring enemies. Becomes NONE on arrival.
	MOVE,
	## Walk to the goal, fighting enemies met on the way and resuming after
	## each fight. Becomes NONE on arrival.
	ATTACK_MOVE,
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

var order: Order = Order.NONE
## ATTACK_MOVE: where the order ends, the facing there, and the group's speed
## cap, kept so the unit can resume after each fight. NONE: the spot the unit
## holds, which bounds how far it steps out to meet an enemy.
var order_x: int = 0
var order_z: int = 0
var order_facing_x: int = 0
var order_facing_z: int = -FixedMath.DIR_ONE
var order_speed_cap: int = 0
## Entity id of the unit being fought or chased; 0 for none (ids start at 1).
var target_id: int = 0
## Ticks until the swing in progress lands; 0 when not swinging.
var windup_left: int = 0
## Ticks until the next swing may start.
var cooldown_left: int = 0
## Enemies this unit has killed. Drives Veterancy; carries over between
## missions with the unit.
var kills: int = 0


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


## Kills the unit outright: hp 0, state DEAD, orders and fighting cleared.
func kill() -> void:
	hp = 0
	transition_to(State.DEAD)
	clear_order()
	clear_engagement()
	order = Order.NONE
	vx = 0
	vy = 0
	vz = 0


## Forgets the target and abandons any swing in progress. The cooldown keeps
## running, so a new order can't make the unit swing sooner.
func clear_engagement() -> void:
	target_id = 0
	windup_left = 0


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
		best_waypoint_distance, stuck_ticks,
		order, order_x, order_z, order_facing_x, order_facing_z, order_speed_cap,
		target_id, windup_left, cooldown_left, kills, path.size(),
	]))
	fields.append_array(path)
	return fields
