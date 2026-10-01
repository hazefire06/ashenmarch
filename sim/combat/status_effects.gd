class_name StatusEffects
extends RefCounted
## Timed effects on units, run by World.step() after the weather and before
## melee, so a unit paralyzed this tick neither swings, shoots, nor walks.
##
## A unit keeps, per kind, the last tick it is affected (Unit.status_until;
## NONE when it isn't). apply() extends that, never shortens it, so effects
## refresh rather than stack. A unit is affected on every tick up to and
## including that one.
## - PARALYSIS: no walking, turning, swinging, shooting, casting, or errands;
##   a wind-up in progress is lost and a shield can't block. Blasts and
##   crowding still push the unit.
## - CONFUSION: the unit fights the nearest unit of either side, whatever its
##   order, without its role preferences, hold leash, or care for friends.
##   Orders given meanwhile are kept; when it wears off the unit drops the
##   fight and carries on with its order (UnitOrders.resume).
## - BURNING: BURN_DAMAGE every BURN_INTERVAL_TICKS (on the world's tick, not
##   the unit's), credited to whoever set it alight (Unit.burn_credit_id, the
##   latest source). Standing on a burning cell keeps it lit (Fire), and it
##   burns on FIRE_BURN_TICKS after stepping off; water of depth 1 or more
##   puts it out.
##
## Update, per tick: first every gas cloud, in ascending id, paralyzes the
## living units in it (GasCloud.contains) and counts down, the last of its
## ticks flagging it spent; then, units in ascending id: wear-offs (a
## confusion that ended last tick resumes the unit's order), water douses,
## and burn damage on its interval. No randomness.

enum Kind {
	PARALYSIS,
	CONFUSION,
	BURNING,
}

## Status timers hold this when the unit isn't affected.
const NONE: int = -1
## Hit points Burning takes every BURN_INTERVAL_TICKS: 9 hp/s, the rate fire
## has burned at since Phase 5.
const BURN_DAMAGE: int = 3
const BURN_INTERVAL_TICKS: int = 10
## Ticks a unit keeps burning after it was last on a burning cell (2 s).
const FIRE_BURN_TICKS: int = 60
## Ticks a fire arrow sets the unit it strikes burning (5 s).
const FIRE_ARROW_BURN_TICKS: int = 150


func update(world: World) -> void:
	_gas(world)
	var ended: int = world.tick - 1
	var burn_tick: bool = world.tick % BURN_INTERVAL_TICKS == 0
	for unit: Unit in world.units:
		if not unit.is_alive():
			continue
		if unit.status_until[Kind.CONFUSION] == ended and ended >= 0:
			UnitOrders.resume(world, unit)
		if not has(world, unit, Kind.BURNING):
			continue
		if world.terrain.water_depth_at(unit.x, unit.z) > 0:
			unit.status_until[Kind.BURNING] = NONE
		elif burn_tick:
			Damage.apply(world, unit, BURN_DAMAGE, unit.x, unit.z, unit.burn_credit_id)


func _gas(world: World) -> void:
	for cloud: GasCloud in world.clouds:
		if cloud.removed:
			continue
		for unit: Unit in world.units:
			if unit.is_alive() and cloud.contains(unit):
				apply(world, unit, Kind.PARALYSIS, cloud.paralysis_ticks, cloud.instigator_id)
		cloud.ticks_left -= 1
		if cloud.ticks_left <= 0:
			cloud.removed = true


## Affects unit with kind for ticks more ticks, counting the current one,
## unless it is already affected for longer. source_id is credited with what a
## Burning does (the latest source wins). Dead units are left alone.
static func apply(world: World, unit: Unit, kind: Kind, ticks: int, source_id: int) -> void:
	if not unit.is_alive() or ticks <= 0:
		return
	unit.status_until[kind] = maxi(unit.status_until[kind], world.tick + ticks - 1)
	if kind == Kind.BURNING:
		unit.burn_credit_id = source_id


## Ends every effect on the unit now (a healing herb). A confused unit goes
## back to its order at once.
static func cure(world: World, unit: Unit) -> void:
	var was_confused: bool = has(world, unit, Kind.CONFUSION)
	clear(unit)
	if was_confused and unit.is_alive():
		UnitOrders.resume(world, unit)


## Drops every effect without side effects (death).
static func clear(unit: Unit) -> void:
	unit.status_until.fill(NONE)
	unit.burn_credit_id = 0


## True if the unit is affected by kind on the current tick.
static func has(world: World, unit: Unit, kind: Kind) -> bool:
	return unit.status_until[kind] >= world.tick


static func paralyzed(world: World, unit: Unit) -> bool:
	return unit.status_until[Kind.PARALYSIS] >= world.tick


static func confused(world: World, unit: Unit) -> bool:
	return unit.status_until[Kind.CONFUSION] >= world.tick


## Ticks the unit is still affected by kind, counting the current one; 0 if
## it isn't.
static func ticks_left(world: World, unit: Unit, kind: Kind) -> int:
	return maxi(0, unit.status_until[kind] - world.tick + 1)
