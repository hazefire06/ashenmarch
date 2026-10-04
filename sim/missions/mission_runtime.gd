class_name MissionRuntime
extends RefCounted
## A mission in progress: which triggers have fired, the current objective, and
## the outcome. MissionScript is the read-only data; this is the state it
## drives, so it lives in the world and its progress is hashed. update() runs
## once a tick inside World.step(), before the AI, so what a trigger spawns or
## switches is there for the AI the same tick.
##
## Conditions are all checked before any trigger fires, so one trigger's
## effects never make another fire on the same tick, and a trigger gated by
## `after` opens the tick after its prerequisite fired, never the same tick.

## How the mission ended, if it has.
enum Outcome {
	## Still being played.
	NONE,
	## A WIN action fired (and no LOSE on the same tick).
	WON,
	## A LOSE action fired.
	LOST,
}

## The data this runs. Read-only, and not hashed: it never changes. (Not named
## `script`: RefCounted already has a member by that name.)
var mission_script: MissionScript
## The difficulty tier it is played at, 0..Difficulty.TIERS - 1.
var tier: int
## The tick the mission started on; TIMERs without `after` count from it.
var start_tick: int
## True once the groups marked spawn_at_start have spawned (the first update).
var started: bool = false
## The tick each trigger fired on, indexed like MissionScript.triggers; -1 for
## one that hasn't.
var fired_tick: PackedInt64Array = PackedInt64Array()
## One bit per faction (1 << faction) that has had a living unit since the
## mission started. FACTION_ELIMINATED needs it, so a side that never existed
## isn't eliminated by default.
var seen_factions: int = 0
## What the player is told to do. Display only, so not hashed; the trigger and
## revision that set it are, and they change whenever the text does.
var objective: String = ""
## The trigger that set the objective, or -1 for none yet.
var objective_trigger: int = -1
## Counts objective changes, so the HUD can tell a re-set of the same text.
var objective_revision: int = 0
## How it ended; NONE while it is still being played. Once it isn't NONE no
## trigger is evaluated again.
var outcome: Outcome = Outcome.NONE
## The tick the outcome was decided on, or -1.
var outcome_tick: int = -1

# Per trigger: the index its `after` names, or -1. Resolved once, because
# names are looked up by scanning.
var _after: PackedInt32Array = PackedInt32Array()


func _init(data: MissionScript, mission_tier: int, at_tick: int) -> void:
	mission_script = data
	tier = mission_tier
	start_tick = at_tick
	fired_tick.resize(mission_script.triggers.size())
	fired_tick.fill(-1)
	_after.resize(mission_script.triggers.size())
	for i: int in mission_script.triggers.size():
		var after: StringName = mission_script.triggers[i].after
		_after[i] = mission_script.trigger_index(after) if after != &"" else -1


## One tick of the mission: spawn the starting groups the first time, then fire
## every trigger that is due. Does nothing once the mission has an outcome.
func update(world: World) -> void:
	if outcome != Outcome.NONE:
		return
	if not started:
		for i: int in mission_script.groups.size():
			if mission_script.groups[i].spawn_at_start:
				world.ai.spawn_group(world, mission_script.groups[i], i, tier)
		started = true
	_see_factions(world)
	var due: Array[int] = []
	for i: int in mission_script.triggers.size():
		if fired_tick[i] < 0 and _is_active(i, world) and _holds(i, world):
			due.append(i)
	var win_trigger: int = -1
	var lose_trigger: int = -1
	for i: int in due:
		fired_tick[i] = world.tick
		world.mission_events.append(MissionEvent.new(MissionEvent.Kind.TRIGGER_FIRED, i))
		for action: TriggerAction in mission_script.triggers[i].actions:
			match action.kind:
				TriggerAction.Kind.WIN:
					if win_trigger < 0:
						win_trigger = i
				TriggerAction.Kind.LOSE:
					if lose_trigger < 0:
						lose_trigger = i
				_:
					_apply(world, i, action)
	# A defeat outranks a victory won on the same tick.
	if lose_trigger >= 0:
		outcome = Outcome.LOST
		world.mission_events.append(MissionEvent.new(MissionEvent.Kind.LOST, lose_trigger))
	elif win_trigger >= 0:
		outcome = Outcome.WON
		world.mission_events.append(MissionEvent.new(MissionEvent.Kind.WON, win_trigger))
	if outcome != Outcome.NONE:
		outcome_tick = world.tick


## Everything the mission keeps, for state_hash().
func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = PackedInt64Array([
		tier, start_tick, int(started), seen_factions, objective_trigger, objective_revision,
		outcome, outcome_tick, fired_tick.size(),
	])
	fields.append_array(fired_tick)
	return fields


func _see_factions(world: World) -> void:
	for unit: Unit in world.units:
		if unit.is_alive():
			seen_factions |= 1 << unit.faction


# A trigger is active once the one it waits for has fired on an earlier tick.
func _is_active(index: int, world: World) -> bool:
	var after: int = _after[index]
	return after < 0 or (fired_tick[after] >= 0 and fired_tick[after] < world.tick)


func _holds(index: int, world: World) -> bool:
	var t: TriggerSpec = mission_script.triggers[index]
	match t.condition:
		TriggerSpec.Condition.AREA_ENTERED:
			return _units_inside(world, t) >= t.min_count
		TriggerSpec.Condition.UNIT_DIES:
			return _deaths(world, t) >= t.count
		TriggerSpec.Condition.TIMER:
			var activation: int = start_tick if _after[index] < 0 else fired_tick[_after[index]] + 1
			return world.tick >= activation + Difficulty.pick(t.ticks, tier)
		TriggerSpec.Condition.GROUP_CLEARED:
			return _cleared(world, t)
		TriggerSpec.Condition.FACTION_ELIMINATED:
			return (seen_factions & (1 << t.faction)) != 0 and not _any_alive(world, t.faction)
	return false


# Living units of t.faction within t.area's radius of its center.
func _units_inside(world: World, t: TriggerSpec) -> int:
	var radius: int = t.area[2]
	var count: int = 0
	for unit: Unit in world.units:
		if not unit.is_alive() or unit.faction != t.faction:
			continue
		var dx: int = unit.x - t.area[0]
		var dz: int = unit.z - t.area[1]
		if dx * dx + dz * dz <= radius * radius:
			count += 1
	return count


# Deaths among every unit the named groups ever had.
func _deaths(world: World, t: TriggerSpec) -> int:
	var count: int = 0
	for group: AiGroup in _groups_named(world, t):
		for unit_id: int in group.spawned_ids:
			if not _is_standing(world, unit_id):
				count += 1
	return count


# Every named group has spawned, and none of the units any of them had is
# still standing.
func _cleared(world: World, t: TriggerSpec) -> bool:
	for group_name: StringName in t.names:
		if world.ai.groups_of(mission_script.group_index(group_name)).is_empty():
			return false
	for group: AiGroup in _groups_named(world, t):
		for unit_id: int in group.spawned_ids:
			if _is_standing(world, unit_id):
				return false
	return true


# The spawned groups of the specs t names, each spec once however often the
# list repeats it.
func _groups_named(world: World, t: TriggerSpec) -> Array[AiGroup]:
	var out: Array[AiGroup] = []
	for i: int in t.names.size():
		if t.names.find(t.names[i]) == i:
			out.append_array(world.ai.groups_of(mission_script.group_index(t.names[i])))
	return out


func _is_standing(world: World, unit_id: int) -> bool:
	var unit: Unit = world.get_unit(unit_id)
	return unit != null and unit.is_alive()


func _any_alive(world: World, side: UnitType.Faction) -> bool:
	for unit: Unit in world.units:
		if unit.is_alive() and unit.faction == side:
			return true
	return false


func _apply(world: World, index: int, action: TriggerAction) -> void:
	match action.kind:
		TriggerAction.Kind.SPAWN_GROUP:
			var group_index: int = mission_script.group_index(action.group)
			world.ai.spawn_group(world, mission_script.groups[group_index], group_index, tier)
		TriggerAction.Kind.SET_WEATHER:
			var w: WeatherChange = action.weather
			world.weather.change_to(
				world.tick, w.rain, w.snow, w.wind_x, w.wind_z, w.ramp_ticks, w.snow_cover
			)
		TriggerAction.Kind.SET_OBJECTIVE:
			objective = action.text
			objective_trigger = index
			objective_revision += 1
			world.mission_events.append(MissionEvent.new(MissionEvent.Kind.OBJECTIVE, index, action.text))
		TriggerAction.Kind.SET_BEHAVIOR:
			for group: AiGroup in world.ai.groups_of(mission_script.group_index(action.group)):
				world.ai.set_behavior(world, group, action.behavior)
