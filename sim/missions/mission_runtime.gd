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
## A TRIGGERS_FIRED link works the same way.
##
## Every name a trigger or action uses for a group is resolved once, in _init:
## to the group's index, or, for an alias (a MissionDraw slot), to the group the
## roll bound to it. After that nothing here looks at a name.

## How the mission ended, if it has.
enum Outcome {
	## Still being played.
	NONE,
	## A WIN action fired (and no LOSE on the same tick).
	WON,
	## A LOSE action fired.
	LOST,
}

## Where an objective stands. Append only: the states are hashed.
enum ObjectiveState {
	## Not on the player's list yet (shown_at_start false, or not shown since).
	HIDDEN,
	## On the list, to be done.
	ACTIVE,
	## Done. Final.
	DONE,
	## Failed. Final.
	FAILED,
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
## Like seen_factions, but only for units the AI didn't spawn (the ones a player
## commands). PLAYER_ELIMINATED needs it, so it doesn't fire on tick 0 in a
## mission whose player units arrive later.
var seen_commanded: int = 0
## The group bound to each draw slot: for each draw in order, for each slot in
## order, the group's index in MissionScript.groups. Rolled by World at the
## start (World.roll_bindings), so a replay rolls the same one; hashed.
var bindings: PackedInt32Array = PackedInt32Array()
## Each objective's ObjectiveState, indexed like MissionScript.objectives.
## Hashed. The objective text is display only (MissionScript) and isn't.
var objective_states: PackedInt32Array = PackedInt32Array()
## The mission's message line (SET_OBJECTIVE), shown above the objective list.
## Display only, so not hashed; the trigger and revision that set it are, and
## they change whenever the text does.
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
# Per trigger: its `names`, resolved. For TRIGGERS_FIRED these are trigger
# indices, for AREA_ENTERED, UNIT_DIES and GROUP_CLEARED group indices (an alias
# through the bindings); a name that resolves to nothing is -1. Empty for the
# other conditions, which don't read names.
var _names: Array[PackedInt32Array] = []
# Per trigger, per action: the group index SPAWN_GROUP and SET_BEHAVIOR act on,
# or the objective index the objective kinds act on; -1 for any other kind.
var _targets: Array[PackedInt32Array] = []


func _init(
	data: MissionScript, mission_tier: int, at_tick: int, rolled_bindings: PackedInt32Array
) -> void:
	mission_script = data
	tier = mission_tier
	start_tick = at_tick
	bindings = rolled_bindings
	fired_tick.resize(mission_script.triggers.size())
	fired_tick.fill(-1)
	objective_states.resize(mission_script.objectives.size())
	for i: int in mission_script.objectives.size():
		objective_states[i] = (
			ObjectiveState.ACTIVE if mission_script.objectives[i].shown_at_start else ObjectiveState.HIDDEN
		)
	_after.resize(mission_script.triggers.size())
	for i: int in mission_script.triggers.size():
		var t: TriggerSpec = mission_script.triggers[i]
		_after[i] = mission_script.trigger_index(t.after) if t.after != &"" else -1
		_names.append(_resolve_names(t))
		var targets: PackedInt32Array = PackedInt32Array()
		for action: TriggerAction in t.actions:
			targets.append(_resolve_target(action))
		_targets.append(targets)


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
		var actions: Array[TriggerAction] = mission_script.triggers[i].actions
		for a: int in actions.size():
			match actions[a].kind:
				TriggerAction.Kind.WIN:
					if win_trigger < 0:
						win_trigger = i
				TriggerAction.Kind.LOSE:
					if lose_trigger < 0:
						lose_trigger = i
				_:
					_apply(world, i, a)
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
	fields.append(bindings.size())
	for bound: int in bindings:
		fields.append(bound)
	fields.append(objective_states.size())
	for state: int in objective_states:
		fields.append(state)
	fields.append(seen_commanded)
	return fields


## How many objectives the mission has.
func objective_count() -> int:
	return mission_script.objectives.size()


## What objective `i` says, for the panel. Display only.
func objective_text(i: int) -> String:
	return mission_script.objectives[i].text


## Where objective `i` stands.
func objective_state(i: int) -> ObjectiveState:
	return objective_states[i] as ObjectiveState


## Whether the player can win without objective `i`: the panel says so.
func objective_optional(i: int) -> bool:
	return mission_script.objectives[i].optional


func _see_factions(world: World) -> void:
	for unit: Unit in world.units:
		if unit.is_alive():
			seen_factions |= 1 << unit.faction
			if not world.ai.controls(unit.id):
				seen_commanded |= 1 << unit.faction


# A trigger is active once the one it waits for has fired on an earlier tick.
func _is_active(index: int, world: World) -> bool:
	var after: int = _after[index]
	return after < 0 or (fired_tick[after] >= 0 and fired_tick[after] < world.tick)


func _holds(index: int, world: World) -> bool:
	var t: TriggerSpec = mission_script.triggers[index]
	match t.condition:
		TriggerSpec.Condition.AREA_ENTERED:
			return _units_inside(world, index) >= t.min_count
		TriggerSpec.Condition.UNIT_DIES:
			return _deaths(world, index) >= t.count
		TriggerSpec.Condition.TIMER:
			var activation: int = start_tick if _after[index] < 0 else fired_tick[_after[index]] + 1
			return world.tick >= activation + Difficulty.pick(t.ticks, tier)
		TriggerSpec.Condition.GROUP_CLEARED:
			return _cleared(world, index)
		TriggerSpec.Condition.FACTION_ELIMINATED:
			return (seen_factions & (1 << t.faction)) != 0 and not _any_alive(world, t.faction, false)
		TriggerSpec.Condition.TRIGGERS_FIRED:
			return _triggers_fired(world, index) >= t.min_count
		TriggerSpec.Condition.PLAYER_ELIMINATED:
			return (seen_commanded & (1 << t.faction)) != 0 and not _any_alive(world, t.faction, true)
	return false


# How many of the triggers trigger `index` names fired on an earlier tick. One
# that fired on this tick isn't counted: the link takes a tick, like `after`.
func _triggers_fired(world: World, index: int) -> int:
	var count: int = 0
	for other: int in _names[index]:
		if other >= 0 and fired_tick[other] >= 0 and fired_tick[other] < world.tick:
			count += 1
	return count


# Living units of the trigger's faction within its area's radius of its center.
# With names, only units the named groups spawned count; without, every unit of
# the faction does.
func _units_inside(world: World, index: int) -> int:
	var t: TriggerSpec = mission_script.triggers[index]
	var count: int = 0
	if t.names.is_empty():
		for unit: Unit in world.units:
			if _counts_inside(unit, t):
				count += 1
		return count
	for group: AiGroup in _groups_named(world, index):
		for unit_id: int in group.spawned_ids:
			var unit: Unit = world.get_unit(unit_id)
			if unit != null and _counts_inside(unit, t):
				count += 1
	return count


func _counts_inside(unit: Unit, t: TriggerSpec) -> bool:
	if not unit.is_alive() or unit.faction != t.faction:
		return false
	var radius: int = t.area[2]
	var dx: int = unit.x - t.area[0]
	var dz: int = unit.z - t.area[1]
	return dx * dx + dz * dz <= radius * radius


# Deaths among every unit the named groups ever had.
func _deaths(world: World, index: int) -> int:
	var count: int = 0
	for group: AiGroup in _groups_named(world, index):
		for unit_id: int in group.spawned_ids:
			if not _is_standing(world, unit_id):
				count += 1
	return count


# Every named group has spawned, and none of the units any of them had is
# still standing.
func _cleared(world: World, index: int) -> bool:
	for spec_index: int in _names[index]:
		if world.ai.groups_of(spec_index).is_empty():
			return false
	for group: AiGroup in _groups_named(world, index):
		for unit_id: int in group.spawned_ids:
			if _is_standing(world, unit_id):
				return false
	return true


# The spawned groups of the specs the trigger names, each spec once however
# often the list repeats it.
func _groups_named(world: World, index: int) -> Array[AiGroup]:
	var refs: PackedInt32Array = _names[index]
	var out: Array[AiGroup] = []
	for i: int in refs.size():
		if refs.find(refs[i]) == i:
			out.append_array(world.ai.groups_of(refs[i]))
	return out


func _is_standing(world: World, unit_id: int) -> bool:
	var unit: Unit = world.get_unit(unit_id)
	return unit != null and unit.is_alive()


# Whether any living unit of `side` exists; with commanded_only, only the ones
# the AI didn't spawn.
func _any_alive(world: World, side: UnitType.Faction, commanded_only: bool) -> bool:
	for unit: Unit in world.units:
		if unit.is_alive() and unit.faction == side:
			if not commanded_only or not world.ai.controls(unit.id):
				return true
	return false


func _apply(world: World, index: int, action_index: int) -> void:
	var action: TriggerAction = mission_script.triggers[index].actions[action_index]
	var target: int = _targets[index][action_index]
	match action.kind:
		TriggerAction.Kind.SPAWN_GROUP:
			world.ai.spawn_group(world, mission_script.groups[target], target, tier)
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
			for group: AiGroup in world.ai.groups_of(target):
				world.ai.set_behavior(world, group, action.behavior)
		TriggerAction.Kind.SHOW_OBJECTIVE:
			if objective_states[target] == ObjectiveState.HIDDEN:
				_set_objective_state(world, index, target, ObjectiveState.ACTIVE)
		TriggerAction.Kind.COMPLETE_OBJECTIVE:
			if not _is_settled(target):
				_set_objective_state(world, index, target, ObjectiveState.DONE)
		TriggerAction.Kind.FAIL_OBJECTIVE:
			if not _is_settled(target):
				_set_objective_state(world, index, target, ObjectiveState.FAILED)


# DONE and FAILED are final: nothing moves an objective out of them.
func _is_settled(objective_index: int) -> bool:
	return (
		objective_states[objective_index] == ObjectiveState.DONE
		or objective_states[objective_index] == ObjectiveState.FAILED
	)


func _set_objective_state(
	world: World, trigger: int, objective_index: int, state: ObjectiveState
) -> void:
	objective_states[objective_index] = state
	world.mission_events.append(
		MissionEvent.new(MissionEvent.Kind.OBJECTIVE_STATE, trigger, "", objective_index, state)
	)


# The trigger's `names` as indices: triggers for TRIGGERS_FIRED, groups for the
# conditions that name groups, nothing for the rest.
func _resolve_names(t: TriggerSpec) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	match t.condition:
		TriggerSpec.Condition.TRIGGERS_FIRED:
			for trigger_name: StringName in t.names:
				out.append(mission_script.trigger_index(trigger_name))
		TriggerSpec.Condition.AREA_ENTERED, TriggerSpec.Condition.UNIT_DIES, TriggerSpec.Condition.GROUP_CLEARED:
			for group_name: StringName in t.names:
				out.append(_resolve_group(group_name))
	return out


# What an action acts on, as an index (see _targets).
func _resolve_target(action: TriggerAction) -> int:
	match action.kind:
		TriggerAction.Kind.SPAWN_GROUP, TriggerAction.Kind.SET_BEHAVIOR:
			return _resolve_group(action.group)
		TriggerAction.Kind.SHOW_OBJECTIVE, TriggerAction.Kind.COMPLETE_OBJECTIVE, TriggerAction.Kind.FAIL_OBJECTIVE:
			return mission_script.objective_index(action.objective)
	return -1


# The index of the group a name means: a group by that name, else the group the
# roll bound to the alias of that name, else -1.
func _resolve_group(group_name: StringName) -> int:
	var direct: int = mission_script.group_index(group_name)
	if direct >= 0:
		return direct
	var slot: int = mission_script.binding_index(group_name)
	if slot < 0 or slot >= bindings.size():
		return -1
	return bindings[slot]
