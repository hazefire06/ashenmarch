class_name MissionScript
extends Resource
## A mission's scripted opposition and rules (data/missions/*.tres): the AI
## groups it can spawn and the triggers that spawn them, change the weather,
## set objectives, and decide the outcome. Adding a mission is adding data,
## not engine code. It is read-only at runtime; MissionRuntime keeps all
## progress in the world.

## The groups the mission can spawn, each named uniquely; a group's index here
## is how the AI and the hash refer to it.
@export var groups: Array[AiGroupSpec] = []
## The mission's rules, checked in this order; a trigger's index here is how
## the runtime and the hash refer to it.
@export var triggers: Array[TriggerSpec] = []


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
		TriggerSpec.Condition.UNIT_DIES:
			errors.append_array(_validate_group_names(prefix, "UNIT_DIES", t))
			if t.count < 1:
				errors.append(prefix + "UNIT_DIES needs count >= 1")
		TriggerSpec.Condition.GROUP_CLEARED:
			errors.append_array(_validate_group_names(prefix, "GROUP_CLEARED", t))
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


func _validate_group_names(prefix: String, condition_name: String, t: TriggerSpec) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if t.names.is_empty():
		errors.append("%s%s needs at least one group name" % [prefix, condition_name])
	for group_name: StringName in t.names:
		if group_index(group_name) < 0:
			errors.append("%sunknown group %s" % [prefix, group_name])
	return errors


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
			var g: int = group_index(action.group)
			if g < 0:
				errors.append("%s: unknown group %s" % [where, action.group])
			elif action.kind == TriggerAction.Kind.SET_BEHAVIOR:
				for problem: String in groups[g].params_errors(action.behavior):
					errors.append("%s: %s" % [where, problem])
		TriggerAction.Kind.SET_WEATHER:
			if action.weather == null:
				errors.append(where + ": SET_WEATHER needs a weather")
			else:
				if action.weather.tick != 0:
					errors.append(where + ": SET_WEATHER weather tick must be 0")
				errors.append_array(action.weather.validate(where + " weather"))
	return errors
