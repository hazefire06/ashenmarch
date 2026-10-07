extends GutTest
## SkirmishSetup.create_world, the one way a skirmish world is built: the
## player's deploy, the herbs, the AI's groups and commander, in that id
## order; a Dark player; both sides AI; what it refuses; and that two worlds
## built from one setup stay identical.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BC: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
const KOTH: SkirmishRules.Mode = SkirmishRules.Mode.KING_OF_THE_HILL
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS
const SKIRMISH_CATALOG: String = "res://data/skirmish/skirmish.tres"

var _catalog: UnitCatalog
var _skirmish: SkirmishCatalog


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	_skirmish = load(SKIRMISH_CATALOG)


func _setup(
	map_id: StringName, mode: SkirmishRules.Mode, player: UnitType.Faction = LIGHT, budget: int = 600,
	player_template: StringName = &"", ai_template: StringName = &""
) -> SkirmishSetup:
	var s: SkirmishSetup = SkirmishSetup.new()
	s.map = _skirmish.skirmish_map(map_id)
	s.rules = SkirmishRules.for_map(s.map, mode, 10, player)
	s.budget = budget
	var ai: UnitType.Faction = DARK if player == LIGHT else LIGHT
	var side_name: Array[String] = ["light", "dark"]
	if player_template == &"":
		player_template = StringName("%s_balanced" % side_name[player])
	if ai_template == &"":
		ai_template = StringName("%s_balanced" % side_name[ai])
	s.armies = [_skirmish.template(player_template).fill(budget, _catalog), _skirmish.template(ai_template).fill(budget, _catalog)]
	s.ai_template_id = ai_template
	s.world_seed = 77
	return s


func _ids_of(w: World, side: UnitType.Faction) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for unit: Unit in w.units:
		if unit.faction == side:
			out.append(unit.id)
	return out


func test_a_world_is_the_deploy_then_the_herbs_then_the_ai() -> void:
	var s: SkirmishSetup = _setup(&"old_mill", KOTH)
	var w: World = SkirmishSetup.create_world(s, _catalog)
	assert_not_null(w)
	assert_not_null(w.mission)
	assert_not_null(w.skirmish)
	assert_eq(w.mission.tier, SkirmishSetup.TIER)
	assert_eq(w.ai.commanders.size(), 1)
	w.step()
	var light: PackedInt32Array = _ids_of(w, LIGHT)
	var dark: PackedInt32Array = _ids_of(w, DARK)
	var n: int = s.armies[0].size()
	assert_eq(light.size(), n)
	assert_eq(light[0], 1, "the deploy comes first")
	assert_eq(light[n - 1], n)
	var herbs: int = s.map.map.herb_plants.size() / 2
	assert_eq(w.herb_plants.size(), herbs)
	assert_eq(w.herb_plants[0].id, n + 1, "then the herbs")
	assert_eq(dark[0], n + herbs + 1, "then the AI's groups")
	assert_eq(dark.size(), s.armies[1].size())
	for unit_id: int in light:
		assert_false(w.ai.controls(unit_id), "the player's units are the player's")
	for unit_id: int in dark:
		assert_true(w.ai.controls(unit_id), "the AI's are the AI's")
	assert_eq(w.skirmish.roster_ids[LIGHT], light)
	assert_eq(w.skirmish.roster_ids[DARK], dark)


func test_the_player_deploys_at_their_start_in_deploy_order() -> void:
	var s: SkirmishSetup = _setup(&"riverside", BC)
	s.player_spawn = 1
	var cmd: DeployCommand = s.deploy_command(_catalog)
	assert_eq(Vector2i(cmd.x, cmd.z), s.map.spawn(1))
	assert_eq(Vector2i(cmd.facing_x, cmd.facing_z), s.map.facing(1))
	assert_eq(cmd.faction, LIGHT)
	assert_eq(cmd.tick, 0)
	assert_eq(cmd.type_ids, s.armies[0].type_list(_catalog))
	assert_eq(cmd.type_ids[0], &"shieldman", "melee in front")
	assert_eq(cmd.type_ids[cmd.type_ids.size() - 1], &"warden", "support at the back")
	var zeros: PackedInt32Array = _zeros(cmd.type_ids.size())
	assert_eq(cmd.soldier_ids, zeros, "no soldiers")
	assert_eq(cmd.kills, zeros, "no kills")
	assert_eq(cmd.hp, zeros, "full health")
	var w: World = SkirmishSetup.create_world(s, _catalog)
	w.step()
	var c: Vector2i = AiOrders.centroid(_units(w, LIGHT))
	assert_lt(FixedMath.length(c.x - s.map.spawn(1).x, c.y - s.map.spawn(1).y), 3000, "the block is centered on start B")
	var d: Vector2i = AiOrders.centroid(_units(w, DARK))
	assert_lt(FixedMath.length(d.x - s.map.spawn(0).x, d.y - s.map.spawn(0).y), 20000, "the AI has start A")


func _zeros(n: int) -> PackedInt32Array:
	var z: PackedInt32Array = PackedInt32Array()
	z.resize(n)
	return z


func _units(w: World, side: UnitType.Faction) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in w.units:
		if unit.faction == side and unit.is_alive():
			out.append(unit)
	return out


func test_a_dark_player_deploys_dark_and_the_ai_plays_light() -> void:
	var s: SkirmishSetup = _setup(&"the_ford", CTF, DARK)
	assert_eq(s.player_faction(), DARK)
	assert_eq(s.ai_faction(), LIGHT)
	var w: World = SkirmishSetup.create_world(s, _catalog)
	assert_eq(w.ai.commanders[0].faction, LIGHT)
	w.step()
	for unit: Unit in _units(w, DARK):
		assert_false(w.ai.controls(unit.id))
	for unit: Unit in _units(w, LIGHT):
		assert_true(w.ai.controls(unit.id))
	assert_eq(_units(w, DARK).size(), s.armies[0].size())


func test_the_ai_army_splits_into_main_and_raiders() -> void:
	var s: SkirmishSetup = _setup(&"riverside", KOTH, LIGHT, 1000, &"", &"dark_raiders")
	var specs: Array[AiGroupSpec] = SkirmishSetup.ai_group_specs(s, 1, 1, _catalog)
	assert_eq(specs.size(), 2)
	var main: AiGroupSpec = specs[0]
	var raiders: AiGroupSpec = specs[1]
	assert_eq(main.name, &"dark_main")
	assert_eq(raiders.name, &"dark_raiders")
	for spec: AiGroupSpec in specs:
		assert_eq(spec.validate(_catalog), PackedStringArray())
		assert_eq(spec.behavior, AiGroupSpec.Behavior.ADVANCE)
		assert_true(spec.ranged_behind)
		assert_true(spec.spawn_at_start)
		assert_eq(spec.retreat_below_permille, 0)
		assert_eq(spec.faction, DARK)
	assert_eq(main.unit_count(0), s.armies[1].size() - s.armies[1].count_of(&"ripper"))
	assert_eq(raiders.unit_count(0), s.armies[1].count_of(&"ripper"))
	assert_eq(raiders.units[0].type_id, &"ripper")
	assert_eq(main.units[0].type_id, &"husk", "melee first")
	var a: Vector2i = main.spawn_point(0)
	var b: Vector2i = raiders.spawn_point(0)
	assert_eq(a, s.map.spawn(1))
	var gap: int = FixedMath.length(b.x - a.x, b.y - a.y)
	assert_gt(gap, SkirmishSetup.RAIDER_GAP, "the raiders stand beside the main block")
	var facing: Vector2i = s.map.facing(1)
	assert_eq((b.x - a.x) * facing.x + (b.y - a.y) * facing.y, 0, "beside, not in front or behind")


func test_an_army_without_raiders_is_one_group_and_all_raiders_is_its_main() -> void:
	var s: SkirmishSetup = _setup(&"riverside", KOTH)
	assert_eq(SkirmishSetup.ai_group_specs(s, 1, 1, _catalog).size(), 2, "Balanced has Rippers")
	var shields: Army = Army.new(DARK)
	shields.set_count(&"husk", 5)
	s.armies[1] = shields
	assert_eq(SkirmishSetup.ai_group_specs(s, 1, 1, _catalog).size(), 1)
	var rippers: Army = Army.new(DARK)
	rippers.set_count(&"ripper", 5)
	s.armies[1] = rippers
	var only: Array[AiGroupSpec] = SkirmishSetup.ai_group_specs(s, 1, 1, _catalog)
	assert_eq(only.size(), 1)
	assert_eq(only[0].name, &"dark_main")
	assert_eq(only[0].spawn_point(0), s.map.spawn(1))


func test_raiders_are_melee_that_go_for_the_back_line() -> void:
	for type_id: StringName in [&"ripper"]:
		assert_true(SkirmishSetup.is_raider(_catalog.find(type_id)), String(type_id))
	for type_id: StringName in [&"husk", &"shieldman", &"reaver", &"blightbag", &"drifter", &"stormcaller", &"longbow"]:
		assert_false(SkirmishSetup.is_raider(_catalog.find(type_id)), String(type_id))


func test_the_raiders_spawn_on_open_ground_at_every_start() -> void:
	for m: SkirmishMap in _skirmish.maps:
		var t: Terrain = Terrain.load_map(m.map)
		for start: int in 2:
			for side: UnitType.Faction in [LIGHT, DARK]:
				var s: SkirmishSetup = _setup(m.id, BC, LIGHT if side == DARK else DARK, 1500, &"", &"dark_raiders" if side == DARK else &"light_balanced")
				var specs: Array[AiGroupSpec] = SkirmishSetup.ai_group_specs(s, 1, start, _catalog)
				for spec: AiGroupSpec in specs:
					var at: Vector2i = spec.spawn_point(0)
					var largest: int = 0
					var count: int = spec.unit_count(0)
					for entry: AiUnitEntry in spec.units:
						largest = maxi(largest, _catalog.find(entry.type_id).body_radius)
					var slots: Array[FormationSlot] = Formations.slots(Formations.Kind.BOX, count, at.x, at.y, spec.facing_x, spec.facing_z, Formations.spacing_for(largest))
					for slot: FormationSlot in slots:
						assert_true(t.is_passable(slot.x, slot.z, Terrain.Mobility.LIVING), "%s start %d %s slot %d, %d" % [m.id, start, spec.name, slot.x, slot.z])


func test_both_sides_ai() -> void:
	var s: SkirmishSetup = _setup(&"old_mill", CTF)
	s.player_is_ai = true
	var w: World = SkirmishSetup.create_world(s, _catalog)
	assert_eq(w.ai.commanders.size(), 2)
	assert_eq(w.ai.commanders[0].faction, LIGHT)
	assert_eq(w.ai.commanders[1].faction, DARK)
	assert_eq(w.ai.commanders[0].id, 1)
	assert_eq(w.ai.commanders[1].id, 2)
	w.step()
	for unit: Unit in w.units:
		assert_true(w.ai.controls(unit.id))
	assert_eq(_units(w, LIGHT).size(), s.armies[0].size())
	assert_eq(_units(w, DARK).size(), s.armies[1].size())


func test_it_refuses_what_it_cant_build() -> void:
	assert_null(SkirmishSetup.create_world(null, _catalog))
	assert_push_error("no setup or no catalog")
	var over: SkirmishSetup = _setup(&"riverside", BC)
	over.budget = 100
	assert_null(SkirmishSetup.create_world(over, _catalog))
	assert_push_error("over the budget")
	var wrong: SkirmishSetup = _setup(&"riverside", BC)
	wrong.armies.reverse()
	assert_null(SkirmishSetup.create_world(wrong, _catalog))
	assert_push_error("the player's army is on the wrong side")
	var spawn: SkirmishSetup = _setup(&"riverside", BC)
	spawn.player_spawn = 2
	assert_null(SkirmishSetup.create_world(spawn, _catalog))
	assert_push_error("player_spawn must be 0 or 1")
	var bare: SkirmishSetup = SkirmishSetup.new()
	var text: String = "\n".join(bare.validate(_catalog))
	for expected: String in ["map is missing", "rules are missing", "armies must be the player's and the AI's"]:
		assert_string_contains(text, expected)


func test_two_worlds_from_one_setup_stay_identical() -> void:
	# One mode per map, and a Dark player once; budget 600 and 1500 ticks keep
	# it quick.
	var cases: Array = [[&"riverside", BC, LIGHT], [&"the_ford", KOTH, DARK], [&"old_mill", CTF, LIGHT]]
	for c: Array in cases:
		var s: SkirmishSetup = _setup(c[0], c[1], c[2])
		var a: World = SkirmishSetup.create_world(s, _catalog)
		var b: World = SkirmishSetup.create_world(s, _catalog)
		var log_a: Array = []
		var log_b: Array = []
		for t: int in 1500:
			a.step()
			b.step()
			for e: AiEvent in a.ai_events:
				log_a.append(e.to_array())
			for e: AiEvent in b.ai_events:
				log_b.append(e.to_array())
			if t % 500 == 499:
				assert_eq(a.state_hash(), b.state_hash(), "%s mode %d at tick %d" % [c[0], c[1], a.tick])
		assert_eq(log_a, log_b, "%s: the AI decided the same" % c[0])
		var commanded: int = log_a.filter(func(e: PackedInt64Array) -> bool: return e[0] == AiEvent.Kind.COMMANDER).size()
		assert_gt(commanded, 0, "%s: the commander thought" % c[0])


func test_the_world_seed_is_the_setups() -> void:
	var s: SkirmishSetup = _setup(&"riverside", BC)
	s.world_seed = 123456
	var w: World = SkirmishSetup.create_world(s, _catalog)
	assert_eq(w.rng_seed, 123456)
