extends GutTest
## The briefing: the mission's name, text and starting objectives, the roster
## slot by slot (veterans with kills, bonuses and health, or recruits), a Bench
## checkbox on every fielded veteran that plans the roster again, the reserve
## list, the difficulty, and Start / Back. The numbers it should show are
## computed from the shipped Riverside MissionDef at the campaign's tier, not
## written in here.

const TIER: int = 2
const SHIELDMAN: StringName = &"shieldman"
const LONGBOW: StringName = &"longbow"

var _campaign: CampaignDef
var _catalog: UnitCatalog
var _riverside: MissionDef


func after_each() -> void:
	# Rebuilding the lists queue_free's the old rows; let the frame free them.
	await get_tree().process_frame


func before_all() -> void:
	_campaign = MenuFixtures.campaign()
	_catalog = MenuFixtures.catalog()
	_riverside = _campaign.missions[0]


func _roster_size(mission: MissionDef, tier: int) -> int:
	var total: int = 0
	for entry: RosterEntry in mission.roster:
		total += Difficulty.pick(entry.counts, tier)
	return total


func _fresh() -> CampaignState:
	return CampaignState.new_campaign(7, TIER)


func _briefing(state: CampaignState, benched: PackedInt32Array = PackedInt32Array()) -> Briefing:
	var screen: Briefing = Briefing.new()
	screen.setup(_campaign, state, _catalog, benched)
	add_child_autofree(screen)
	return screen


## Seven veteran Shieldmen (Riverside fields six), best first: id 1 has the
## most kills. Ids 1..7; next_soldier_id 8.
func _veterans(count: int = 7) -> CampaignState:
	var soldiers: Array[Soldier] = []
	for i: int in count:
		soldiers.append(CampaignFixtures.soldier(i + 1, SHIELDMAN, 10 - i))
	return CampaignFixtures.state(soldiers, TIER)


func _grid_rows(screen: Briefing, grid_name: String) -> int:
	var grid: GridContainer = MenuFixtures.named(screen, grid_name) as GridContainer
	# One header row of labels, then a row per soldier.
	@warning_ignore("integer_division")
	var rows: int = grid.get_child_count() / Briefing.COLUMNS - 1
	return rows


func _bench_box(screen: Briefing, soldier_id: int) -> CheckBox:
	return MenuFixtures.named(screen, "Bench%d" % soldier_id) as CheckBox


# --- the mission --------------------------------------------------------------


func test_it_shows_the_mission_its_text_and_the_difficulty() -> void:
	var screen: Briefing = _briefing(_fresh())
	assert_eq((MenuFixtures.named(screen, "MissionName") as Label).text, "Riverside")
	assert_eq((MenuFixtures.named(screen, "MissionCount") as Label).text, "Mission 1 of 3")
	assert_eq((MenuFixtures.named(screen, "Difficulty") as Label).text, "Difficulty: Normal")
	assert_eq((MenuFixtures.named(screen, "BriefingText") as Label).text, _riverside.briefing)


func test_the_difficulty_label_follows_the_tier() -> void:
	for tier: int in Difficulty.TIERS:
		var screen: Briefing = _briefing(CampaignState.new_campaign(7, tier))
		assert_eq(
			(MenuFixtures.named(screen, "Difficulty") as Label).text,
			"Difficulty: %s" % ["Easy", "Moderate", "Normal", "Hard", "Brutal"][tier]
		)


func test_it_lists_the_objectives_that_show_from_the_start_only() -> void:
	var screen: Briefing = _briefing(_fresh())
	var list: VBoxContainer = MenuFixtures.named(screen, "Objectives") as VBoxContainer
	var shown: Array[String] = []
	for objective: ObjectiveSpec in _riverside.rules.objectives:
		if objective.shown_at_start:
			shown.append("- " + objective.text + (" (optional)" if objective.optional else ""))
	assert_gt(shown.size(), 0, "Riverside has starting objectives")
	assert_eq(MenuFixtures.texts(list), PackedStringArray(shown))


func test_a_hidden_objective_is_not_given_away_and_an_optional_one_is_marked() -> void:
	var def: MissionDef = ViewFixtures.mission()
	var campaign: CampaignDef = CampaignFixtures.campaign([def])
	var state: CampaignState = _fresh()
	var screen: Briefing = Briefing.new()
	screen.setup(campaign, state, _catalog)
	add_child_autofree(screen)
	var lines: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(screen, "Objectives"))
	assert_eq(lines, PackedStringArray(["- Hold the field"]), "the hill objective is hidden until the mission shows it")
	def.rules.objectives[1].shown_at_start = true
	var again: Briefing = Briefing.new()
	again.setup(campaign, state, _catalog)
	add_child_autofree(again)
	assert_eq(
		MenuFixtures.texts(MenuFixtures.named(again, "Objectives")),
		PackedStringArray(["- Hold the field", "- Take the hill (optional)"])
	)
	def.rules.objectives[1].shown_at_start = false


# --- the roster ---------------------------------------------------------------


func test_a_fresh_campaign_fields_riversides_roster_all_recruits() -> void:
	var screen: Briefing = _briefing(_fresh())
	var expected: int = _roster_size(_riverside, TIER)
	assert_eq(screen.plan().size(), expected)
	assert_eq(_grid_rows(screen, "RosterGrid"), expected, "one row per slot")
	assert_eq(screen.plan().recruits.size(), expected, "nobody has survived anything yet")
	assert_true(MenuFixtures.says(screen, "Roster: %d soldiers (0 veterans, %d recruits)" % [expected, expected]))
	var recruit_cells: int = 0
	for text: String in MenuFixtures.texts(MenuFixtures.named(screen, "RosterGrid")):
		if text == "Recruit":
			recruit_cells += 1
	assert_eq(recruit_cells, expected, "each slot says Recruit")
	assert_null(MenuFixtures.named(screen, "ReserveGrid"), "no reserve yet")


func test_the_slots_follow_the_missions_counts_by_type() -> void:
	var screen: Briefing = _briefing(_fresh())
	var grid_texts: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(screen, "RosterGrid"))
	for entry: RosterEntry in _riverside.roster:
		var type: UnitType = _catalog.find(entry.type_id)
		var shown: int = 0
		for text: String in grid_texts:
			if text == type.display_name:
				shown += 1
		assert_eq(shown, Difficulty.pick(entry.counts, TIER), "%s slots at Normal" % type.display_name)


func test_recruits_show_their_names_from_the_campaigns_list() -> void:
	var screen: Briefing = _briefing(_fresh())
	for i: int in screen.plan().size():
		assert_eq(screen.plan().names[i], _campaign.soldier_names[i], "names are handed out in order")
		assert_true(MenuFixtures.says(screen, screen.plan().names[i]))


func test_a_veteran_shows_kills_bonuses_and_health() -> void:
	# Shieldman: accuracy cap 120, attack rate 250, no speed bonus; 100 hp.
	# Four kills is half of HALF_CAP_KILLS * 2: bonus = cap * 4 / 8.
	var state: CampaignState = CampaignFixtures.state([CampaignFixtures.soldier(1, SHIELDMAN, 4, 40)], TIER)
	var screen: Briefing = _briefing(state)
	var row: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(screen, "RosterGrid"))
	var at: int = row.find("Soldier 1")
	assert_gt(at, -1, "the veteran is in the roster")
	assert_eq(row.slice(at, at + 7), PackedStringArray(["Soldier 1", "Shieldman", "4", "+6%", "+12.5%", "-", "40/100"]))
	assert_true(screen.plan().is_recruit.has(true), "the other slots are still recruits")
	assert_false(screen.plan().is_recruit[0])
	assert_true(MenuFixtures.says(screen, "Roster: %d soldiers (1 veterans, %d recruits)" % [
		screen.plan().size(), screen.plan().size() - 1
	]))


func test_an_unhurt_veteran_shows_full_health() -> void:
	var state: CampaignState = CampaignFixtures.state([CampaignFixtures.soldier(1, SHIELDMAN, 0, 0)], TIER)
	var row: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(_briefing(state), "RosterGrid"))
	assert_true(row.has("100/100"))


# --- benching -----------------------------------------------------------------


func test_only_fielded_veterans_have_a_bench_box() -> void:
	var screen: Briefing = _briefing(_veterans(3))
	for id: int in [1, 2, 3]:
		assert_not_null(_bench_box(screen, id), "veteran %d can be benched" % id)
		assert_false(_bench_box(screen, id).button_pressed)
	assert_null(_bench_box(screen, 4), "a recruit can't be")
	assert_eq(screen.plan().soldier_ids.slice(0, 3), PackedInt32Array([1, 2, 3]))


func test_benching_a_veteran_plans_again_and_the_next_best_takes_his_slot() -> void:
	var state: CampaignState = _veterans(7)
	var screen: Briefing = _briefing(state)
	assert_eq(screen.plan().soldier_ids.slice(0, 6), PackedInt32Array([1, 2, 3, 4, 5, 6]), "the best six go")
	_bench_box(screen, 1).button_pressed = true
	assert_true(screen.benched().has(1))
	assert_eq(screen.plan().soldier_ids.slice(0, 6), PackedInt32Array([2, 3, 4, 5, 6, 7]), "the seventh steps in")
	assert_false(screen.plan().soldier_ids.has(1))


func test_a_benched_veteran_waits_in_the_reserve_with_his_box_ticked_and_can_come_back() -> void:
	# Six veterans fill Riverside's six Shieldman slots exactly: no reserve.
	var screen: Briefing = _briefing(_veterans(6))
	assert_null(MenuFixtures.named(screen, "ReserveGrid"), "nobody is left out yet")
	_bench_box(screen, 1).button_pressed = true
	var reserve: GridContainer = MenuFixtures.named(screen, "ReserveGrid") as GridContainer
	assert_not_null(reserve)
	assert_eq(_grid_rows(screen, "ReserveGrid"), 1, "veteran 1 is the one in reserve")
	assert_true(MenuFixtures.says(reserve, "Soldier 1"))
	assert_true(_bench_box(screen, 1).button_pressed, "still ticked, in the reserve list")
	assert_true(MenuFixtures.says(screen, "Reserve: 1"))
	_bench_box(screen, 1).button_pressed = false
	assert_eq(screen.benched().size(), 0)
	assert_eq(screen.plan().soldier_ids.slice(0, 6), PackedInt32Array([1, 2, 3, 4, 5, 6]), "back in his slot")
	assert_null(MenuFixtures.named(screen, "ReserveGrid"), "and the reserve is empty again")


func test_benching_with_no_spare_veteran_gives_the_slot_to_a_recruit() -> void:
	var state: CampaignState = _veterans(6)
	var screen: Briefing = _briefing(state)
	var recruits: int = screen.plan().recruits.size()
	_bench_box(screen, 1).button_pressed = true
	assert_eq(screen.plan().recruits.size(), recruits + 1, "a recruit fills it")
	assert_eq(screen.plan().soldier_ids.slice(0, 5), PackedInt32Array([2, 3, 4, 5, 6]))
	assert_eq(screen.plan().soldier_ids[5], state.next_soldier_id, "with the next provisional id")
	assert_eq(_grid_rows(screen, "RosterGrid"), screen.plan().size(), "the roster is the same size")


func test_extra_veterans_who_have_no_slot_are_listed_as_reserve_without_a_box() -> void:
	var screen: Briefing = _briefing(_veterans(8))
	assert_eq(_grid_rows(screen, "ReserveGrid"), 2, "veterans 7 and 8 have no slot")
	assert_null(_bench_box(screen, 7), "nothing to bench: they aren't going")
	assert_null(_bench_box(screen, 8))
	assert_true(MenuFixtures.says(screen, "Reserve: 2"))


func test_a_type_the_mission_has_no_slot_for_waits_in_reserve() -> void:
	var state: CampaignState = CampaignFixtures.state([CampaignFixtures.soldier(1, &"warden", 3)], TIER)
	var screen: Briefing = _briefing(state)
	assert_eq(_grid_rows(screen, "ReserveGrid"), 1, "Riverside has no Warden slot")
	assert_true(MenuFixtures.says(MenuFixtures.named(screen, "ReserveGrid"), "Warden"))


func test_the_bench_survives_a_rebuilt_briefing_and_ignores_the_gone() -> void:
	var state: CampaignState = _veterans(7)
	var screen: Briefing = _briefing(state, PackedInt32Array([1, 99]))
	assert_eq(screen.benched(), PackedInt32Array([1]), "99 isn't on the roll")
	assert_false(screen.plan().soldier_ids.has(1), "the bench is in force from the start (a Retry's)")


func test_benching_changes_nothing_in_the_campaign() -> void:
	var state: CampaignState = _veterans(7)
	var before: Dictionary = state.to_dict()
	var screen: Briefing = _briefing(state)
	_bench_box(screen, 2).button_pressed = true
	_bench_box(screen, 3).button_pressed = true
	assert_eq(state.to_dict(), before, "a plan is only a plan")


func test_the_roster_keeps_the_keyboard_on_the_box_that_was_pressed() -> void:
	var screen: Briefing = _briefing(_veterans(7))
	_bench_box(screen, 1).button_pressed = true
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _bench_box(screen, 1))


# --- leaving ------------------------------------------------------------------


func test_start_sends_the_plan_and_the_bench() -> void:
	var screen: Briefing = _briefing(_veterans(7))
	_bench_box(screen, 1).button_pressed = true
	watch_signals(screen)
	MenuFixtures.press(screen, "StartButton")
	assert_signal_emit_count(screen, "start_pressed", 1)
	var args: Array = get_signal_parameters(screen, "start_pressed")
	assert_eq(args[0], screen.plan(), "the very plan on show")
	assert_eq(args[1], PackedInt32Array([1]))


func test_back_and_esc_go_back() -> void:
	var screen: Briefing = _briefing(_fresh())
	watch_signals(screen)
	MenuFixtures.press(screen, "BackButton")
	assert_signal_emit_count(screen, "back_pressed", 1)
	var key: InputEventKey = InputEventKey.new()
	key.physical_keycode = KEY_ESCAPE
	key.pressed = true
	get_viewport().push_input(key)
	assert_signal_emit_count(screen, "back_pressed", 2)


func test_the_keyboard_starts_on_start() -> void:
	var screen: Briefing = _briefing(_fresh())
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), MenuFixtures.named(screen, "StartButton"))


func test_a_later_mission_shows_its_own_briefing() -> void:
	var state: CampaignState = _fresh()
	state.mission_index = 2
	var screen: Briefing = _briefing(state)
	assert_eq((MenuFixtures.named(screen, "MissionName") as Label).text, _campaign.missions[2].display_name)
	assert_eq((MenuFixtures.named(screen, "MissionCount") as Label).text, "Mission 3 of 3")
	assert_eq(screen.plan().size(), _roster_size(_campaign.missions[2], TIER))
