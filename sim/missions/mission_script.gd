class_name MissionScript
extends Resource
## A mission's scripted opposition and rules (data/missions/*.tres): the AI
## groups it can spawn and the triggers that spawn them, change the weather,
## set objectives, and decide the outcome. Adding a mission is adding data,
## not engine code. It is read-only at runtime; MissionRuntime keeps all
## progress in the world.
##
## Anywhere a trigger or action names a group, it may name an alias instead:
## a slot of one of the script's draws, which means whichever pool group the
## world's roll bound to it (MissionDraw, World.roll_bindings).

## The groups the mission can spawn, each named uniquely; a group's index here
## is how the AI and the hash refer to it.
@export var groups: Array[AiGroupSpec] = []
## The mission's rules, checked in this order; a trigger's index here is how
## the runtime and the hash refer to it.
@export var triggers: Array[TriggerSpec] = []
## The objectives the player's panel lists, each named uniquely; an objective's
## index here is how the runtime, the HUD, and the hash refer to it.
@export var objectives: Array[ObjectiveSpec] = []
## The random draws made at the start, in order; a draw's index here, and a
## slot's place in it, say where its binding sits in MissionRuntime.bindings.
@export var draws: Array[MissionDraw] = []


## Index of the first group with this name, or -1.
func group_index(group_name: StringName) -> int:
	for i: int in groups.size():
		if groups[i] != null and groups[i].name == group_name:
			return i
	return -1


## Index of the first trigger with this name, or -1.
func trigger_index(trigger_name: StringName) -> int:
	for i: int in triggers.size():
		if triggers[i] != null and triggers[i].name == trigger_name:
			return i
	return -1


## Index of the first objective with this name, or -1.
func objective_index(objective_name: StringName) -> int:
	for i: int in objectives.size():
		if objectives[i] != null and objectives[i].name == objective_name:
			return i
	return -1


## Which draw and slot an alias name is, as (draw index, slot index), or
## (-1, -1) if it is no alias. The first match wins, like the other lookups.
func alias_draw(alias_name: StringName) -> Vector2i:
	if alias_name == &"":
		return Vector2i(-1, -1)
	for i: int in draws.size():
		if draws[i] == null:
			continue
		var slot: int = draws[i].slots.find(alias_name)
		if slot >= 0:
			return Vector2i(i, slot)
	return Vector2i(-1, -1)


## Where an alias's binding sits in a bindings array (one entry per slot of
## every draw, draws in order), or -1 if it is no alias.
func binding_index(alias_name: StringName) -> int:
	var at: Vector2i = alias_draw(alias_name)
	if at.x < 0:
		return -1
	var index: int = at.y
	for i: int in at.x:
		if draws[i] != null:
			index += draws[i].slots.size()
	return index


## Problems that make the script unusable, or an empty array. The catalog is
## what the groups' unit type ids are checked against.
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var seen_groups: Dictionary[StringName, bool] = {}
	for i: int in groups.size():
		var g: AiGroupSpec = groups[i]
		if g == null:
			errors.append("group %d is null" % i)
			continue
		errors.append_array(g.validate(catalog))
		# An empty name is already reported by the group itself.
		if g.name != &"" and seen_groups.has(g.name):
			errors.append("duplicate group name %s" % g.name)
		seen_groups[g.name] = true
	errors.append_array(_validate_objectives())
	errors.append_array(_validate_draws())
	var seen_triggers: Dictionary[StringName, bool] = {}
	for i: int in triggers.size():
		var t: TriggerSpec = triggers[i]
		if t == null:
			errors.append("trigger %d is null" % i)
			continue
		if t.name != &"" and seen_triggers.has(t.name):
			errors.append("duplicate trigger name %s" % t.name)
		seen_triggers[t.name] = true
		errors.append_array(_validate_trigger(i, t))
	return errors


func _validate_objectives() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var seen: Dictionary[StringName, bool] = {}
	for i: int in objectives.size():
		var o: ObjectiveSpec = objectives[i]
		if o == null:
			errors.append("objective %d is null" % i)
			continue
		if o.name == &"":
			errors.append("objective %d: name is empty" % i)
		elif seen.has(o.name):
			errors.append("duplicate objective name %s" % o.name)
		seen[o.name] = true
	return errors


func _validate_draws() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var aliases: Dictionary[StringName, bool] = {}
	var pooled: Dictionary[StringName, bool] = {}
	for i: int in draws.size():
		var d: MissionDraw = draws[i]
		var where: String = "draw %d" % i
		if d == null:
			errors.append(where + " is null")
			continue
		if d.slots.is_empty():
			errors.append(where + " needs at least one slot")
		elif d.slots.size() > d.pool.size():
			errors.append("%s has %d slots but only %d pool groups" % [where, d.slots.size(), d.pool.size()])
		for alias: StringName in d.slots:
			if alias == &"":
				errors.append(where + ": alias name is empty")
				continue
			if aliases.has(alias):
				errors.append("%s: duplicate alias name %s" % [where, alias])
			if group_index(alias) >= 0:
				errors.append("%s: alias %s is also a group name" % [where, alias])
			aliases[alias] = true
		for pool_name: StringName in d.pool:
			var g: int = group_index(pool_name)
			if g < 0:
				errors.append("%s: unknown pool group %s" % [where, pool_name])
			elif groups[g].spawn_at_start:
				errors.append("%s: pool group %s spawns at start" % [where, pool_name])
			if pooled.has(pool_name):
				errors.append("%s: pool group %s is already in a pool" % [where, pool_name])
			pooled[pool_name] = true
	return errors


func _validate_trigger(index: int, t: TriggerSpec) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var prefix: String = "trigger %s: " % (String(t.name) if t.name != &"" else "<unnamed>")
	if t.name == &"":
		errors.append(prefix + "name is empty")
	if not TriggerSpec.Condition.values().has(t.condition):
		errors.append(prefix + "condition is not a TriggerSpec.Condition")
	if not UnitType.Faction.values().has(t.faction):
		errors.append(prefix + "faction is not a UnitType.Faction")
	if t.after != &"":
		if trigger_index(t.after) < 0:
			errors.append("%safter names no trigger (%s)" % [prefix, t.after])
		elif _after_loops(index):
			errors.append(prefix + "after chain loops")
	match t.condition:
		TriggerSpec.Condition.AREA_ENTERED:
			if t.area.size() != 3:
				errors.append(prefix + "AREA_ENTERED needs area as x, z, radius")
			elif t.area[2] <= 0:
				errors.append(prefix + "AREA_ENTERED needs a radius above 0")
			if t.min_count < 1:
				errors.append(prefix + "AREA_ENTERED needs min_count >= 1")
			errors.append_array(_validate_group_names(prefix, "AREA_ENTERED", t, false))
		TriggerSpec.Condition.UNIT_DIES:
			errors.append_array(_validate_group_names(prefix, "UNIT_DIES", t, true))
			if t.count < 1:
				errors.append(prefix + "UNIT_DIES needs count >= 1")
		TriggerSpec.Condition.GROUP_CLEARED:
			errors.append_array(_validate_group_names(prefix, "GROUP_CLEARED", t, true))
		TriggerSpec.Condition.TRIGGERS_FIRED:
			errors.append_array(_validate_trigger_names(prefix, t))
		TriggerSpec.Condition.TIMER:
			if not Difficulty.is_valid(t.ticks):
				errors.append("%sTIMER needs 1 or %d ticks" % [prefix, Difficulty.TIERS])
			else:
				for value: int in t.ticks:
					if value < 0:
						errors.append(prefix + "TIMER ticks can't be negative")
						break
	for i: int in t.actions.size():
		errors.append_array(_validate_action(prefix, i, t.actions[i]))
	return errors


# True if following `after` links from triggers[start] revisits a trigger.
func _after_loops(start: int) -> bool:
	var visited: Dictionary[int, bool] = {}
	var current: int = start
	while not visited.has(current):
		visited[current] = true
		var t: TriggerSpec = triggers[current]
		if t.after == &"":
			return false
		current = trigger_index(t.after)
		if current < 0:
			return false
	return true


# `required` is false for a condition that only filters by group (AREA_ENTERED).
func _validate_group_names(
	prefix: String, condition_name: String, t: TriggerSpec, required: bool
) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if required and t.names.is_empty():
		errors.append("%s%s needs at least one group name" % [prefix, condition_name])
	for group_name: StringName in t.names:
		var problem: String = _group_reference_problem(group_name)
		if problem != "":
			errors.append(prefix + problem)
	return errors


func _validate_trigger_names(prefix: String, t: TriggerSpec) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if t.names.is_empty():
		errors.append(prefix + "TRIGGERS_FIRED needs at least one trigger name")
		return errors
	var seen: Dictionary[StringName, bool] = {}
	for trigger_name: StringName in t.names:
		if trigger_name == t.name:
			errors.append(prefix + "TRIGGERS_FIRED can't name itself")
		elif trigger_index(trigger_name) < 0:
			errors.append("%sTRIGGERS_FIRED names no trigger (%s)" % [prefix, trigger_name])
		if seen.has(trigger_name):
			errors.append("%sTRIGGERS_FIRED names %s twice" % [prefix, trigger_name])
		seen[trigger_name] = true
	if t.min_count < 1 or t.min_count > t.names.size():
		errors.append("%sTRIGGERS_FIRED needs min_count from 1 to %d" % [prefix, t.names.size()])
	return errors


# Why a trigger or action can't name this group (an alias, or a group outside
# every pool), or "" if it can.
func _group_reference_problem(group_name: StringName) -> String:
	if alias_draw(group_name).x >= 0:
		return ""
	if group_index(group_name) < 0:
		return "unknown group %s" % group_name
	for d: MissionDraw in draws:
		if d != null and d.pool.has(group_name):
			return "pool group %s can only be named through an alias" % group_name
	return ""


# The indices of the groups a name may mean: the group itself, or every group
# of the pool if it is an alias (any of them could be the one drawn).
func _groups_it_may_mean(group_name: StringName) -> Array[int]:
	var out: Array[int] = []
	var alias: Vector2i = alias_draw(group_name)
	if alias.x < 0:
		out.append(group_index(group_name))
		return out
	for pool_name: StringName in draws[alias.x].pool:
		var g: int = group_index(pool_name)
		if g >= 0:
			out.append(g)
	return out


func _validate_action(prefix: String, i: int, action: TriggerAction) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var where: String = "%saction %d" % [prefix, i]
	if action == null:
		errors.append(where + " is null")
		return errors
	if not TriggerAction.Kind.values().has(action.kind):
		errors.append(where + ": kind is not a TriggerAction.Kind")
	if not AiGroupSpec.Behavior.values().has(action.behavior):
		errors.append(where + ": behavior is not an AiGroupSpec.Behavior")
	match action.kind:
		TriggerAction.Kind.SPAWN_GROUP, TriggerAction.Kind.SET_BEHAVIOR:
			var reference_problem: String = _group_reference_problem(action.group)
			if reference_problem != "":
				errors.append("%s: %s" % [where, reference_problem])
			elif action.kind == TriggerAction.Kind.SET_BEHAVIOR:
				# An alias could be any group of its pool, so each one must be
				# able to take the behavior.
				for g: int in _groups_it_may_mean(action.group):
					for problem: String in groups[g].params_errors(action.behavior):
						errors.append("%s: %s" % [where, problem])
		TriggerAction.Kind.SHOW_OBJECTIVE, TriggerAction.Kind.COMPLETE_OBJECTIVE, TriggerAction.Kind.FAIL_OBJECTIVE:
			if objective_index(action.objective) < 0:
				errors.append("%s: unknown objective %s" % [where, action.objective])
		TriggerAction.Kind.SET_WEATHER:
			if action.weather == null:
				errors.append(where + ": SET_WEATHER needs a weather")
			else:
				if action.weather.tick != 0:
					errors.append(where + ": SET_WEATHER weather tick must be 0")
				errors.append_array(action.weather.validate(where + " weather"))
	return errors
