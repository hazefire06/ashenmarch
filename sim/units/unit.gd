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
	## Ranged: stands facing shot_target_id (or its ground target), drawing
	## or recovering between shots. Appended so earlier values keep theirs.
	SHOOTING,
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
	## Ranged units: bombard (ground_x, ground_z), walking into range first if
	## needed, until given another order.
	GROUND_ATTACK,
}

## Bitmask of states each state may change to, indexed by State. Every live
## state can reach DEAD; kill() relies on it.
const _ALLOWED: Array[int] = [
	# IDLE
	(1 << State.MOVING) | (1 << State.ATTACKING) | (1 << State.SHOOTING) | (1 << State.DEAD),
	# MOVING
	(1 << State.IDLE) | (1 << State.ATTACKING) | (1 << State.SHOOTING) | (1 << State.DEAD),
	# ATTACKING
	(1 << State.IDLE) | (1 << State.MOVING) | (1 << State.SHOOTING) | (1 << State.DEAD),
	# DEAD
	0,
	# SHOOTING
	(1 << State.IDLE) | (1 << State.MOVING) | (1 << State.ATTACKING) | (1 << State.DEAD),
]

## Milli-units per tick of knockback (1 m/s) at or above which the unit is
## reeling.
const KNOCKED_SPEED: int = 1000 / 30

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

## GROUND_ATTACK: the spot being bombarded.
var ground_x: int = 0
var ground_z: int = 0
## GROUND_ATTACK: the unit has already walked toward the spot to get in
## range, so finding itself stopped and still unable to reach it means it
## never will.
var ground_walked: bool = false
## Entity id of the unit being shot at; 0 for none.
var shot_target_id: int = 0
## Ticks until the shot being drawn leaves; 0 when not drawing.
var aim_left: int = 0
## Ticks until the next draw may start.
var shot_cooldown_left: int = 0
## Shots left this mission; -1 is unlimited.
var ammo_left: int = 0
## Special uses left this mission (satchels, the fire arrow).
var special_left: int = 0
## FIRE_ARROW special: the next shot is the fire arrow.
var fire_nocked: bool = false
## Knockback from blasts, milli-units per tick. UnitMovement adds it to the
## unit's velocity and bleeds it off; while it is fast the unit is reeling
## and can't steer, swing, or shoot.
var knock_vx: int = 0
var knock_vz: int = 0


func _init(
	entity_id: int, pos_x: int, pos_y: int, pos_z: int,
	unit_type: UnitType, catalog_index: int, side: UnitType.Faction
) -> void:
	super(entity_id, pos_x, pos_y, pos_z)
	type = unit_type
	type_index = catalog_index
	faction = side
	hp = unit_type.max_hp
	ammo_left = unit_type.ranged_ammo
	special_left = unit_type.special_charges


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
## A body lies on the ground, so UnitMovement drops a floating one.
func kill() -> void:
	hp = 0
	transition_to(State.DEAD)
	clear_order()
	clear_engagement()
	clear_shot()
	order = Order.NONE
	vx = 0
	vy = 0
	vz = 0
	knock_vx = 0
	knock_vz = 0


## Forgets the target and abandons any swing in progress. The cooldown keeps
## running, so a new order can't make the unit swing sooner.
func clear_engagement() -> void:
	target_id = 0
	windup_left = 0


## Forgets the ranged target and abandons any draw in progress. The shot
## cooldown keeps running.
func clear_shot() -> void:
	shot_target_id = 0
	aim_left = 0


## True while a blast's knockback is still throwing the unit: it can't
## steer, swing, or shoot until it slows below KNOCKED_SPEED.
func is_reeling() -> bool:
	return knock_vx * knock_vx + knock_vz * knock_vz >= KNOCKED_SPEED * KNOCKED_SPEED


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
		ground_x, ground_z, 1 if ground_walked else 0, shot_target_id, aim_left, shot_cooldown_left,
		ammo_left, special_left, 1 if fire_nocked else 0, knock_vx, knock_vz,
	]))
	fields.append_array(path)
	return fields
