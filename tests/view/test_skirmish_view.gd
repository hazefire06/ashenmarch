extends GutTest
## The in-match view of a skirmish (Phase 9): SideColors, the flags in the world
## (FlagsView), the score line and the F7 scoreboard (SkirmishHud), the flags on
## the overhead map, the control bar's status line, and MainView wiring them for
## a skirmish launch (and not for a campaign mission). The views read the sim and
## never change it; where a test sets sim state by hand (a flag's owner, the
## hill's holder) it is standing in for what a played tick would have left.
## Scenes are stepped by hand, never by awaiting frames, so every test runs the
## same ticks.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BC: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
const KOTH: SkirmishRules.Mode = SkirmishRules.Mode.KING_OF_THE_HILL
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS
const NO_SIDE: int = SkirmishRuntime.NO_SIDE
const CONTESTED: int = SkirmishRuntime.CONTESTED

var _catalog: UnitCatalog
var _physics_rate: int = 0


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	# MainView sets the global physics rate to the sim's; put it back after.
	_physics_rate = Engine.physics_ticks_per_second


func after_all() -> void:
	Engine.physics_ticks_per_second = _physics_rate
	ViewFixtures.cleanup()


# --- helpers ------------------------------------------------------------------


# A bare skirmish world on a flat 60 x 60 map with the fixtures' flags (0 the
# hill at 30, 30; 1 north at 30, 10; 2 south at 30, 50, radius 4 m), no units.
func _world(mode: SkirmishRules.Mode = KOTH, side: UnitType.Faction = LIGHT, minutes: int = 10) -> World:
	var rules: SkirmishRules = SkirmishRules.for_map(ViewFixtures.skirmish_map(), mode, minutes, side)
	var w: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	assert_true(w.start_mission(MissionScript.new(), 0))
	assert_true(w.start_skirmish(rules))
	return w


func _unit(w: World, type_id: StringName, side: UnitType.Faction, x: int, z: int) -> Unit:
	return w.spawn_unit(_catalog.index_of(type_id), side, x * M, z * M, 1, 0)


# Two Shieldmen and three Husks well away from every flag, then one step, which
# records the armies.
func _armies(w: World) -> void:
	for i: int in 2:
		_unit(w, &"shieldman", LIGHT, 5, 5 + 2 * i)
	for i: int in 3:
		_unit(w, &"husk", DARK, 55, 5 + 2 * i)
	w.step()


func _flags(w: World) -> FlagsView:
	var view: FlagsView = FlagsView.new()
	add_child_autofree(view)
	view.setup(w)
	return view


func _hud(w: World, player: UnitType.Faction = LIGHT) -> SkirmishHud:
	var hud: SkirmishHud = SkirmishHud.new()
	add_child_autofree(hud)
	hud.setup(w, player)
	return hud


func _map(w: World) -> OverheadMap:
	var map: OverheadMap = OverheadMap.new()
	add_child_autofree(map)
	map.setup(w.terrain, null, w)
	# Anchored to the corner so the size can be set (full-rect anchors would
	# override it), as a window 800 x 600 would make it.
	map.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	map.size = Vector2(800.0, 600.0)
	return map


func _key(keycode: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = true
	return event


func _push(event: InputEvent) -> void:
	get_viewport().push_input(event)


func _main(
	mode: SkirmishRules.Mode = KOTH, side: UnitType.Faction = LIGHT, minutes: int = 10
) -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.skirmish_launch(mode, side, minutes)
	main.end_delay = 0.0
	add_child_autofree(main)
	return main


func _step(main: MainView, ticks: int = 1) -> void:
	for _i: int in ticks:
		main._physics_process(1.0 / World.TICK_RATE)


func _units_of(w: World, side: UnitType.Faction) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in w.units:
		if unit.faction == side:
			out.append(unit)
	return out


func _kill(units: Array[Unit]) -> void:
	for unit: Unit in units:
		unit.state = Unit.State.DEAD


# How far apart two colors are, as points in RGB space.
func _gap(a: Color, b: Color) -> float:
	return Vector3(a.r, a.g, a.b).distance_to(Vector3(b.r, b.g, b.b))


func _controller(main: MainView) -> SelectionController:
	return main.get_node("Hud/Selection") as SelectionController


# --- the colors ---------------------------------------------------------------


func test_each_side_has_its_own_color_and_nobody_is_grey() -> void:
	assert_eq(SideColors.of(LIGHT), SideColors.LIGHT)
	assert_eq(SideColors.of(DARK), SideColors.DARK)
	assert_eq(SideColors.of(NO_SIDE), SideColors.NEUTRAL)
	assert_eq(SideColors.of(CONTESTED), SideColors.NEUTRAL, "contested is nobody's")
	assert_eq(SideColors.of(7), SideColors.NEUTRAL, "and so is anything that isn't a faction")
	assert_gt(SideColors.LIGHT.b, SideColors.LIGHT.r, "Light is blue")
	assert_gt(SideColors.DARK.r, SideColors.DARK.b, "Dark is crimson")
	assert_almost_eq(SideColors.NEUTRAL.r, SideColors.NEUTRAL.b, 0.05, "grey has no hue")


func test_sides_are_named() -> void:
	assert_eq(SideColors.side_name(LIGHT), "Light")
	assert_eq(SideColors.side_name(DARK), "Dark")


# --- the flags in the world ---------------------------------------------------


func test_body_count_shows_no_flags() -> void:
	assert_eq(_flags(_world(BC)).flag_count_shown(), 0)


func test_king_of_the_hill_shows_only_the_hill() -> void:
	var w: World = _world(KOTH)
	var view: FlagsView = _flags(w)
	assert_eq(view.flag_count_shown(), 1)
	assert_eq(view.shown_flag(0), w.skirmish.rules.hill)
	var at: Vector3 = view.flag_position(0)
	assert_almost_eq(at.x, 30.0, 0.01)
	assert_almost_eq(at.z, 30.0, 0.01)
	assert_almost_eq(view.ring_radius(), 4.0, 0.01, "the ring is the flag's capture radius")


func test_capture_the_flags_shows_every_flag() -> void:
	var view: FlagsView = _flags(_world(CTF))
	assert_eq(view.flag_count_shown(), 3)
	assert_almost_eq(view.flag_position(1).z, 10.0, 0.01)
	assert_almost_eq(view.flag_position(2).z, 50.0, 0.01)


func test_a_world_with_no_skirmish_shows_no_flags() -> void:
	var w: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	assert_eq(_flags(w).flag_count_shown(), 0)


func test_the_flags_stand_on_the_ground_there() -> void:
	var rules: SkirmishRules = SkirmishRules.for_map(ViewFixtures.skirmish_map(), KOTH, 10, LIGHT)
	var terrain: Terrain = TestTerrains.flat(60, 60)
	for k: int in terrain.heights.size():
		terrain.heights[k] = 2500
	var w: World = World.new(1, terrain, _catalog)
	assert_true(w.start_mission(MissionScript.new(), 0))
	assert_true(w.start_skirmish(rules))
	assert_almost_eq(_flags(w).flag_position(0).y, 2.5, 0.01)


func test_the_hills_banner_follows_who_holds_it() -> void:
	var w: World = _world(KOTH)
	var view: FlagsView = _flags(w)
	assert_eq(view.banner_color(0), SideColors.NEUTRAL, "nobody on it")
	w.skirmish.hill_holder = LIGHT
	view.after_step()
	assert_eq(view.banner_color(0), SideColors.LIGHT)
	w.skirmish.hill_holder = DARK
	view.after_step()
	assert_eq(view.banner_color(0), SideColors.DARK)
	w.skirmish.hill_holder = NO_SIDE
	view.after_step()
	assert_eq(view.banner_color(0), SideColors.NEUTRAL)


func test_the_ring_is_the_banners_color_see_through() -> void:
	var w: World = _world(KOTH)
	var view: FlagsView = _flags(w)
	w.skirmish.hill_holder = DARK
	view.after_step()
	var ring: Color = view.ring_color(0)
	assert_eq(Color(ring, 1.0), SideColors.DARK)
	assert_lt(ring.a, 1.0, "the ground shows through")


func test_the_hills_banner_always_flies_at_the_top() -> void:
	var w: World = _world(KOTH)
	var view: FlagsView = _flags(w)
	assert_eq(view.banner_height_ratio(0), 1.0)
	w.skirmish.hill_holder = LIGHT
	view.after_step()
	assert_eq(view.banner_height_ratio(0), 1.0)


func test_a_contested_hill_flashes_between_the_two_sides_colors() -> void:
	var w: World = _world(KOTH)
	var view: FlagsView = _flags(w)
	w.skirmish.hill_holder = CONTESTED
	view.after_step()
	var first: Color = view.banner_color(0)
	assert_true(first == SideColors.LIGHT or first == SideColors.DARK, "one side's color or the other's")
	view._process(FlagsView.CONTEST_FLASH_SECONDS * 1.01)
	var second: Color = view.banner_color(0)
	assert_true(second == SideColors.LIGHT or second == SideColors.DARK)
	assert_ne(second, first, "and the other a quarter second later")
	view._process(FlagsView.CONTEST_FLASH_SECONDS)
	assert_eq(view.banner_color(0), first, "back again")
	assert_eq(Color(view.ring_color(0), 1.0), first, "the ring flashes with it")


func test_a_flash_of_real_time_does_not_recolor_a_hill_that_is_not_contested() -> void:
	var w: World = _world(KOTH)
	var view: FlagsView = _flags(w)
	w.skirmish.hill_holder = DARK
	view.after_step()
	for _i: int in 5:
		view._process(FlagsView.CONTEST_FLASH_SECONDS)
		assert_eq(view.banner_color(0), SideColors.DARK)


func test_a_flags_banner_is_its_owners_color() -> void:
	var w: World = _world(CTF)
	var view: FlagsView = _flags(w)
	for i: int in 3:
		assert_eq(view.banner_color(i), SideColors.NEUTRAL, "flag %d is nobody's" % i)
	w.skirmish.flag_owner[1] = DARK
	view.after_step()
	assert_eq(view.banner_color(1), SideColors.DARK)
	assert_eq(view.banner_color(0), SideColors.NEUTRAL, "the others are as they were")
	w.skirmish.flag_owner[1] = LIGHT
	view.after_step()
	assert_eq(view.banner_color(1), SideColors.LIGHT)


func test_a_flag_nobody_holds_rests_at_the_foot_and_an_owned_one_flies_at_the_top() -> void:
	var w: World = _world(CTF)
	var view: FlagsView = _flags(w)
	assert_eq(view.banner_height_ratio(1), 0.0)
	var low: float = view.banner_y(1)
	w.skirmish.flag_owner[1] = DARK
	view.after_step()
	assert_eq(view.banner_height_ratio(1), 1.0)
	var high: float = view.banner_y(1)
	assert_gt(high, low, "the banner is higher on the pole")
	assert_lt(high + FlagsView.BANNER_SIZE.y * 0.5, FlagsView.POLE_HEIGHT + 0.01, "and still on it")
	assert_gt(low - FlagsView.BANNER_SIZE.y * 0.5, -0.01, "and the low one is above the ground")


func test_a_banner_climbs_the_pole_as_a_capture_goes() -> void:
	var w: World = _world(CTF)
	var view: FlagsView = _flags(w)
	var capture: int = w.skirmish.rules.capture_ticks
	w.skirmish.flag_capture_side[2] = LIGHT
	var last_y: float = view.banner_y(2)
	for step: int in [1, 2, 3]:
		w.skirmish.flag_progress[2] = int(capture * step / 4.0)
		view.after_step()
		assert_almost_eq(view.banner_height_ratio(2), step / 4.0, 0.02)
		assert_gt(view.banner_y(2), last_y, "higher at %d of 4" % step)
		last_y = view.banner_y(2)


func test_a_flag_being_captured_is_tinted_toward_the_capturer() -> void:
	var w: World = _world(CTF)
	var view: FlagsView = _flags(w)
	w.skirmish.flag_capture_side[0] = LIGHT
	w.skirmish.flag_progress[0] = int(w.skirmish.rules.capture_ticks * 0.5)
	view.after_step()
	var half: Color = view.banner_color(0)
	assert_eq(half, SideColors.NEUTRAL.lerp(SideColors.LIGHT, 0.5))
	w.skirmish.flag_progress[0] = w.skirmish.rules.capture_ticks - 1
	view.after_step()
	assert_lt(
		_gap(view.banner_color(0), SideColors.LIGHT), _gap(half, SideColors.LIGHT),
		"closer to the capturer's color as it nears"
	)


func test_an_owned_flag_taken_from_its_owner_keeps_flying_and_shifts_color() -> void:
	var w: World = _world(CTF)
	var view: FlagsView = _flags(w)
	w.skirmish.flag_owner[0] = DARK
	w.skirmish.flag_capture_side[0] = LIGHT
	w.skirmish.flag_progress[0] = int(w.skirmish.rules.capture_ticks * 0.5)
	view.after_step()
	assert_eq(view.banner_height_ratio(0), 1.0, "it is still Dark's flag")
	assert_eq(view.banner_color(0), SideColors.DARK.lerp(SideColors.LIGHT, 0.5))


func test_the_flags_view_never_changes_the_world() -> void:
	var w: World = _world(CTF)
	_armies(w)
	var before: String = w.state_hash()
	var view: FlagsView = _flags(w)
	w.skirmish.hill_holder = CONTESTED
	var held: String = w.state_hash()
	view.after_step()
	view._process(0.3)
	assert_eq(w.state_hash(), held)
	assert_ne(held, before, "(the hill was changed by the test, the view changed nothing)")


func test_setting_up_again_replaces_the_flags() -> void:
	var view: FlagsView = _flags(_world(CTF))
	assert_eq(view.flag_count_shown(), 3)
	view.setup(_world(KOTH))
	assert_eq(view.flag_count_shown(), 1)
	assert_eq(view.get_child_count(), 1, "the old flags are gone, the new one is there")


# --- the score line and the scoreboard ----------------------------------------


func test_the_line_names_the_mode_the_time_and_the_score_with_the_player_marked() -> void:
	assert_eq(_hud(_world(BC)).clock_text(), "Body Count · 10:00 · Light (you) 0 · Dark 0")
	assert_eq(_hud(_world(KOTH)).clock_text(), "King of the Hill · 10:00 · Hill: Light (you) 0:00 · Dark 0:00")
	assert_eq(_hud(_world(CTF)).clock_text(), "Capture the Flags · 10:00 · Flags: Light (you) 0 · Dark 0")


func test_a_dark_player_is_the_one_marked() -> void:
	var w: World = _world(BC, DARK)
	assert_eq(_hud(w, DARK).clock_text(), "Body Count · 10:00 · Light 0 · Dark (you) 0")


func test_the_clock_counts_down_as_ticks_pass() -> void:
	var w: World = _world(BC, LIGHT, 3)
	var hud: SkirmishHud = _hud(w)
	assert_true(hud.clock_text().contains("3:00"))
	for _t: int in World.TICK_RATE:
		w.step()
	hud.show_world(w)
	assert_true(hud.clock_text().contains("2:59"), hud.clock_text())
	for _t: int in 59 * World.TICK_RATE:
		w.step()
	hud.show_world(w)
	assert_true(hud.clock_text().contains("2:00"), hud.clock_text())


func test_the_line_shows_the_score_in_the_modes_terms() -> void:
	var w: World = _world(KOTH)
	var hud: SkirmishHud = _hud(w)
	w.skirmish.hold_ticks[LIGHT] = 72 * World.TICK_RATE
	w.skirmish.hold_ticks[DARK] = 48 * World.TICK_RATE
	hud.show_world(w)
	assert_true(hud.clock_text().ends_with("Hill: Light (you) 1:12 · Dark 0:48"), hud.clock_text())
	var counting: World = _world(BC)
	var counting_hud: SkirmishHud = _hud(counting)
	counting.skirmish.deaths[DARK] = 3
	counting.skirmish.deaths[LIGHT] = 1
	counting_hud.show_world(counting)
	assert_true(counting_hud.clock_text().ends_with("Light (you) 3 · Dark 1"), "kills are the enemy's deaths")
	var flags: World = _world(CTF)
	var flags_hud: SkirmishHud = _hud(flags)
	flags.skirmish.flag_owner[0] = LIGHT
	flags.skirmish.flag_owner[1] = LIGHT
	flags.skirmish.flag_owner[2] = DARK
	flags_hud.show_world(flags)
	assert_true(flags_hud.clock_text().ends_with("Flags: Light (you) 2 · Dark 1"), flags_hud.clock_text())


func test_the_clock_stops_where_the_skirmish_was_decided() -> void:
	var w: World = _world(BC)
	_armies(w)
	var hud: SkirmishHud = _hud(w)
	_kill(_units_of(w, DARK))
	w.step()
	assert_true(w.skirmish.is_decided())
	hud.show_world(w)
	var at_the_end: String = hud.clock_text()
	for _t: int in 60:
		w.step()
	hud.show_world(w)
	assert_eq(hud.clock_text(), at_the_end)


func test_the_line_is_hidden_without_a_skirmish() -> void:
	var w: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	var hud: SkirmishHud = _hud(w)
	assert_false(hud.visible)
	assert_eq(hud.clock_text(), "")
	assert_true(_hud(_world()).visible, "and on with one")


func test_the_line_sits_where_the_missions_message_line_does() -> void:
	var hud: SkirmishHud = _hud(_world())
	var line: Label = hud.get_child(0) as Label
	assert_eq(line.offset_top, MissionHud.OBJECTIVE_TOP)


func test_the_scoreboard_starts_hidden_and_f7_toggles_it() -> void:
	var hud: SkirmishHud = _hud(_world())
	assert_false(hud.scoreboard_visible())
	hud._unhandled_input(_key(KEY_F7))
	assert_true(hud.scoreboard_visible())
	hud._unhandled_input(_key(KEY_F7))
	assert_false(hud.scoreboard_visible())


func test_f7_is_the_scoreboard_action() -> void:
	InputBindings.install()
	assert_true(InputMap.has_action(InputBindings.TOGGLE_SCOREBOARD))
	assert_true(_key(KEY_F7).is_action(InputBindings.TOGGLE_SCOREBOARD))
	assert_false(_key(KEY_F6).is_action(InputBindings.TOGGLE_SCOREBOARD))


func test_other_keys_leave_the_scoreboard_alone() -> void:
	var hud: SkirmishHud = _hud(_world())
	hud._unhandled_input(_key(KEY_F5))
	hud._unhandled_input(_key(KEY_TAB))
	assert_false(hud.scoreboard_visible())


func test_toggling_the_scoreboard_fills_it_in_at_once() -> void:
	var w: World = _world(KOTH)
	_armies(w)
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	assert_eq(hud.scoreboard_rows()[1][1], "2 / 2")


func test_the_scoreboard_lists_the_player_first() -> void:
	var w: World = _world(KOTH)
	_armies(w)
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	var rows: Array[PackedStringArray] = hud.scoreboard_rows()
	assert_eq(rows.size(), 3, "a header and a row a side")
	assert_eq(rows[0][0], "")
	assert_true(rows[0].has("Lost") and rows[0].has("Kills") and rows[0].has("Score"))
	assert_eq(rows[1], PackedStringArray(["You (Light)", "2 / 2", "0", "0", "0:00"]))
	assert_eq(rows[2], PackedStringArray(["AI (Dark)", "3 / 3", "0", "0", "0:00"]))
	var dark: SkirmishHud = _hud(w, DARK)
	dark.toggle_scoreboard()
	var dark_rows: Array[PackedStringArray] = dark.scoreboard_rows()
	assert_eq(dark_rows[1][0], "You (Dark)")
	assert_eq(dark_rows[2][0], "AI (Light)")
	assert_eq(dark_rows[1][1], "3 / 3", "the player's own army is the first row")


func test_the_scoreboard_counts_the_alive_the_lost_and_the_kills() -> void:
	var w: World = _world(BC)
	_armies(w)
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	var husks: Array[Unit] = _units_of(w, DARK)
	husks[0].state = Unit.State.DEAD
	husks[1].state = Unit.State.DEAD
	_units_of(w, LIGHT)[0].state = Unit.State.DEAD
	w.step()
	hud.show_world(w)
	var rows: Array[PackedStringArray] = hud.scoreboard_rows()
	assert_eq(rows[1], PackedStringArray(["You (Light)", "1 / 2", "1", "2", "2"]), "one lost, two killed, score 2")
	assert_eq(rows[2], PackedStringArray(["AI (Dark)", "1 / 3", "2", "1", "1"]))


func test_the_scoreboard_scores_the_hill_in_minutes_and_flags_in_flags() -> void:
	var w: World = _world(KOTH)
	_armies(w)
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	w.skirmish.hold_ticks[LIGHT] = 95 * World.TICK_RATE
	hud.show_world(w)
	assert_eq(hud.scoreboard_rows()[1][4], "1:35")
	assert_eq(hud.scoreboard_flag_lines().size(), 0, "no flag list for the hill")
	var flags: World = _world(CTF)
	_armies(flags)
	var flags_hud: SkirmishHud = _hud(flags)
	flags_hud.toggle_scoreboard()
	flags.skirmish.flag_owner[2] = DARK
	flags_hud.show_world(flags)
	assert_eq(flags_hud.scoreboard_rows()[2][4], "1")
	assert_eq(flags_hud.scoreboard_rows()[1][4], "0")


func test_the_scoreboard_says_the_mode_and_the_clock() -> void:
	var w: World = _world(CTF, LIGHT, 5)
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	assert_eq(hud.scoreboard_summary(), "Capture the Flags · 5:00 left of 5:00")
	for _t: int in 90 * World.TICK_RATE:
		w.step()
	hud.show_world(w)
	assert_eq(hud.scoreboard_summary(), "Capture the Flags · 3:30 left of 5:00")


func test_capture_the_flags_lists_who_owns_each_flag() -> void:
	var w: World = _world(CTF)
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	assert_eq(hud.scoreboard_flag_lines(), PackedStringArray(["Flag 1: nobody", "Flag 2: nobody", "Flag 3: nobody"]))
	w.skirmish.flag_owner[1] = DARK
	w.skirmish.flag_owner[2] = LIGHT
	w.skirmish.flag_capture_side[0] = LIGHT
	w.skirmish.flag_progress[0] = int(w.skirmish.rules.capture_ticks * 0.5)
	hud.show_world(w)
	assert_eq(
		hud.scoreboard_flag_lines(),
		PackedStringArray(["Flag 1: nobody (Light capturing, 50%)", "Flag 2: Dark", "Flag 3: Light"])
	)


func test_the_scoreboard_never_takes_the_mouse() -> void:
	var hud: SkirmishHud = _hud(_world())
	hud.toggle_scoreboard()
	assert_eq(hud.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	for node: Node in hud.find_children("*", "Control", true, false):
		var control: Control = node as Control
		assert_eq(control.mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s ignores the mouse" % control.name)


func test_the_hud_never_changes_the_world() -> void:
	var w: World = _world(CTF)
	_armies(w)
	var before: String = w.state_hash()
	var hud: SkirmishHud = _hud(w)
	hud.toggle_scoreboard()
	hud.show_world(w)
	hud._unhandled_input(_key(KEY_F7))
	assert_eq(w.state_hash(), before)


# --- the overhead map ---------------------------------------------------------


func test_the_map_marks_no_flags_without_a_skirmish_or_a_world() -> void:
	var w: World = World.new(1, TestTerrains.flat(60, 60), _catalog)
	assert_eq(_map(w).flag_marks().size(), 0)
	var bare: OverheadMap = OverheadMap.new()
	add_child_autofree(bare)
	bare.setup(w.terrain, null)
	assert_eq(bare.flag_marks().size(), 0, "the old two-argument call still works")


func test_the_map_marks_the_flags_the_mode_uses() -> void:
	assert_eq(_map(_world(BC)).flag_marks().size(), 0)
	var hill: Array[Dictionary] = _map(_world(KOTH)).flag_marks()
	assert_eq(hill.size(), 1)
	assert_eq(hill[0]["flag"], 0)
	assert_eq(_map(_world(CTF)).flag_marks().size(), 3)


func test_the_maps_flags_sit_where_the_flags_are_north_up() -> void:
	var map: OverheadMap = _map(_world(CTF))
	var marks: Array[Dictionary] = map.flag_marks()
	var middle: Vector2 = marks[0]["at"]
	var north: Vector2 = marks[1]["at"]
	var south: Vector2 = marks[2]["at"]
	assert_almost_eq(middle.x, 400.0, 12.0, "the middle of an 800 px map")
	assert_almost_eq(middle.y, 300.0, 12.0)
	assert_lt(north.y, middle.y, "z = 0 is the top edge, so the north flag is above")
	assert_gt(south.y, middle.y)
	assert_almost_eq(north.x, middle.x, 0.5)


func test_the_maps_flags_are_in_their_holders_colors() -> void:
	var w: World = _world(CTF)
	var map: OverheadMap = _map(w)
	w.skirmish.flag_owner[0] = LIGHT
	w.skirmish.flag_owner[1] = DARK
	var marks: Array[Dictionary] = map.flag_marks()
	assert_eq(marks[0]["color"], SideColors.LIGHT)
	assert_eq(marks[1]["color"], SideColors.DARK)
	assert_eq(marks[2]["color"], SideColors.NEUTRAL)


func test_the_maps_hill_is_in_its_holders_color() -> void:
	var w: World = _world(KOTH)
	var map: OverheadMap = _map(w)
	w.skirmish.hill_holder = DARK
	assert_eq(map.flag_marks()[0]["color"], SideColors.DARK)
	w.skirmish.hill_holder = CONTESTED
	var flashing: Color = map.flag_marks()[0]["color"]
	assert_true(flashing == SideColors.LIGHT or flashing == SideColors.DARK)


func test_drawing_the_map_with_flags_works_and_leaves_the_world_alone() -> void:
	var w: World = _world(CTF)
	_armies(w)
	var map: OverheadMap = _map(w)
	var before: String = w.state_hash()
	map.visible = true
	await wait_process_frames(2)
	assert_eq(w.state_hash(), before)


# --- MainView: a skirmish launch ----------------------------------------------


func test_a_skirmish_gets_its_flags_and_hud_and_a_campaign_mission_does_not() -> void:
	var main: MainView = _main(CTF)
	assert_not_null(main.get_node_or_null("Flags"))
	assert_eq((main.get_node("Flags") as FlagsView).flag_count_shown(), 3)
	assert_not_null(main.get_node_or_null("Hud/SkirmishHud"))
	var campaign: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	campaign.launch = ViewFixtures.launch()
	add_child_autofree(campaign)
	assert_null(campaign.get_node_or_null("Flags"))
	assert_null(campaign.get_node_or_null("Hud/SkirmishHud"))


func test_the_flags_by_mode_in_the_real_scene() -> void:
	assert_eq((_main(BC).get_node("Flags") as FlagsView).flag_count_shown(), 0)
	assert_eq((_main(KOTH).get_node("Flags") as FlagsView).flag_count_shown(), 1)
	assert_eq((_main(CTF).get_node("Flags") as FlagsView).flag_count_shown(), 3)


func test_the_flags_follow_the_world_as_it_steps() -> void:
	var main: MainView = _main(CTF)
	_step(main)
	var flags: FlagsView = main.get_node("Flags") as FlagsView
	main.world.skirmish.flag_owner[1] = DARK
	_step(main)
	assert_eq(flags.banner_color(1), SideColors.DARK, "the step brought the banner up to date")


func test_the_clock_names_the_mode_and_counts_down_in_the_real_scene() -> void:
	var main: MainView = _main(KOTH)
	var hud: SkirmishHud = main.get_node("Hud/SkirmishHud") as SkirmishHud
	assert_true(hud.clock_text().begins_with("King of the Hill · 10:00"), hud.clock_text())
	_step(main, 60)
	assert_true(hud.clock_text().begins_with("King of the Hill · 9:58"), hud.clock_text())
	_step(main, 30)
	assert_true(hud.clock_text().begins_with("King of the Hill · 9:57"), hud.clock_text())


func test_f7_in_the_real_scene_opens_and_closes_the_scoreboard() -> void:
	var main: MainView = _main()
	var hud: SkirmishHud = main.get_node("Hud/SkirmishHud") as SkirmishHud
	_step(main)
	assert_false(hud.scoreboard_visible())
	_push(_key(KEY_F7))
	assert_true(hud.scoreboard_visible())
	assert_eq(hud.scoreboard_rows()[1][1], "2 / 2", "filled in with the armies")
	_push(_key(KEY_F7))
	assert_false(hud.scoreboard_visible())


func test_the_scoreboard_opens_while_paused_too() -> void:
	var main: MainView = _main()
	var hud: SkirmishHud = main.get_node("Hud/SkirmishHud") as SkirmishHud
	_step(main)
	main.paused = true
	_push(_key(KEY_F7))
	assert_true(hud.scoreboard_visible())


func test_the_stats_label_points_at_the_scoreboard_key() -> void:
	var main: MainView = _main()
	main._process(0.016)
	var label: Label = main.get_node("Hud/StatsLabel") as Label
	assert_true(label.text.contains("(F5 AI overlay, F7 scoreboard)"), label.text)
	assert_false(label.text.contains("F6"))


func test_a_dark_player_selects_only_dark_units() -> void:
	var main: MainView = _main(KOTH, DARK)
	_step(main)
	var controller: SelectionController = _controller(main)
	assert_eq(controller.side, DARK, "the mouse commands the player's side from the start")
	for unit: Unit in _units_of(main.world, DARK):
		assert_true(controller._selectable(unit.id), "a Dark unit is the player's")
	var enemies: Array[Unit] = _units_of(main.world, LIGHT)
	assert_eq(enemies.size(), 2)
	for unit: Unit in enemies:
		assert_false(controller._selectable(unit.id), "a Light unit is the AI's")
	assert_eq((main.get_node("Units") as UnitsView)._viewer, DARK, "and the view is theirs too")


func test_a_light_player_selects_only_light_units() -> void:
	var main: MainView = _main(KOTH, LIGHT)
	_step(main)
	var controller: SelectionController = _controller(main)
	for unit: Unit in main.world.units:
		assert_eq(controller._selectable(unit.id), unit.faction == LIGHT)


func test_the_debug_keys_do_nothing_in_a_skirmish() -> void:
	var main: MainView = _main(KOTH, DARK)
	_step(main, 2)
	var controller: SelectionController = _controller(main)
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	assert_false(bar.is_switch_side_visible())
	_push(_key(KEY_F9))
	assert_eq(controller.side, DARK, "F9 doesn't hand the mouse to the enemy")
	controller.switch_side()
	assert_eq(controller.side, DARK)
	var before: String = main.world.state_hash()
	_push(_key(KEY_F6))
	assert_eq(main.world.state_hash(), before, "F6 enqueued no weather")
	_step(main, 40)
	assert_eq(main.world.weather.rain, 0)
	controller.selection.select(PackedInt32Array([_units_of(main.world, DARK)[0].id]))
	_push(_key(KEY_F8))
	_step(main, 2)
	assert_false(StatusEffects.paralyzed(main.world, _units_of(main.world, DARK)[0]), "nor F8")


func test_the_status_line_names_the_sides_and_counts_the_living() -> void:
	var main: MainView = _main(KOTH, LIGHT)
	_step(main)
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	bar._process(0.0)
	assert_eq(bar.status_text(), "Nothing selected   |   You (Light) 2 · Enemy (Dark) 2 alive")
	_kill([_units_of(main.world, DARK)[0]])
	_step(main)
	bar._process(0.0)
	assert_true(bar.status_text().ends_with("You (Light) 2 · Enemy (Dark) 1 alive"), bar.status_text())
	assert_false(bar.status_text().contains("Controlling"), "no side to name: it is fixed")
	assert_false(bar.status_text().contains("debug"))


func test_a_dark_player_sees_their_own_side_first_and_the_ais_units_count() -> void:
	var main: MainView = _main(KOTH, DARK)
	_step(main)
	var bar: ControlBar = main.get_node("Hud/ControlBar") as ControlBar
	bar._process(0.0)
	assert_true(bar.status_text().ends_with("You (Dark) 2 · Enemy (Light) 2 alive"), bar.status_text())


func test_the_status_line_of_a_campaign_mission_is_as_it_was() -> void:
	var campaign: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	campaign.launch = ViewFixtures.launch()
	add_child_autofree(campaign)
	_step(campaign)
	var bar: ControlBar = campaign.get_node("Hud/ControlBar") as ControlBar
	bar._process(0.0)
	assert_true(bar.status_text().contains("Light 1 · Dark 1 alive"), bar.status_text())
	assert_true(bar.status_text().ends_with("Controlling: Light"), bar.status_text())


func test_the_overhead_map_gets_the_world_in_a_skirmish() -> void:
	var main: MainView = _main(CTF)
	var map: OverheadMap = main.get_node("Hud/OverheadMap") as OverheadMap
	assert_eq(map.flag_marks().size(), 3)
	var campaign: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	campaign.launch = ViewFixtures.launch()
	add_child_autofree(campaign)
	assert_eq((campaign.get_node("Hud/OverheadMap") as OverheadMap).flag_marks().size(), 0)


func test_the_views_leave_the_sim_exactly_as_it_would_have_been() -> void:
	var watched: MainView = _main(CTF)
	var plain: MainView = _main(CTF)
	_step(watched, 5)
	_push(_key(KEY_F5))
	_push(_key(KEY_F7))
	var map: OverheadMap = watched.get_node("Hud/OverheadMap") as OverheadMap
	map.visible = true
	_step(watched, 25)
	watched._process(0.016)
	_step(plain, 30)
	assert_eq(watched.world.state_hash(), plain.world.state_hash(), "drawing and overlays touch nothing")


func test_the_ai_overlay_draws_the_skirmish_commander_in_the_real_scene() -> void:
	var main: MainView = _main(KOTH)
	_step(main, 31)
	_push(_key(KEY_F5))
	var overlay: AiDebugView = main.get_node("AiDebug") as AiDebugView
	assert_true(overlay.visible)
	var labels: PackedStringArray = overlay.label_texts()
	var found: bool = false
	for text: String in labels:
		if text.contains("commander: "):
			found = true
	assert_true(found, "a commander label among %s" % [labels])
	assert_gt(overlay.line_count(), 0)


# --- the end ------------------------------------------------------------------


func test_skirmish_ended_is_sent_once_with_the_outcome_after_the_skirmish_is_decided() -> void:
	var main: MainView = _main(BC)
	_step(main)
	watch_signals(main)
	_kill(_units_of(main.world, DARK))
	_step(main)
	assert_true(main.is_frozen())
	assert_signal_not_emitted(main, "skirmish_ended", "not before a frame has passed")
	main._process(0.016)
	main._process(0.016)
	assert_signal_emit_count(main, "skirmish_ended", 1)
	assert_signal_emitted_with_parameters(main, "skirmish_ended", [MissionRuntime.Outcome.WON])
	assert_signal_not_emitted(main, "mission_ended", "a skirmish has no results of a mission")


func test_a_lost_skirmish_reports_the_defeat_from_the_players_side() -> void:
	var main: MainView = _main(BC, DARK)
	_step(main)
	watch_signals(main)
	_kill(_units_of(main.world, DARK))
	_step(main)
	main._process(0.016)
	assert_signal_emitted_with_parameters(main, "skirmish_ended", [MissionRuntime.Outcome.LOST])
	var banner: MissionHud = main.get_node("Hud/MissionHud") as MissionHud
	assert_eq(banner.shown_banner(), "Defeat")


func test_both_armies_wiped_out_at_once_is_a_draw_with_its_banner() -> void:
	var main: MainView = _main(BC)
	_step(main)
	watch_signals(main)
	_kill(_units_of(main.world, LIGHT))
	_kill(_units_of(main.world, DARK))
	_step(main)
	assert_eq(main.world.skirmish.winner, SkirmishRuntime.DRAW)
	var banner: MissionHud = main.get_node("Hud/MissionHud") as MissionHud
	assert_eq(banner.shown_banner(), "Draw")
	main._process(0.016)
	assert_signal_emitted_with_parameters(main, "skirmish_ended", [MissionRuntime.Outcome.DRAW])


func test_a_skirmish_that_has_not_ended_keeps_stepping_and_sends_nothing() -> void:
	var main: MainView = _main()
	watch_signals(main)
	_step(main, 5)
	main._process(0.016)
	assert_eq(main.world.tick, 5)
	assert_false(main.is_frozen())
	assert_signal_not_emitted(main, "skirmish_ended")
