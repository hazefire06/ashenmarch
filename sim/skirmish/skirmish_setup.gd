class_name SkirmishSetup
extends RefCounted
## A whole skirmish as data: the map, the rules, both armies, who starts where,
## and the seed. create_world builds the world from it, the one way a
## skirmish world is made (the App, the tests and the playtest all use it),
## so the same setup always builds the same world, and the setup plus the
## player's commands is a replay.
##
## The player's army enters as a DeployCommand at tick 0, like a campaign
## roster. The AI's is the mission's starting groups (ai_group_specs), driven
## by a SkirmishCommander. With player_is_ai (the playtest's AI-against-AI
## runs, and tests) both armies are AI groups with a commander each.

## The tier a skirmish world plays at. Skirmish has no difficulty: both sides
## get the same budget. Only the AI's own groups read a tier, and theirs
## spawn the same counts at every tier.
const TIER: int = 2
## Milli-units between the AI's main block and its raiders, side by side.
const RAIDER_GAP: int = 4000

var map: SkirmishMap
var rules: SkirmishRules
## The budget both armies were bought with.
var budget: int = 0
## The player's army, then the AI's (armies[0] is on rules.player_faction).
var armies: Array[Army] = []
## Which of the map's starts the player has, 0 (A) or 1 (B); the AI has the
## other.
var player_spawn: int = 0
## The ArmyTemplate the AI's army was filled from, for the results screen.
## Not used to build anything: armies[1] is the army.
var ai_template_id: StringName = &""
var world_seed: int = 0
## True: the player's army is AI too (a commander each side).
var player_is_ai: bool = false


## The player's side.
func player_faction() -> UnitType.Faction:
	return rules.player_faction


## The AI's side.
func ai_faction() -> UnitType.Faction:
	return (1 - rules.player_faction) as UnitType.Faction


## Problems that make the setup unplayable, or an empty array. Every one is
## listed.
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if map == null:
		errors.append("map is missing")
	else:
		for problem: String in map.validate():
			errors.append("map: " + problem)
	if rules == null:
		errors.append("rules are missing")
	else:
		for problem: String in rules.validate():
			errors.append("rules: " + problem)
	if player_spawn != 0 and player_spawn != 1:
		errors.append("player_spawn must be 0 or 1")
	if armies.size() != 2 or armies[0] == null or armies[1] == null:
		errors.append("armies must be the player's and the AI's")
	elif rules != null:
		var sides: Array[UnitType.Faction] = [player_faction(), ai_faction()]
		var whose: Array[String] = ["the player's army", "the AI's army"]
		for i: int in 2:
			if armies[i].faction != sides[i]:
				errors.append("%s is on the wrong side" % whose[i])
			for problem: String in armies[i].validate(catalog, budget):
				errors.append("%s: %s" % [whose[i], problem])
	return errors


## The world this setup plays out in, before its first step: the player's
## deploy (or AI groups), the map's herb plants, the AI's groups as the
## mission's starting groups, the skirmish rules, and a commander per AI side.
## Entity ids run deploy, herbs, groups, as in the campaign. Returns null
## after a push_error for a null input, a setup that doesn't validate, or a
## map that won't load.
static func create_world(setup: SkirmishSetup, catalog: UnitCatalog) -> World:
	if setup == null or catalog == null:
		push_error("SkirmishSetup.create_world: no setup or no catalog")
		return null
	var errors: PackedStringArray = setup.validate(catalog)
	if not errors.is_empty():
		push_error("SkirmishSetup.create_world: %s" % "; ".join(errors))
		return null
	var terrain: Terrain = Terrain.load_map(setup.map.map)
	if terrain == null:
		push_error("SkirmishSetup.create_world: the map didn't load")
		return null
	var world: World = World.new(setup.world_seed, terrain, catalog)
	var script: MissionScript = MissionScript.new()
	var ai_sides: Array[int] = []
	var player_start: int = setup.player_spawn
	if setup.player_is_ai:
		ai_sides.append(0)
	else:
		world.enqueue(setup.deploy_command(catalog))
	ai_sides.append(1)
	var herbs: PackedInt32Array = setup.map.map.herb_plants
	for i: int in range(0, herbs.size() - 1, 2):
		world.enqueue(SpawnHerbPlantCommand.new(world.tick, herbs[i], herbs[i + 1]))
	# Per AI army: [main spec index, raider spec index or -1, side].
	var plans: Array[PackedInt32Array] = []
	for army_index: int in ai_sides:
		var start: int = player_start if army_index == 0 else 1 - player_start
		var specs: Array[AiGroupSpec] = ai_group_specs(setup, army_index, start, catalog)
		var main_index: int = script.groups.size()
		script.groups.append(specs[0])
		var raider_index: int = -1
		if specs.size() > 1:
			raider_index = script.groups.size()
			script.groups.append(specs[1])
		plans.append(PackedInt32Array([main_index, raider_index, setup.armies[army_index].faction]))
	if not world.start_mission(script, TIER) or not world.start_skirmish(setup.rules):
		return null
	var a: Vector2i = setup.map.spawn(0)
	var b: Vector2i = setup.map.spawn(1)
	var centre: Vector2i = world.pathing.snap_to_component(
		(a.x + b.x) / 2, (a.y + b.y) / 2, Terrain.Mobility.LIVING,
		world.pathing.component_at(a.x, a.y, Terrain.Mobility.LIVING)
	)
	for plan: PackedInt32Array in plans:
		var commander_id: int = world.ai.commanders.size() + 1
		world.ai.commanders.append(SkirmishCommander.new(
			commander_id, plan[2] as UnitType.Faction, plan[0], plan[1], centre
		))
	return world


## The setup as plain data for a replay (Replay.setup): the map by resource
## path, the rules' fields, both armies as sorted type ids and counts, and the
## rest as is. Only ints, bools, Strings and packed arrays, so var_to_bytes
## stores it the same everywhere.
func to_dict() -> Dictionary:
	var army_data: Array = []
	for army: Army in armies:
		var ids: PackedStringArray = PackedStringArray()
		for type_id: StringName in army.counts:
			ids.append(String(type_id))
		ids.sort()
		var counts: PackedInt32Array = PackedInt32Array()
		for type_name: String in ids:
			counts.append(army.counts[StringName(type_name)])
		army_data.append([int(army.faction), ids, counts])
	return {
		"map": map.resource_path,
		"mode": int(rules.mode),
		"time_limit_ticks": rules.time_limit_ticks,
		"capture_ticks": rules.capture_ticks,
		"player_faction": int(rules.player_faction),
		"flags": rules.flags.duplicate(),
		"hill": rules.hill,
		"flag_radius": rules.flag_radius,
		"budget": budget,
		"armies": army_data,
		"player_spawn": player_spawn,
		"ai_template": String(ai_template_id),
		"seed": world_seed,
		"player_is_ai": player_is_ai,
	}


## The setup to_dict() describes, or null if `data` is malformed: a missing or
## wrongly typed field, an enum out of range, or a map path that doesn't load
## as a SkirmishMap. Whether the result is playable is validate()'s (and
## create_world's) to say.
static func from_dict(data: Dictionary) -> SkirmishSetup:
	var ints: PackedStringArray = [
		"mode", "time_limit_ticks", "capture_ticks", "player_faction", "hill", "flag_radius",
		"budget", "player_spawn", "seed",
	]
	for key: String in ints:
		if not data.get(key) is int:
			return null
	if (
		not data.get("map") is String or not data.get("flags") is PackedInt32Array
		or not data.get("armies") is Array or not data.get("ai_template") is String
		or not data.get("player_is_ai") is bool
	):
		return null
	if (
		not SkirmishRules.Mode.values().has(data["mode"])
		or not UnitType.Faction.values().has(data["player_faction"])
	):
		return null
	var map_path: String = data["map"]
	if not map_path.begins_with("res://") or not ResourceLoader.exists(map_path):
		return null
	var loaded_map: SkirmishMap = load(map_path) as SkirmishMap
	if loaded_map == null:
		return null
	var setup: SkirmishSetup = SkirmishSetup.new()
	setup.map = loaded_map
	setup.rules = SkirmishRules.new()
	setup.rules.mode = data["mode"] as SkirmishRules.Mode
	setup.rules.time_limit_ticks = data["time_limit_ticks"]
	setup.rules.capture_ticks = data["capture_ticks"]
	setup.rules.player_faction = data["player_faction"] as UnitType.Faction
	setup.rules.flags = (data["flags"] as PackedInt32Array).duplicate()
	setup.rules.hill = data["hill"]
	setup.rules.flag_radius = data["flag_radius"]
	setup.budget = data["budget"]
	setup.player_spawn = data["player_spawn"]
	setup.ai_template_id = StringName(data["ai_template"] as String)
	setup.world_seed = data["seed"]
	setup.player_is_ai = data["player_is_ai"]
	for entry: Variant in data["armies"] as Array:
		if not entry is Array or (entry as Array).size() != 3:
			return null
		var fields: Array = entry
		if (
			not fields[0] is int or not UnitType.Faction.values().has(fields[0])
			or not fields[1] is PackedStringArray or not fields[2] is PackedInt32Array
		):
			return null
		var ids: PackedStringArray = fields[1]
		var counts: PackedInt32Array = fields[2]
		if ids.size() != counts.size():
			return null
		var army: Army = Army.new(fields[0] as UnitType.Faction)
		for k: int in ids.size():
			army.set_count(StringName(ids[k]), counts[k])
		setup.armies.append(army)
	return setup


## The player's army as the tick-0 DeployCommand: deploy order (melee first),
## at the player's start, facing as the map says, in a box, on the player's
## side; no soldiers, kills or wounds.
func deploy_command(catalog: UnitCatalog) -> DeployCommand:
	var ids: Array[StringName] = armies[0].type_list(catalog)
	var zeros: PackedInt32Array = PackedInt32Array()
	zeros.resize(ids.size())
	var at: Vector2i = map.spawn(player_spawn)
	var facing: Vector2i = map.facing(player_spawn)
	return DeployCommand.new(
		0, ids, zeros, zeros, zeros, at.x, at.y, facing.x, facing.y, Formations.Kind.BOX,
		player_faction()
	)


## An AI army's groups, as specs built for this world (never shared): the
## main group, everything but the raiders, at the start; and, if the army has
## any, the raiders (melee types that prefer ranged or support targets: the
## Rippers) beside it, to the main block's right with RAIDER_GAP between.
## Both start ADVANCE at their spawn, keep their ranged and support behind
## the melee (ranged_behind), never retreat on their own, and spawn at the
## start of the mission.
static func ai_group_specs(
	setup: SkirmishSetup, army_index: int, start: int, catalog: UnitCatalog
) -> Array[AiGroupSpec]:
	var army: Army = setup.armies[army_index]
	var main_ids: Array[StringName] = []
	var raider_ids: Array[StringName] = []
	for type_id: StringName in army.type_list(catalog):
		if is_raider(catalog.find(type_id)):
			raider_ids.append(type_id)
		else:
			main_ids.append(type_id)
	var at: Vector2i = setup.map.spawn(start)
	var facing: Vector2i = setup.map.facing(start)
	var side: StringName = &"light" if army.faction == UnitType.Faction.LIGHT else &"dark"
	var specs: Array[AiGroupSpec] = []
	if main_ids.is_empty():
		# Nothing but raiders: they are the main group, at the start itself.
		specs.append(_spec(StringName("%s_main" % side), army.faction, raider_ids, at, facing))
		return specs
	specs.append(_spec(StringName("%s_main" % side), army.faction, main_ids, at, facing))
	if not raider_ids.is_empty():
		var right: Vector2i = FixedMath.normalize(-facing.y, facing.x, FixedMath.DIR_ONE)
		if facing == Vector2i.ZERO:
			right = Vector2i(FixedMath.DIR_ONE, 0)
		var offset: int = (
			block_width(main_ids, facing, catalog) / 2 + block_width(raider_ids, facing, catalog) / 2
			+ RAIDER_GAP
		)
		var spot: Vector2i = at + Vector2i(
			right.x * offset / FixedMath.DIR_ONE, right.y * offset / FixedMath.DIR_ONE
		)
		specs.append(_spec(StringName("%s_raiders" % side), army.faction, raider_ids, spot, facing))
	return specs


## True if the type is a raider in a skirmish army: a melee type that goes for
## ranged or support units first (a Ripper).
static func is_raider(t: UnitType) -> bool:
	var backline: int = (1 << UnitType.Role.RANGED) | (1 << UnitType.Role.SUPPORT)
	return t.role == UnitType.Role.MELEE and (t.preferred_target_roles & backline) != 0


## How wide a box of these types stands across its facing, in milli-units,
## slot center to slot center (World.spawn_block's layout).
static func block_width(type_ids: Array[StringName], facing: Vector2i, catalog: UnitCatalog) -> int:
	if type_ids.is_empty():
		return 0
	var largest: int = 0
	for type_id: StringName in type_ids:
		largest = maxi(largest, catalog.find(type_id).body_radius)
	var slots: Array[FormationSlot] = Formations.slots(
		Formations.Kind.BOX, type_ids.size(), 0, 0, facing.x, facing.y, Formations.spacing_for(largest)
	)
	var right: Vector2i = FixedMath.normalize(-facing.y, facing.x, FixedMath.DIR_ONE)
	if facing == Vector2i.ZERO:
		right = Vector2i(FixedMath.DIR_ONE, 0)
	var lo: int = 0
	var hi: int = 0
	for slot: FormationSlot in slots:
		var across: int = (slot.x * right.x + slot.z * right.y) / FixedMath.DIR_ONE
		lo = mini(lo, across)
		hi = maxi(hi, across)
	return hi - lo


static func _spec(
	group_name: StringName, side: UnitType.Faction, type_ids: Array[StringName], at: Vector2i,
	facing: Vector2i
) -> AiGroupSpec:
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = group_name
	spec.faction = side
	# One entry per run of a type, in deploy order, so the block lays out
	# melee in front.
	var i: int = 0
	while i < type_ids.size():
		var j: int = i
		while j < type_ids.size() and type_ids[j] == type_ids[i]:
			j += 1
		var entry: AiUnitEntry = AiUnitEntry.new()
		entry.type_id = type_ids[i]
		entry.counts = PackedInt32Array([j - i])
		spec.units.append(entry)
		i = j
	spec.spawns = PackedInt32Array([at.x, at.y])
	spec.facing_x = facing.x
	spec.facing_z = facing.y
	spec.formation = Formations.Kind.BOX
	spec.spawn_at_start = true
	spec.behavior = AiGroupSpec.Behavior.ADVANCE
	spec.guard_radius = SkirmishCommander.ENGAGE_RADIUS
	spec.ranged_behind = true
	return spec
