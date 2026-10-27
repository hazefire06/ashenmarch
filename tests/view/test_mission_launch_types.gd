extends GutTest
## MissionLaunch.unit_types: the types a launch can bring onto the field, which
## MainView loads art for before the first frame. The golden replays pin that
## nothing in a real game fields a type the list missed.


func test_a_mission_brings_its_roster_and_every_group_of_its_script() -> void:
	var mission: MissionDef = load("res://data/missions/old_mill/mission.tres") as MissionDef
	var types: Array[StringName] = MissionLaunch.new(mission, 4, 1).unit_types()
	for entry: RosterEntry in mission.roster:
		assert_has(types, entry.type_id)
	for group: AiGroupSpec in mission.rules.groups:
		for unit_entry: AiUnitEntry in group.units:
			assert_has(types, unit_entry.type_id)
	assert_eq(types.size(), 10, "Old Mill can field every v1 type")


func test_riverside_brings_six_types() -> void:
	var mission: MissionDef = load("res://data/missions/riverside/mission.tres") as MissionDef
	assert_eq(Array(MissionLaunch.new(mission, 2, 1).unit_types()), [&"husk", &"longbow", &"reaver", &"ripper", &"sapper", &"shieldman"])


func test_the_deploy_adds_its_types() -> void:
	var launch: MissionLaunch = ViewFixtures.launch()
	launch.deploy.type_ids.append(&"warden")
	assert_has(launch.unit_types(), &"warden")


func test_a_skirmish_brings_both_armies() -> void:
	assert_eq(Array(MissionLaunch.for_skirmish(ViewFixtures.skirmish_setup()).unit_types()), [&"husk", &"shieldman"])


func test_a_launch_of_neither_brings_nothing() -> void:
	assert_eq(MissionLaunch.new().unit_types().size(), 0)


func test_the_list_is_sorted_with_no_repeats() -> void:
	var mission: MissionDef = load("res://data/missions/the_ford/mission.tres") as MissionDef
	var types: Array[StringName] = MissionLaunch.new(mission, 2, 1).unit_types()
	var sorted: Array[StringName] = types.duplicate()
	sorted.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	assert_eq(types, sorted)
	for type_id: StringName in types:
		assert_eq(types.count(type_id), 1, "%s once" % type_id)


func test_no_golden_replay_fields_a_type_its_launch_did_not_list() -> void:
	var units: UnitCatalog = load(App.CATALOG_PATH) as UnitCatalog
	var paths: PackedStringArray = ReplayVerifier.golden_paths()
	assert_gt(paths.size(), 0)
	for path: String in paths:
		var replay: Replay = ReplayStore.load_file(path)
		assert_not_null(replay, path)
		var launch: MissionLaunch = MissionLaunch.for_replay(replay)
		assert_not_null(launch, path)
		var listed: Array[StringName] = launch.unit_types()
		var player: ReplayPlayer = ReplayPlayer.new(replay, units)
		var seen: Dictionary[StringName, bool] = {}
		while not player.is_done():
			player.step()
			for unit: Unit in player.world.units:
				seen[unit.type.id] = true
		for type_id: StringName in seen:
			assert_has(listed, type_id, "%s fields %s" % [path.get_file(), type_id])
