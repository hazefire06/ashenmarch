class_name MissionStats
extends RefCounted
## The numbers behind a mission's results screen: how long it took, who was
## lost and to whom, what each soldier killed, and which enemies fell. An
## observer, not sim state: it only reads a World, never changes one, and is
## not hashed, so it can't affect determinism. Whatever runs the world (the
## view's loop, or a headless playtest) drives it:
##   step the world once (the deploy command applies on that first tick),
##   begin(world); then, after every step, observe(world); at the end,
##   finish(world).
## observe() must see every step: World clears its combat events at the start
## of each one.
##
## Friendly fire is judged from the KILL events (CombatEvent): a soldier whose
## killer was on his own side, himself included, or whose death was credited to
## no one (a stray charge, fire nobody lit, a burn after a herb cleared its
## credit) died to friendly fire. The rest of the numbers are read from the
## world at the end, where bodies persist.

## The tick the mission ended on (the world's tick when finish() ran), so also
## how many ticks were simulated.
var end_tick: int = 0
## Enemies dead by their unit type id: every dead Dark unit that isn't a
## campaign soldier (one who was converted and then died is ours to mourn, not
## a kill).
var enemy_dead: Dictionary[StringName, int] = {}
## Soldier ids lost: dead, or no longer on the Light side (converted), in the
## order the world holds their units.
var lost: PackedInt32Array = PackedInt32Array()
## Soldier ids of the victims of friendly fire, in the order they died. Always
## a subset of `lost` once finish() has run.
var friendly_fire: PackedInt32Array = PackedInt32Array()
## Kills each deployed soldier made this mission (what he ended with minus what
## he deployed with), by soldier id, the lost included.
var soldier_kills: Dictionary[int, int] = {}

# Kills each Light soldier had when begin() ran, by soldier id.
var _deploy_kills: Dictionary[int, int] = {}


## Starts over from this world: remembers the kills every Light campaign
## soldier deployed with. Call it after the first step, when the deploy has
## applied.
func begin(world: World) -> void:
	end_tick = 0
	enemy_dead.clear()
	lost.clear()
	friendly_fire.clear()
	soldier_kills.clear()
	_deploy_kills.clear()
	for unit: Unit in world.units:
		if unit.soldier_id != 0 and unit.faction == UnitType.Faction.LIGHT:
			_deploy_kills[unit.soldier_id] = unit.kills


## Reads the KILL events of the step that just ran.
func observe(world: World) -> void:
	for event: CombatEvent in world.combat_events:
		if event.kind != CombatEvent.Kind.KILL:
			continue
		var victim: Unit = world.get_unit(event.target_id)
		if victim == null or victim.soldier_id == 0 or victim.faction != UnitType.Faction.LIGHT:
			continue
		var killer: Unit = world.get_unit(event.attacker_id)
		var own_side: bool = killer == null or killer.faction == victim.faction
		if own_side and not friendly_fire.has(victim.soldier_id):
			friendly_fire.append(victim.soldier_id)


## Closes the mission: records the end tick and reads the world once for the
## rest of the numbers. Can be called again to refresh them.
func finish(world: World) -> void:
	end_tick = world.tick
	enemy_dead.clear()
	lost.clear()
	soldier_kills.clear()
	for unit: Unit in world.units:
		if unit.soldier_id != 0:
			soldier_kills[unit.soldier_id] = unit.kills - _deploy_kills.get(unit.soldier_id, unit.kills)
			if not unit.is_alive() or unit.faction != UnitType.Faction.LIGHT:
				lost.append(unit.soldier_id)
		elif unit.faction == UnitType.Faction.DARK and not unit.is_alive():
			enemy_dead[unit.type.id] = enemy_dead.get(unit.type.id, 0) + 1


## How many enemies are dead, of every type.
func enemies_killed() -> int:
	var total: int = 0
	for type_id: StringName in enemy_dead:
		total += enemy_dead[type_id]
	return total


## Kills this soldier made this mission; 0 for one who wasn't there.
func kills_of(soldier_id: int) -> int:
	return soldier_kills.get(soldier_id, 0)


## The mission's length in whole seconds.
func seconds() -> int:
	# Whole seconds are the point, so the remainder is dropped on purpose.
	@warning_ignore("integer_division")
	var whole: int = end_tick / World.TICK_RATE
	return whole


## True if this soldier was lost: dead, or no longer on the Light side.
func was_lost(soldier_id: int) -> bool:
	return lost.has(soldier_id)


## True if this soldier died to friendly fire (see the class comment).
func was_friendly_fire(soldier_id: int) -> bool:
	return friendly_fire.has(soldier_id)
