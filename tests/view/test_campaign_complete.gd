extends GutTest
## The campaign-complete screen: what the finished campaign came to (missions,
## enemies killed, soldiers lost, time), the survivors with their kills, best
## first, and the roll of the fallen with where each fell.

const SHIELDMAN: StringName = &"shieldman"
const LONGBOW: StringName = &"longbow"

var _campaign: CampaignDef
var _catalog: UnitCatalog


func before_all() -> void:
	_campaign = MenuFixtures.campaign()
	_catalog = MenuFixtures.catalog()


## A finished campaign at Hard: three won missions, two soldiers alive (the
## one with fewer kills joined first), two fallen.
func _finished() -> CampaignState:
	var state: CampaignState = CampaignFixtures.state([
		CampaignFixtures.soldier(1, SHIELDMAN, 4), CampaignFixtures.soldier(5, LONGBOW, 11),
	], 3)
	state.soldiers[0].name = "Ailsa"
	state.soldiers[0].missions = 3
	state.soldiers[1].name = "Calum"
	state.soldiers[1].missions = 2
	var first: Soldier = CampaignFixtures.soldier(2, SHIELDMAN, 6)
	first.name = "Bridie"
	first.fallen_in = &"riverside"
	var second: Soldier = CampaignFixtures.soldier(3, LONGBOW, 0)
	second.name = "Dougal"
	second.fallen_in = &"old_mill"
	state.fallen.append_array([first, second])
	state.history = [
		{"id": "riverside", "ticks": 4200, "kills": 20, "losses": 1},
		{"id": "the_ford", "ticks": 3000, "kills": 15, "losses": 0},
		{"id": "old_mill", "ticks": 5400, "kills": 33, "losses": 1},
	]
	state.mission_index = 3
	return state


func _screen(state: CampaignState) -> CampaignComplete:
	var screen: CampaignComplete = CampaignComplete.new()
	screen.setup(_campaign, state, _catalog)
	add_child_autofree(screen)
	return screen


func test_it_says_the_campaign_is_complete_and_totals_it() -> void:
	var screen: CampaignComplete = _screen(_finished())
	assert_eq((MenuFixtures.named(screen, "Title") as Label).text, "Campaign complete")
	# 4200 + 3000 + 5400 ticks at 30 a second: 12,600 / 30 = 420 s = 7:00.
	assert_eq(
		(MenuFixtures.named(screen, "Summary") as Label).text,
		"Hard   -   3 missions won   -   Enemies killed: 68   -   Soldiers lost: 2   -   Time 7:00"
	)


func test_survivors_are_listed_by_kills_with_their_missions() -> void:
	var screen: CampaignComplete = _screen(_finished())
	assert_true(MenuFixtures.says(screen, "Survivors: 2"))
	assert_eq(
		MenuFixtures.texts(MenuFixtures.named(screen, "SurvivorGrid")),
		PackedStringArray(["Name", "Type", "Kills", "Missions", "Calum", "Longbow", "11", "2", "Ailsa", "Shieldman", "4", "3"]),
		"Calum has more kills, so he comes first"
	)


func test_the_fallen_are_listed_with_where_they_fell() -> void:
	var screen: CampaignComplete = _screen(_finished())
	assert_true(MenuFixtures.says(screen, "The fallen: 2"))
	assert_eq(
		MenuFixtures.texts(MenuFixtures.named(screen, "FallenGrid")),
		PackedStringArray([
			"Name", "Type", "Kills", "Fell at",
			"Bridie", "Shieldman", "6", "Riverside", "Dougal", "Longbow", "0", "Old Mill",
		]),
		"in the order they fell, by the mission's own name"
	)


func test_no_one_fell_says_no_one() -> void:
	var state: CampaignState = _finished()
	state.fallen.clear()
	var screen: CampaignComplete = _screen(state)
	assert_true(MenuFixtures.says(screen, "The fallen: 0"))
	assert_true(MenuFixtures.says(screen, "No one."))


func test_a_mission_the_campaign_no_longer_has_is_named_by_its_id() -> void:
	var state: CampaignState = _finished()
	state.fallen[0].fallen_in = &"lost_mission"
	assert_true(MenuFixtures.says(_screen(state), "lost_mission"))


func test_main_menu_and_esc_leave() -> void:
	var screen: CampaignComplete = _screen(_finished())
	watch_signals(screen)
	MenuFixtures.press(screen, "MainMenuButton")
	assert_signal_emit_count(screen, "main_menu_pressed", 1)
	var key: InputEventKey = InputEventKey.new()
	key.physical_keycode = KEY_ESCAPE
	key.pressed = true
	get_viewport().push_input(key)
	assert_signal_emit_count(screen, "main_menu_pressed", 2)
