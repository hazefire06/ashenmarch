extends GutTest
## The data a campaign is made of: RosterEntry, MissionDef (and the problems
## validate() lists), CampaignDef, and MissionSetup, the one place a world is
## built from a MissionDef.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestTerrains.catalog()


# --- fixtures ---------------------------------------------------------------


func _entry(type_id: StringName, counts: PackedInt32Array = PackedInt32Array([1])) -> RosterEntry:
	return CampaignFixtures.entry(type_id, counts)


## A mission that validates: three Shieldmen and two Longbows at every tier.
func _valid() -> MissionDef:
	return CampaignFixtures.mission(&"riverside", [_entry(&"shieldman", PackedInt32Array([3])), _entry(&"longbow", PackedInt32Array([2]))])


func _errors(m: MissionDef) -> PackedStringArray:
	return m.validate(_catalog)


func _mentions(errors: PackedStringArray, fragment: String) -> bool:
	for e: String in errors:
		if e.contains(fragment):
			return true
	return false


func _assert_problem(m: MissionDef, fragment: String) -> void:
	var errors: PackedStringArray = _errors(m)
	assert_true(_mentions(errors, fragment), "expected a problem mentioning '%s', got %s" % [fragment, errors])


# --- RosterEntry ------------------------------------------------------------


func test_a_roster_entry_defaults_to_one_unit_that_carries_over() -> void:
	var e: RosterEntry = RosterEntry.new()
	assert_eq(e.type_id, &"")
	assert_eq(e.counts, PackedInt32Array([1]))
	assert_true(e.carryover)


func test_roster_entries_do_not_share_their_default_counts() -> void:
	var a: RosterEntry = RosterEntry.new()
	var b: RosterEntry = RosterEntry.new()
	a.counts[0] = 9
	assert_eq(b.counts, PackedInt32Array([1]))


# --- MissionDef defaults ------------------------------------------------------


func test_a_mission_defaults_face_south_in_a_box_with_the_camera_75_m_out() -> void:
	var m: MissionDef = MissionDef.new()
	assert_eq(m.deploy_facing_x, 0)
	assert_eq(m.deploy_facing_z, 1)
	assert_eq(m.deploy_formation, Formations.Kind.BOX)
	assert_eq(m.camera_distance, 75000)
	assert_null(m.atmosphere)
	assert_true(m.roster.is_empty())


# --- MissionDef.validate ------------------------------------------------------


func test_a_well_formed_mission_has_no_problems() -> void:
	assert_eq(_errors(_valid()), PackedStringArray())


func test_a_mission_needs_an_id_and_a_name() -> void:
	var m: MissionDef = _valid()
	m.id = &""
	_assert_problem(m, "id")
	m = _valid()
	m.display_name = ""
	_assert_problem(m, "display_name")


func test_a_mission_needs_a_map_and_rules() -> void:
	var m: MissionDef = _valid()
	m.map = null
	_assert_problem(m, "map")
	m = _valid()
	m.rules = null
	_assert_problem(m, "rules")


func test_the_rules_are_validated_too() -> void:
	var m: MissionDef = _valid()
	m.rules.groups.append(MissionFixtures.group(&"husks"))
	var errors: PackedStringArray = _errors(m)
	assert_true(_mentions(errors, "rules"), "the problem says it is in the rules: %s" % [errors])
	assert_true(_mentions(errors, "duplicate group name husks"), "and what it is: %s" % [errors])


func test_the_deploy_point_is_one_x_z_pair() -> void:
	for bad: Array in [[], [1000], [1000, 2000, 3000], [-1000, 2000]]:
		var m: MissionDef = _valid()
		m.deploy = PackedInt32Array(bad)
		_assert_problem(m, "deploy")


func test_the_camera_start_is_one_x_z_pair_and_the_distance_is_positive() -> void:
	for bad: Array in [[], [1000], [1000, 2000, 3000]]:
		var m: MissionDef = _valid()
		m.camera_start = PackedInt32Array(bad)
		_assert_problem(m, "camera_start")
	for bad_distance: int in [0, -5000]:
		var m: MissionDef = _valid()
		m.camera_distance = bad_distance
		_assert_problem(m, "camera_distance")


func test_the_deploy_formation_must_be_a_formation() -> void:
	var m: MissionDef = _valid()
	m.set(&"deploy_formation", 99)
	_assert_problem(m, "deploy_formation")


func test_a_mission_needs_a_roster() -> void:
	var m: MissionDef = _valid()
	m.roster = []
	_assert_problem(m, "roster")


func test_roster_entries_must_exist() -> void:
	var m: MissionDef = _valid()
	m.roster.append(null)
	_assert_problem(m, "roster entry 2 is null")


func test_a_roster_type_must_be_in_the_catalog() -> void:
	var m: MissionDef = _valid()
	m.roster.append(_entry(&"dragon"))
	_assert_problem(m, "dragon")


func test_a_roster_type_must_be_a_light_unit() -> void:
	for dark: StringName in [&"husk", &"ripper", &"blightbag", &"drifter", &"stormcaller"]:
		var m: MissionDef = _valid()
		m.roster.append(_entry(dark))
		_assert_problem(m, String(dark))


func test_the_villager_cannot_be_on_the_roster() -> void:
	var m: MissionDef = _valid()
	m.roster.append(_entry(&"villager"))
	_assert_problem(m, "villager")


func test_exactly_the_players_five_fighting_types_are_accepted() -> void:
	var accepted: Array[StringName] = []
	for t: UnitType in _catalog.types:
		var m: MissionDef = _valid()
		m.roster = [_entry(t.id)]
		if _errors(m).is_empty():
			accepted.append(t.id)
	var expected: Array[StringName] = [&"shieldman", &"reaver", &"longbow", &"sapper", &"warden"]
	accepted.sort()
	expected.sort()
	assert_eq(accepted, expected)


func test_counts_are_one_per_tier_or_one_for_all() -> void:
	for ok: Array in [[2], [1, 2, 3, 4, 5]]:
		var m: MissionDef = _valid()
		m.roster = [_entry(&"shieldman", PackedInt32Array(ok))]
		assert_eq(_errors(m), PackedStringArray(), str(ok))
	for bad: Array in [[], [1, 2], [1, 2, 3, 4]]:
		var m: MissionDef = _valid()
		m.roster = [_entry(&"shieldman", PackedInt32Array(bad))]
		_assert_problem(m, "counts")


func test_counts_cannot_be_negative() -> void:
	var m: MissionDef = _valid()
	m.roster = [_entry(&"shieldman", PackedInt32Array([3, 3, -1, 3, 3]))]
	_assert_problem(m, "negative")


func test_every_tier_must_deploy_someone_or_the_player_is_never_seen() -> void:
	var m: MissionDef = _valid()
	m.roster = [_entry(&"shieldman", PackedInt32Array([0, 2, 2, 2, 2]))]
	_assert_problem(m, "tier 0")
	m.roster = [_entry(&"shieldman", PackedInt32Array([0]))]
	var errors: PackedStringArray = _errors(m)
	for tier: int in Difficulty.TIERS:
		assert_true(_mentions(errors, "tier %d" % tier), "tier %d" % tier)


func test_another_entry_can_cover_a_tier_the_first_leaves_empty() -> void:
	var m: MissionDef = _valid()
	m.roster = [
		_entry(&"shieldman", PackedInt32Array([0, 0, 2, 2, 2])),
		_entry(&"reaver", PackedInt32Array([1, 1, 0, 0, 0])),
	]
	assert_eq(_errors(m), PackedStringArray())


func test_an_invalid_atmosphere_is_reported() -> void:
	var m: MissionDef = _valid()
	m.atmosphere = Atmosphere.new()
	assert_eq(_errors(m), PackedStringArray(), "the default is valid")
	m.atmosphere.sun_energy = -1.0
	_assert_problem(m, "atmosphere")
	_assert_problem(m, "sun_energy")


func test_validate_lists_every_problem_not_just_the_first() -> void:
	var m: MissionDef = _valid()
	m.id = &""
	m.display_name = ""
	m.map = null
	m.rules = null
	m.deploy = PackedInt32Array()
	m.roster = [_entry(&"husk")]
	assert_gte(_errors(m).size(), 6, "%s" % [_errors(m)])


# --- CampaignDef ------------------------------------------------------------


func _campaign() -> CampaignDef:
	return CampaignFixtures.campaign([_valid(), CampaignFixtures.mission(&"the_ford", [_entry(&"shieldman")])])


func test_a_campaign_def_wants_fifty_names() -> void:
	assert_eq(CampaignDef.MIN_NAMES, 50)
	assert_eq(_campaign().validate(_catalog), PackedStringArray())
	var c: CampaignDef = _campaign()
	c.soldier_names.resize(49)
	assert_true(_mentions(c.validate(_catalog), "soldier_names"))


func test_a_campaign_def_needs_missions_with_unique_ids() -> void:
	var empty: CampaignDef = CampaignFixtures.campaign([])
	assert_true(_mentions(empty.validate(_catalog), "mission"))
	var twice: CampaignDef = CampaignFixtures.campaign([_valid(), _valid()])
	assert_true(_mentions(twice.validate(_catalog), "duplicate mission id riverside"))
	var holey: CampaignDef = _campaign()
	holey.missions.append(null)
	assert_true(_mentions(holey.validate(_catalog), "mission 2 is null"))


func test_a_campaign_def_reports_its_missions_problems_by_mission() -> void:
	var c: CampaignDef = _campaign()
	c.missions[1].roster = [_entry(&"husk")]
	var errors: PackedStringArray = c.validate(_catalog)
	assert_true(_mentions(errors, "the_ford"), "%s" % [errors])
	assert_true(_mentions(errors, "husk"), "%s" % [errors])


func test_campaign_names_must_be_filled_in_and_distinct() -> void:
	var c: CampaignDef = _campaign()
	c.soldier_names[3] = ""
	assert_true(_mentions(c.validate(_catalog), "empty"))
	c = _campaign()
	c.soldier_names[4] = c.soldier_names[9]
	assert_true(_mentions(c.validate(_catalog), "twice"))


# --- MissionSetup -------------------------------------------------------------


## A Riverside mission deploying 3 Shieldmen and 2 Longbows on the north bank.
func _setup_mission() -> MissionDef:
	return CampaignFixtures.mission(
		&"setup", [_entry(&"shieldman", PackedInt32Array([3])), _entry(&"longbow", PackedInt32Array([2]))], 290, 185
	)


func _deploy_for(m: MissionDef, state: CampaignState = null) -> DeployCommand:
	var campaign_state: CampaignState = state if state != null else CampaignState.new_campaign(5, 2)
	return campaign_state.plan_deploy(m, PackedInt32Array(), CampaignFixtures.names()).command(0, m)


func test_a_world_is_built_from_the_mission_with_the_deploy_in_it() -> void:
	var m: MissionDef = _setup_mission()
	var world: World = MissionSetup.create_world(m, 3, 99, _deploy_for(m), _catalog)
	assert_not_null(world)
	if world == null:
		return
	assert_eq(world.tick, 0, "nothing has stepped")
	assert_eq(world.rng_seed, 99)
	assert_not_null(world.mission)
	assert_eq(world.mission.tier, 3)
	assert_eq(world.terrain.size_x, 512, "Riverside's ground")
	world.step()
	var soldiers: Array[Unit] = []
	for u: Unit in world.units:
		if u.soldier_id != 0:
			soldiers.append(u)
	assert_eq(soldiers.size(), 5, "the deploy landed")
	for u: Unit in soldiers:
		assert_eq(u.faction, LIGHT)
		assert_lt(absi(u.x - 290 * M), 8 * M, "around the deploy point")
		assert_lt(absi(u.z - 185 * M), 8 * M)
	var types: Array[StringName] = []
	for u: Unit in soldiers:
		types.append(u.type.id)
	assert_eq(types, [&"shieldman", &"shieldman", &"shieldman", &"longbow", &"longbow"] as Array[StringName], "roster order")
	assert_eq(soldiers[0].soldier_id, 1)
	assert_eq(soldiers[4].soldier_id, 5)


func test_the_deploy_comes_first_then_the_herb_plants_then_the_missions_groups() -> void:
	var m: MissionDef = _setup_mission()
	var world: World = MissionSetup.create_world(m, 2, 1, _deploy_for(m), _catalog)
	world.step()
	var herbs: PackedInt32Array = m.map.herb_plants
	assert_eq(world.herb_plants.size(), herbs.size() >> 1, "the map's herb plants are planted")
	assert_gt(world.herb_plants.size(), 0)
	for k: int in world.herb_plants.size():
		var plant: HerbPlant = world.herb_plants[k]
		assert_eq(plant.x, herbs[2 * k])
		assert_eq(plant.z, herbs[2 * k + 1])
	var first_unit_id: int = world.units[0].id
	assert_eq(first_unit_id, 1, "the soldiers are entities 1..5")
	assert_eq(world.herb_plants[0].id, 6, "the herb plants follow")
	var husk_ids: Array[int] = []
	for u: Unit in world.units:
		if u.faction == DARK:
			husk_ids.append(u.id)
	assert_eq(husk_ids[0], 6 + world.herb_plants.size(), "and the groups spawn after them")


func test_the_mission_runs_in_the_world_it_built() -> void:
	var m: MissionDef = _setup_mission()
	m.rules.groups[0] = MissionFixtures.group(&"husks", 4, 100, 100)
	var world: World = MissionSetup.create_world(m, 0, 1, _deploy_for(m), _catalog)
	world.step()
	var husks: int = 0
	for u: Unit in world.units:
		husks += 1 if u.faction == DARK else 0
	assert_eq(husks, 4, "the script's starting group spawned")


func test_two_worlds_built_alike_stay_alike() -> void:
	var m: MissionDef = _setup_mission()
	var a: World = MissionSetup.create_world(m, 2, 7, _deploy_for(m), _catalog)
	var b: World = MissionSetup.create_world(m, 2, 7, _deploy_for(m), _catalog)
	for _t: int in 40:
		a.step()
		b.step()
	assert_eq(a.state_hash(), b.state_hash())


func test_a_mission_without_a_map_builds_no_world() -> void:
	var m: MissionDef = _setup_mission()
	var command: DeployCommand = _deploy_for(m)
	m.map = null
	assert_null(MissionSetup.create_world(m, 2, 1, command, _catalog))
	assert_push_error("MissionSetup")


func test_a_map_that_cannot_be_loaded_builds_no_world() -> void:
	var m: MissionDef = _setup_mission()
	var command: DeployCommand = _deploy_for(m)
	m.map = MapInfo.new()
	assert_null(MissionSetup.create_world(m, 2, 1, command, _catalog))
	assert_push_error_count(2)


func test_a_missing_mission_deploy_or_catalog_builds_no_world() -> void:
	var m: MissionDef = _setup_mission()
	assert_null(MissionSetup.create_world(null, 2, 1, _deploy_for(m), _catalog))
	assert_null(MissionSetup.create_world(m, 2, 1, null, _catalog))
	assert_null(MissionSetup.create_world(m, 2, 1, _deploy_for(m), null))
	assert_push_error_count(3)


func test_a_tier_out_of_range_or_a_bad_script_builds_no_world() -> void:
	var m: MissionDef = _setup_mission()
	var command: DeployCommand = _deploy_for(m)
	assert_null(MissionSetup.create_world(m, 5, 1, command, _catalog))
	var bad: MissionDef = _setup_mission()
	bad.rules.groups.append(MissionFixtures.group(&"husks"))
	assert_null(MissionSetup.create_world(bad, 2, 1, command, _catalog))
	assert_push_error_count(2)
