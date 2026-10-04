extends GutTest
## CampaignState and what it hands around: Soldier records, the DeployPlan a
## mission starts from (veterans fill same-type carryover slots, most kills
## first; empty slots get recruits with provisional ids), what winning commits
## (recruits join, survivors keep kills and wounds, the dead and the converted
## fall), and the JSON form a save file holds.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const SHIELDMAN: StringName = &"shieldman"
const LONGBOW: StringName = &"longbow"
const REAVER: StringName = &"reaver"
const WARDEN: StringName = &"warden"

var _names: PackedStringArray


func before_each() -> void:
	_names = CampaignFixtures.names()


# --- fixtures ---------------------------------------------------------------


func _entry(type_id: StringName, count: int = 1, carryover: bool = true) -> RosterEntry:
	return CampaignFixtures.entry(type_id, PackedInt32Array([count]), carryover)


func _soldier(id: int, type_id: StringName, kills: int = 0, hp: int = 0) -> Soldier:
	return CampaignFixtures.soldier(id, type_id, kills, hp)


func _ids(soldiers: Array[Soldier]) -> Array[int]:
	var out: Array[int] = []
	for s: Soldier in soldiers:
		out.append(s.id)
	return out


func _slot_ids(plan: DeployPlan) -> Array[int]:
	var out: Array[int] = []
	out.assign(plan.soldier_ids)
	return out


func _json(state: CampaignState) -> String:
	return JSON.stringify(state.to_dict())


## What a save file reads back as: the state's dictionary through JSON text.
func _parsed(state: CampaignState) -> Dictionary:
	return JSON.parse_string(JSON.stringify(state.to_dict())) as Dictionary


## A state with a bit of everything, for the JSON tests.
func _busy_state(campaign_seed: int = 12345) -> CampaignState:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 7, 40), _soldier(2, LONGBOW, 0, 0), _soldier(5, WARDEN, 3, 60),
	], 3, campaign_seed)
	var lost: Soldier = _soldier(3, REAVER, 2, 0)
	lost.fallen_in = &"riverside"
	lost.missions = 1
	state.fallen.append(lost)
	state.next_soldier_id = 6
	state.mission_index = 1
	state.history.append({"id": "riverside", "ticks": 9000, "kills": 14, "losses": 1})
	return state


# --- Soldier ------------------------------------------------------------------


func test_a_soldier_starts_alive_with_no_kills_and_full_health() -> void:
	var s: Soldier = Soldier.new(4, SHIELDMAN, "Cole")
	assert_eq(s.id, 4)
	assert_eq(s.type_id, SHIELDMAN)
	assert_eq(s.name, "Cole")
	assert_eq(s.kills, 0)
	assert_eq(s.hp, 0, "0 is full health, as in DeployCommand")
	assert_eq(s.missions, 0)
	assert_eq(s.fallen_in, &"")


func test_a_soldier_round_trips_through_its_dictionary() -> void:
	var s: Soldier = _soldier(9, WARDEN, 12, 33)
	s.missions = 2
	s.fallen_in = &"the_ford"
	var back: Soldier = Soldier.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	assert_not_null(back)
	assert_eq(back.id, 9)
	assert_eq(back.type_id, WARDEN)
	assert_eq(back.name, "Soldier 9")
	assert_eq(back.kills, 12)
	assert_eq(back.hp, 33)
	assert_eq(back.missions, 2)
	assert_eq(back.fallen_in, &"the_ford")
	assert_typeof(back.id, TYPE_INT, "JSON numbers come back as floats; the record holds ints")
	assert_typeof(back.type_id, TYPE_STRING_NAME)


func test_a_malformed_soldier_record_is_refused_with_the_reason() -> void:
	var good: Dictionary = _soldier(9, WARDEN, 12, 33).to_dict()
	var cases: Dictionary[String, Variant] = {
		"id": 0, "type_id": "", "name": 5, "kills": -1, "hp": -2, "missions": 1.5, "fallen_in": 7,
	}
	for key: String in cases:
		var bad: Dictionary = good.duplicate()
		bad[key] = cases[key]
		var errors: PackedStringArray = PackedStringArray()
		assert_null(Soldier.from_dict(bad, errors), "%s = %s" % [key, cases[key]])
		assert_eq(errors.size(), 1, key)
		if errors.size() == 1:
			assert_string_contains(errors[0], key)
		var missing: Dictionary = good.duplicate()
		missing.erase(key)
		var missing_errors: PackedStringArray = PackedStringArray()
		assert_null(Soldier.from_dict(missing, missing_errors), "no %s" % key)
		assert_eq(missing_errors.size(), 1, "no %s" % key)
	var not_a_record: PackedStringArray = PackedStringArray()
	assert_null(Soldier.from_dict("soldier", not_a_record))
	assert_eq(not_a_record.size(), 1)


func test_a_number_too_big_to_be_exact_is_not_a_whole_number() -> void:
	assert_true(Soldier.is_whole_number(7))
	assert_true(Soldier.is_whole_number(7.0))
	assert_false(Soldier.is_whole_number(7.5))
	assert_false(Soldier.is_whole_number(1e300))
	assert_false(Soldier.is_whole_number("7"))
	assert_false(Soldier.is_whole_number(null))
	var errors: PackedStringArray = PackedStringArray()
	var record: Dictionary = _soldier(9, WARDEN).to_dict()
	record["kills"] = 1e300
	assert_null(Soldier.from_dict(record, errors))
	assert_eq(errors.size(), 1)


# --- a new campaign -----------------------------------------------------------


func test_a_new_campaign_is_empty_and_at_the_first_mission() -> void:
	var state: CampaignState = CampaignState.new_campaign(77, 3)
	assert_eq(state.campaign_seed, 77)
	assert_eq(state.tier, 3)
	assert_eq(state.mission_index, 0)
	assert_eq(state.next_soldier_id, 1, "0 means not a campaign soldier, so ids start at 1")
	assert_true(state.soldiers.is_empty())
	assert_true(state.fallen.is_empty())
	assert_true(state.history.is_empty())


func test_a_new_campaigns_tier_is_kept_within_the_five_tiers() -> void:
	assert_eq(CampaignState.new_campaign(1, -3).tier, 0)
	assert_eq(CampaignState.new_campaign(1, 9).tier, Difficulty.TIERS - 1)


func test_a_campaign_is_complete_when_every_mission_is_won() -> void:
	var campaign: CampaignDef = CampaignFixtures.campaign([
		CampaignFixtures.mission(&"one", [_entry(SHIELDMAN)]),
		CampaignFixtures.mission(&"two", [_entry(SHIELDMAN)]),
	])
	var state: CampaignState = CampaignState.new_campaign(1, 2)
	assert_false(state.is_complete(campaign))
	state.mission_index = 1
	assert_false(state.is_complete(campaign))
	state.mission_index = 2
	assert_true(state.is_complete(campaign))


# --- mission_seed ---------------------------------------------------------------


func test_a_missions_seed_is_the_same_every_time_so_a_retry_replays_the_waves() -> void:
	var state: CampaignState = CampaignState.new_campaign(424242, 2)
	for index: int in 5:
		assert_eq(state.mission_seed(index), state.mission_seed(index))
	assert_eq(CampaignState.new_campaign(424242, 0).mission_seed(2), state.mission_seed(2), "tier doesn't enter it")


func test_each_mission_of_a_campaign_gets_its_own_seed() -> void:
	var state: CampaignState = CampaignState.new_campaign(424242, 2)
	var seen: Dictionary[int, bool] = {}
	for index: int in 200:
		var s: int = state.mission_seed(index)
		assert_false(seen.has(s), "index %d repeats an earlier seed" % index)
		seen[s] = true


func test_different_campaign_seeds_give_different_mission_seeds() -> void:
	var seen: Dictionary[int, bool] = {}
	for campaign_seed: int in range(1, 201):
		var s: int = CampaignState.new_campaign(campaign_seed, 2).mission_seed(0)
		assert_false(seen.has(s), "campaign seed %d repeats an earlier seed" % campaign_seed)
		seen[s] = true


func test_seeds_that_differ_in_one_high_or_low_bit_do_not_collide() -> void:
	var base: int = 0x1234567812345678
	var seen: Dictionary[int, bool] = {}
	for bit: int in 63:
		var s: int = CampaignState.new_campaign(base ^ (1 << bit), 2).mission_seed(1)
		assert_false(seen.has(s), "bit %d collides" % bit)
		seen[s] = true


func test_a_mission_seed_is_never_negative_even_from_a_negative_campaign_seed() -> void:
	for campaign_seed: int in [0, 1, -1, 9223372036854775807, -9223372036854775807, 0x2545F4914F6CDD1D]:
		for index: int in 4:
			assert_gte(CampaignState.new_campaign(campaign_seed, 2).mission_seed(index), 0)


func test_mission_seeds_are_pinned() -> void:
	# The mix is integer-only, with every product under 2^63, so these hold on
	# every platform (they were checked against an independent Python
	# implementation of the same steps, for negative and 2^53+1 seeds too). A
	# change here re-rolls every campaign's missions: treat the numbers as part
	# of the save format.
	var state: CampaignState = CampaignState.new_campaign(12345, 2)
	assert_eq(state.mission_seed(0), 8709232887400433624)
	assert_eq(state.mission_seed(1), 3033101676260329702)
	assert_eq(state.mission_seed(2), 6894688919407694388)
	assert_eq(CampaignState.new_campaign(-1, 2).mission_seed(0), 2007352174118566558)
	assert_eq(CampaignState.new_campaign(9007199254740993, 2).mission_seed(3), 5274038053317070589)
	assert_eq(CampaignState.new_campaign(-9223372036854775807, 2).mission_seed(2), 5740578832884705578)


# --- soldier names ----------------------------------------------------------------


func test_names_follow_the_id_and_a_numeral_marks_each_lap_of_the_list() -> void:
	var names: PackedStringArray = PackedStringArray(["Ada", "Bram", "Cole"])
	assert_eq(CampaignState.name_for(1, names), "Bram")
	assert_eq(CampaignState.name_for(2, names), "Cole")
	assert_eq(CampaignState.name_for(3, names), "Ada II", "id 3 wraps the three names for the first time")
	assert_eq(CampaignState.name_for(4, names), "Bram II")
	assert_eq(CampaignState.name_for(6, names), "Ada III")
	assert_eq(CampaignState.name_for(9, names), "Ada IV")
	assert_eq(CampaignState.name_for(27, names), "Ada X")
	assert_eq(CampaignState.name_for(3 * 49 + 1, names), "Bram L", "49 laps on: roman numerals keep going")


func test_names_are_the_plain_name_until_the_list_wraps() -> void:
	var names: PackedStringArray = CampaignFixtures.names(50)
	for id: int in range(1, 50):
		assert_eq(CampaignState.name_for(id, names), names[id])


func test_with_no_names_a_soldier_is_numbered() -> void:
	assert_eq(CampaignState.name_for(7, PackedStringArray()), "Soldier 7")


# --- plan_deploy: who fills the slots ----------------------------------------------


func test_a_fresh_campaign_deploys_only_recruits_numbered_from_one() -> void:
	var state: CampaignState = CampaignState.new_campaign(7, 2)
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 3), _entry(LONGBOW, 2)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(plan.size(), 5)
	assert_eq(_slot_ids(plan), [1, 2, 3, 4, 5])
	assert_eq(plan.type_ids, [SHIELDMAN, SHIELDMAN, SHIELDMAN, LONGBOW, LONGBOW] as Array[StringName])
	assert_eq(plan.is_recruit, [true, true, true, true, true] as Array[bool])
	assert_eq(plan.names, PackedStringArray(["Bram", "Cole", "Dara", "Eben", "Ada II"]))
	assert_eq(plan.kills, PackedInt32Array([0, 0, 0, 0, 0]))
	assert_eq(plan.hp, PackedInt32Array([0, 0, 0, 0, 0]), "a recruit is at full health: hp 0")
	assert_eq(_ids(plan.recruits), [1, 2, 3, 4, 5])
	assert_eq(plan.recruits[0].name, "Bram")
	assert_eq(plan.recruits[0].type_id, SHIELDMAN)


func test_veterans_fill_a_type_most_kills_first_then_healthiest_then_lowest_id() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 3, 50),
		_soldier(2, SHIELDMAN, 5, 40),
		_soldier(3, SHIELDMAN, 5, 70),
		_soldier(4, SHIELDMAN, 5, 70),
		_soldier(5, SHIELDMAN, 5, 0),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 5)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	# 5: full health (hp 0 sorts as healthiest); 3 and 4 tie on hp, lowest id
	# first; 2 is the most wounded of the five-kill men; 1 has fewer kills.
	assert_eq(_slot_ids(plan), [5, 3, 4, 2, 1])
	assert_eq(plan.is_recruit, [false, false, false, false, false] as Array[bool])
	assert_eq(plan.kills, PackedInt32Array([5, 5, 5, 5, 3]), "a veteran deploys with the kills he has")
	assert_eq(plan.hp, PackedInt32Array([0, 70, 70, 40, 50]), "and the wounds he has")
	assert_true(plan.recruits.is_empty())


func test_a_full_health_veteran_outranks_a_wounded_one_with_the_same_kills() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, LONGBOW, 2, 30), _soldier(2, LONGBOW, 2, 0)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(LONGBOW, 1)])
	assert_eq(_slot_ids(state.plan_deploy(mission, PackedInt32Array(), _names)), [2])


func test_only_soldiers_of_the_slots_type_fill_it() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, LONGBOW, 9), _soldier(2, SHIELDMAN, 0), _soldier(3, WARDEN, 4),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(_slot_ids(plan), [2, 4], "the Shieldman, then a recruit with the next id (4, after 1..3)")
	assert_eq(plan.is_recruit, [false, true] as Array[bool])


func test_extra_veterans_go_to_reserve_and_the_best_deploy() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 1), _soldier(2, SHIELDMAN, 8), _soldier(3, SHIELDMAN, 4),
		_soldier(4, SHIELDMAN, 0), _soldier(5, SHIELDMAN, 6),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(_slot_ids(plan), [2, 5])
	assert_eq(_ids(state.reserve_for(mission, PackedInt32Array())), [1, 3, 4], "the rest wait, in pool order")


func test_empty_slots_are_filled_with_recruits_after_the_veterans() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 3), _soldier(2, SHIELDMAN, 1)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 4)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(_slot_ids(plan), [1, 2, 3, 4], "recruits take ids 3 and 4, the next two")
	assert_eq(plan.is_recruit, [false, false, true, true] as Array[bool])
	assert_eq(_ids(plan.recruits), [3, 4])
	assert_true(state.reserve_for(mission, PackedInt32Array()).is_empty())


func test_a_slot_that_does_not_carry_over_is_always_a_recruit() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, WARDEN, 6), _soldier(2, SHIELDMAN, 2)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 1), _entry(WARDEN, 1, false)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(plan.type_ids, [SHIELDMAN, WARDEN] as Array[StringName])
	assert_eq(plan.is_recruit, [false, true] as Array[bool])
	assert_eq(_slot_ids(plan), [2, 3])
	assert_eq(_ids(state.reserve_for(mission, PackedInt32Array())), [1], "the Warden veteran sits this one out")


func test_benching_a_veteran_puts_him_in_reserve_and_the_next_one_takes_the_slot() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 9), _soldier(2, SHIELDMAN, 5), _soldier(3, SHIELDMAN, 1),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2)])
	var benched: PackedInt32Array = PackedInt32Array([1])
	assert_eq(_slot_ids(state.plan_deploy(mission, benched, _names)), [2, 3])
	assert_eq(_ids(state.reserve_for(mission, benched)), [1])


func test_benching_the_only_veteran_gives_the_slot_to_a_recruit() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, LONGBOW, 9)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(LONGBOW, 1)])
	var benched: PackedInt32Array = PackedInt32Array([1])
	var plan: DeployPlan = state.plan_deploy(mission, benched, _names)
	assert_eq(_slot_ids(plan), [2])
	assert_eq(plan.is_recruit, [true] as Array[bool])
	assert_eq(_ids(state.reserve_for(mission, benched)), [1])


func test_benching_a_soldier_who_would_not_deploy_anyway_changes_nothing() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 9), _soldier(2, SHIELDMAN, 1)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 1)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array([2]), _names)
	assert_eq(_slot_ids(plan), [1])


func test_a_type_listed_twice_does_not_deploy_the_same_soldier_twice() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 9), _soldier(2, SHIELDMAN, 5), _soldier(3, SHIELDMAN, 1),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2), _entry(SHIELDMAN, 2)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(_slot_ids(plan), [1, 2, 3, 4], "the second entry gets the third veteran, then a recruit")
	assert_eq(plan.is_recruit, [false, false, false, true] as Array[bool])


func test_the_tier_picks_each_entrys_count() -> void:
	var counts: PackedInt32Array = PackedInt32Array([1, 2, 3, 4, 5])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [CampaignFixtures.entry(SHIELDMAN, counts)])
	for tier: int in Difficulty.TIERS:
		var state: CampaignState = CampaignState.new_campaign(1, tier)
		assert_eq(state.plan_deploy(mission, PackedInt32Array(), _names).size(), tier + 1, "tier %d" % tier)


func test_recruit_ids_never_reuse_a_fallen_soldiers() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 1)])
	var dead: Soldier = _soldier(2, SHIELDMAN, 3)
	dead.fallen_in = &"m"
	state.fallen.append(dead)
	state.next_soldier_id = 3
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2)])
	assert_eq(_slot_ids(state.plan_deploy(mission, PackedInt32Array(), _names)), [1, 3])


func test_planning_changes_nothing_so_two_plans_agree() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 2, 40)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 3), _entry(LONGBOW, 2)])
	var before: String = _json(state)
	var first: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	var second: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(_json(state), before, "no recruit is committed by planning")
	assert_eq(state.next_soldier_id, 2)
	assert_eq(_slot_ids(first), _slot_ids(second))
	assert_eq(first.names, second.names)
	assert_eq(_slot_ids(first), [1, 2, 3, 4, 5])


func test_plan_deploy_builds_the_command_for_the_mission() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, LONGBOW, 4, 55)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2), _entry(LONGBOW, 1)], 70, 30)
	mission.deploy_facing_x = 1
	mission.deploy_facing_z = -1
	mission.deploy_formation = Formations.Kind.WEDGE
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	var command: DeployCommand = plan.command(12, mission)
	assert_eq(command.tick, 12)
	assert_eq(command.type_ids, [SHIELDMAN, SHIELDMAN, LONGBOW] as Array[StringName], "roster order")
	assert_eq(command.soldier_ids, PackedInt32Array([2, 3, 1]), "recruits 2 and 3, then the veteran")
	assert_eq(command.kills, PackedInt32Array([0, 0, 4]))
	assert_eq(command.hp, PackedInt32Array([0, 0, 55]))
	assert_eq(command.x, 70 * M)
	assert_eq(command.z, 30 * M)
	assert_eq(command.facing_x, 1)
	assert_eq(command.facing_z, -1)
	assert_eq(command.formation, Formations.Kind.WEDGE)
	assert_eq(command.faction, LIGHT)


func test_the_planned_command_puts_the_veterans_into_the_world_as_they_were() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 6, 41)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2)])
	var world: World = CampaignFixtures.deployed_world(state.plan_deploy(mission, PackedInt32Array(), _names), mission)
	var veteran: Unit = CampaignFixtures.unit_of(world, 1)
	var recruit: Unit = CampaignFixtures.unit_of(world, 2)
	assert_eq(world.units.size(), 2)
	assert_eq(veteran.kills, 6)
	assert_eq(veteran.hp, 41)
	assert_eq(recruit.kills, 0)
	assert_eq(recruit.hp, recruit.type.max_hp)
	assert_eq(veteran.faction, LIGHT)


# --- apply_victory ----------------------------------------------------------------


## Plans, deploys, and returns the pieces apply_victory needs.
func _play(state: CampaignState, mission: MissionDef, benched: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var plan: DeployPlan = state.plan_deploy(mission, benched, _names)
	var world: World = CampaignFixtures.deployed_world(plan, mission)
	var stats: MissionStats = MissionStats.new()
	stats.begin(world)
	return {"plan": plan, "world": world, "stats": stats}


## Runs the world `ticks` more ticks (none by default: a test that has put the
## world in the state it wants shouldn't let the units fight on) and closes the
## stats, then commits the win.
func _win(state: CampaignState, mission: MissionDef, played: Dictionary, ticks: int = 0) -> void:
	var world: World = played["world"]
	var stats: MissionStats = played["stats"]
	for _t: int in ticks:
		world.step()
		stats.observe(world)
	stats.finish(world)
	state.apply_victory(mission, played["plan"], world, stats)


func test_winning_commits_the_recruits_and_advances_the_ids() -> void:
	var state: CampaignState = CampaignState.new_campaign(7, 2)
	var mission: MissionDef = CampaignFixtures.mission(&"riverside", [_entry(SHIELDMAN, 2), _entry(LONGBOW, 1)])
	var played: Dictionary = _play(state, mission)
	assert_true(state.soldiers.is_empty(), "nothing is committed until the win")
	_win(state, mission, played)
	assert_eq(_ids(state.soldiers), [1, 2, 3])
	assert_eq(state.next_soldier_id, 4)
	assert_eq(state.soldiers[0].name, "Bram")
	assert_eq(state.soldiers[2].type_id, LONGBOW)
	for s: Soldier in state.soldiers:
		assert_eq(s.missions, 1, "each survived one mission")
		assert_eq(s.hp, 0, "unhurt: full health")
	assert_eq(state.mission_index, 1)
	assert_true(state.fallen.is_empty())


func test_the_next_mission_deploys_last_missions_survivors_and_numbers_new_recruits_after_them() -> void:
	var state: CampaignState = CampaignState.new_campaign(7, 2)
	var first: MissionDef = CampaignFixtures.mission(&"one", [_entry(SHIELDMAN, 2)])
	var played: Dictionary = _play(state, first)
	CampaignFixtures.unit_of(played["world"], 2).kills = 4
	_win(state, first, played)
	var second: MissionDef = CampaignFixtures.mission(&"two", [_entry(SHIELDMAN, 3)])
	var plan: DeployPlan = state.plan_deploy(second, PackedInt32Array(), _names)
	assert_eq(_slot_ids(plan), [2, 1, 3], "the four-kill man first, then his comrade, then a recruit")
	assert_eq(plan.kills, PackedInt32Array([4, 0, 0]))


func test_survivors_keep_the_kills_and_wounds_they_ended_with() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 4), _soldier(2, LONGBOW, 1, 30)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 1), _entry(LONGBOW, 1)])
	var played: Dictionary = _play(state, mission)
	var world: World = played["world"]
	var shield: Unit = CampaignFixtures.unit_of(world, 1)
	shield.kills = 6
	shield.hp = 55
	var bow: Unit = CampaignFixtures.unit_of(world, 2)
	bow.hp = bow.type.max_hp
	_win(state, mission, played)
	var first: Soldier = state.soldiers[0]
	assert_eq(first.kills, 6)
	assert_eq(first.hp, 55)
	assert_eq(first.missions, 1)
	var second: Soldier = state.soldiers[1]
	assert_eq(second.kills, 1)
	assert_eq(second.hp, 0, "healed back to full: stored as full (0), so a later change to max_hp can't strand him wounded")


func test_the_dead_and_the_converted_fall_and_are_remembered_where() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 5), _soldier(2, SHIELDMAN, 3), _soldier(3, SHIELDMAN, 2), _soldier(4, LONGBOW, 1),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"the_ford", [_entry(SHIELDMAN, 3), _entry(LONGBOW, 1)])
	var played: Dictionary = _play(state, mission)
	var world: World = played["world"]
	var dead: Unit = CampaignFixtures.unit_of(world, 2)
	dead.kills = 7
	dead.kill()
	CampaignFixtures.unit_of(world, 3).faction = DARK
	_win(state, mission, played)
	assert_eq(_ids(state.soldiers), [1, 4])
	assert_eq(_ids(state.fallen), [2, 3])
	for s: Soldier in state.fallen:
		assert_eq(s.fallen_in, &"the_ford")
		assert_eq(s.missions, 0, "missions counts those survived")
	assert_eq(state.fallen[0].kills, 7, "the kills they made before they fell are kept with them")


func test_the_reserve_is_untouched_by_a_win() -> void:
	var state: CampaignState = CampaignFixtures.state([
		_soldier(1, SHIELDMAN, 9), _soldier(2, SHIELDMAN, 0, 33), _soldier(3, WARDEN, 4, 20),
	])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 1)])
	var played: Dictionary = _play(state, mission)
	_win(state, mission, played)
	assert_eq(_ids(state.soldiers), [1, 2, 3])
	assert_eq(state.soldiers[0].missions, 1)
	for k: int in [1, 2]:
		assert_eq(state.soldiers[k].missions, 0, "didn't deploy, so didn't survive anything")
	assert_eq(state.soldiers[1].hp, 33)
	assert_eq(state.soldiers[2].kills, 4)
	assert_eq(state.soldiers[2].hp, 20)


func test_a_recruit_who_dies_is_still_on_the_roll_of_the_fallen() -> void:
	var state: CampaignState = CampaignState.new_campaign(7, 2)
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2)])
	var played: Dictionary = _play(state, mission)
	CampaignFixtures.unit_of(played["world"], 1).kill()
	_win(state, mission, played)
	assert_eq(_ids(state.soldiers), [2])
	assert_eq(_ids(state.fallen), [1])
	assert_eq(state.next_soldier_id, 3, "his id is spent either way")
	assert_eq(state.fallen[0].name, "Bram")


func test_a_win_records_the_mission_in_the_history() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN), _soldier(2, SHIELDMAN)])
	var mission: MissionDef = CampaignFixtures.mission(&"riverside", [_entry(SHIELDMAN, 2)])
	var played: Dictionary = _play(state, mission)
	var world: World = played["world"]
	CampaignFixtures.unit_of(world, 2).kill()
	for i: int in 3:
		var husk: Unit = world.spawn_unit(world.catalog.index_of(&"husk"), DARK, (20 + i) * M, 20 * M, 0, 1)
		husk.kill()
	_win(state, mission, played, 29)
	assert_eq(state.history.size(), 1)
	var entry: Dictionary = state.history[0]
	assert_eq(entry["id"], "riverside")
	assert_eq(entry["ticks"], world.tick, "the tick the mission ended on")
	assert_eq(entry["kills"], 3, "enemies dead")
	assert_eq(entry["losses"], 1, "soldiers lost")
	assert_eq(state.mission_index, 1)


func test_a_soldier_with_no_unit_in_the_world_is_left_as_he_was() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 4, 30)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 1)])
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	var empty_world: World = World.new(1, TestTerrains.flat(20, 20), TestTerrains.catalog())
	var stats: MissionStats = MissionStats.new()
	stats.begin(empty_world)
	stats.finish(empty_world)
	state.apply_victory(mission, plan, empty_world, stats)
	assert_eq(_ids(state.soldiers), [1])
	assert_eq(state.soldiers[0].kills, 4)
	assert_eq(state.soldiers[0].hp, 30)
	assert_eq(state.soldiers[0].missions, 0)
	assert_true(state.fallen.is_empty())


func test_a_defeat_changes_nothing_so_a_retry_plans_the_same_deploy() -> void:
	var state: CampaignState = CampaignFixtures.state([_soldier(1, SHIELDMAN, 3, 40), _soldier(2, LONGBOW, 1)])
	var mission: MissionDef = CampaignFixtures.mission(&"m", [_entry(SHIELDMAN, 2), _entry(LONGBOW, 1)])
	var before: String = _json(state)
	var first: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	var world: World = CampaignFixtures.deployed_world(first, mission)
	for u: Unit in world.units:
		u.kill()
	assert_eq(_json(state), before, "the failed attempt is simply dropped")
	var retry: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _names)
	assert_eq(_slot_ids(retry), _slot_ids(first))
	assert_eq(retry.kills, first.kills)
	assert_eq(retry.hp, first.hp)
	assert_eq(state.mission_index, 0, "still the same mission, with the same seed, so the same waves")


# --- JSON -------------------------------------------------------------------------


func test_the_state_round_trips_through_json_text() -> void:
	var state: CampaignState = _busy_state()
	var errors: PackedStringArray = PackedStringArray()
	var back: CampaignState = CampaignState.from_dict(_parsed(state), errors)
	assert_not_null(back, "errors: %s" % [errors])
	if back == null:
		return
	assert_true(errors.is_empty())
	assert_eq(back.campaign_seed, 12345)
	assert_eq(back.tier, 3)
	assert_eq(back.mission_index, 1)
	assert_eq(back.next_soldier_id, 6)
	assert_eq(_ids(back.soldiers), [1, 2, 5])
	assert_eq(back.soldiers[0].kills, 7)
	assert_eq(back.soldiers[0].hp, 40)
	assert_eq(back.soldiers[2].type_id, WARDEN)
	assert_eq(_ids(back.fallen), [3])
	assert_eq(back.fallen[0].fallen_in, &"riverside")
	assert_eq(back.fallen[0].missions, 1)
	assert_eq(back.history.size(), 1)
	assert_eq(back.history[0]["id"], "riverside")
	assert_eq(back.history[0]["ticks"], 9000)
	assert_eq(back.history[0]["kills"], 14)
	assert_eq(back.history[0]["losses"], 1)
	assert_eq(_json(back), _json(state), "and writes itself back out the same")


func test_json_numbers_come_back_as_ints() -> void:
	var back: CampaignState = CampaignState.from_dict(_parsed(_busy_state()))
	assert_typeof(back.tier, TYPE_INT)
	assert_typeof(back.mission_index, TYPE_INT)
	assert_typeof(back.next_soldier_id, TYPE_INT)
	assert_typeof(back.campaign_seed, TYPE_INT)
	assert_typeof(back.soldiers[0].kills, TYPE_INT)
	assert_typeof(back.history[0]["ticks"], TYPE_INT)


func test_a_64_bit_seed_survives_json_exactly() -> void:
	# JSON numbers are doubles: 2^53 + 1 is the first integer one can't hold.
	assert_ne(int(float(9007199254740993)), 9007199254740993, "the problem is real")
	for big: int in [9007199254740993, 9223372036854775807, -9223372036854775807, 0x2545F4914F6CDD1D, 0, -1]:
		var state: CampaignState = _busy_state(big)
		var text: String = JSON.stringify(state.to_dict())
		assert_string_contains(text, '"campaign_seed":"%d"' % big)
		var back: CampaignState = CampaignState.from_dict(JSON.parse_string(text))
		assert_not_null(back, "seed %d" % big)
		if back != null:
			assert_eq(back.campaign_seed, big)
			assert_eq(back.mission_seed(2), state.mission_seed(2), "so the missions replay the same")


func test_from_dict_does_not_share_the_dictionary_it_was_given() -> void:
	var d: Dictionary = _parsed(_busy_state())
	var back: CampaignState = CampaignState.from_dict(d)
	back.history[0]["ticks"] = 1
	back.soldiers[0].kills = 99
	assert_eq((d["history"] as Array)[0]["ticks"], 9000.0)
	assert_eq(((d["soldiers"] as Array)[0] as Dictionary)["kills"], 7.0)


func test_a_save_from_another_version_is_refused() -> void:
	assert_eq(CampaignState.VERSION, 1)
	for version: Variant in [0, 2, 1.5, "1", null]:
		var d: Dictionary = _parsed(_busy_state())
		d["version"] = version
		var errors: PackedStringArray = PackedStringArray()
		assert_null(CampaignState.from_dict(d, errors), "version %s" % [version])
		assert_eq(errors.size(), 1)
		if errors.size() == 1:
			assert_string_contains(errors[0], "version")
	var without: Dictionary = _parsed(_busy_state())
	without.erase("version")
	var missing_errors: PackedStringArray = PackedStringArray()
	assert_null(CampaignState.from_dict(without, missing_errors))
	assert_eq(missing_errors.size(), 1)


func test_a_save_missing_a_key_is_refused_naming_it() -> void:
	for key: String in [
		"campaign_seed", "tier", "mission_index", "next_soldier_id", "soldiers", "fallen", "history"
	]:
		var d: Dictionary = _parsed(_busy_state())
		d.erase(key)
		var errors: PackedStringArray = PackedStringArray()
		assert_null(CampaignState.from_dict(d, errors), "no %s" % key)
		assert_eq(errors.size(), 1, key)
		if errors.size() == 1:
			assert_string_contains(errors[0], key)


func test_a_save_with_a_value_of_the_wrong_shape_is_refused() -> void:
	var cases: Dictionary[String, Variant] = {
		"campaign_seed": 12345,
		"tier": 5,
		"mission_index": -1,
		"next_soldier_id": 0,
		"soldiers": {},
		"fallen": "none",
		"history": [3],
	}
	for key: String in cases:
		var d: Dictionary = _parsed(_busy_state())
		d[key] = cases[key]
		var errors: PackedStringArray = PackedStringArray()
		assert_null(CampaignState.from_dict(d, errors), "%s = %s" % [key, cases[key]])
		assert_eq(errors.size(), 1, key)
		if errors.size() == 1:
			assert_string_contains(errors[0], key)


func test_a_save_whose_seed_text_is_not_an_integer_is_refused() -> void:
	for text: String in ["", "abc", "12.5", "99999999999999999999", "1e9", " 12"]:
		var d: Dictionary = _parsed(_busy_state())
		d["campaign_seed"] = text
		var errors: PackedStringArray = PackedStringArray()
		assert_null(CampaignState.from_dict(d, errors), "seed '%s'" % text)
		assert_eq(errors.size(), 1)


func test_a_save_with_a_bad_soldier_or_history_entry_is_refused_saying_which() -> void:
	var d: Dictionary = _parsed(_busy_state())
	((d["soldiers"] as Array)[1] as Dictionary).erase("name")
	var errors: PackedStringArray = PackedStringArray()
	assert_null(CampaignState.from_dict(d, errors))
	assert_eq(errors.size(), 1)
	if errors.size() == 1:
		assert_string_contains(errors[0], "soldiers")
		assert_string_contains(errors[0], "1")
		assert_string_contains(errors[0], "name")
	var h: Dictionary = _parsed(_busy_state())
	((h["history"] as Array)[0] as Dictionary).erase("ticks")
	var history_errors: PackedStringArray = PackedStringArray()
	assert_null(CampaignState.from_dict(h, history_errors))
	assert_eq(history_errors.size(), 1)
	if history_errors.size() == 1:
		assert_string_contains(history_errors[0], "history")
		assert_string_contains(history_errors[0], "ticks")


func test_a_save_that_would_reuse_a_soldier_id_is_refused() -> void:
	var reused: Dictionary = _parsed(_busy_state())
	# Soldier 3 is among the fallen; put another 3 in the pool.
	((reused["soldiers"] as Array)[0] as Dictionary)["id"] = 3
	var errors: PackedStringArray = PackedStringArray()
	assert_null(CampaignState.from_dict(reused, errors))
	assert_eq(errors.size(), 1)
	if errors.size() == 1:
		assert_string_contains(errors[0], "id")
	var ahead: Dictionary = _parsed(_busy_state())
	ahead["next_soldier_id"] = 5
	var ahead_errors: PackedStringArray = PackedStringArray()
	assert_null(CampaignState.from_dict(ahead, ahead_errors), "soldier 5 is alive, so the next id can't be 5")
	assert_eq(ahead_errors.size(), 1)


func test_something_that_is_not_a_dictionary_is_refused() -> void:
	for junk: Variant in [null, [], "save", 3]:
		var errors: PackedStringArray = PackedStringArray()
		assert_null(CampaignState.from_dict(junk, errors), "%s" % [junk])
		assert_eq(errors.size(), 1)


func test_from_dict_without_an_error_list_still_returns_null() -> void:
	assert_null(CampaignState.from_dict({}))
	assert_not_null(CampaignState.from_dict(_parsed(_busy_state())))
