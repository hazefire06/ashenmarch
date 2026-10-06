extends GutTest
## The skirmish playtest (scripts/playtest/skirmish_runner.gd and its result and
## report): one very short run of each matrix finishes and returns a
## well-formed record, the pilot is sent where the mode says, a draw is called
## a draw, and the tables read back what the runs wrote. The long matrices are
## the playtest's own job (`make skirmish-playtest`); these are a minute of
## game time on Old Mill.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BC: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
const KOTH: SkirmishRules.Mode = SkirmishRules.Mode.KING_OF_THE_HILL
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS
const SKIRMISH_CATALOG: String = "res://data/skirmish/skirmish.tres"
const MAP: StringName = &"old_mill"
const MINUTES: int = 1
const BUDGET: int = 400
const SMALL_BUDGET: int = 150
const SEED: int = 1000

var _catalog: UnitCatalog
var _skirmish: SkirmishCatalog
var _runner: SkirmishRunner
# The two short runs, shared by the tests that read them (they are the slow part).
var _a: SkirmishResult
var _b: SkirmishResult
var _b_pilot: PlaytestPilot
# One world to snap the routes against (route_for only reads it).
var _route_world: World


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	_skirmish = load(SKIRMISH_CATALOG)
	_runner = SkirmishRunner.new(_catalog, _skirmish)
	_runner.record_commands = true
	_a = _runner.play(MAP, KOTH, MINUTES, BUDGET, &"light_balanced", &"dark_balanced", 0, SEED)
	_runner.release()
	_b = _runner.play(
		MAP, KOTH, MINUTES, BUDGET, &"light_balanced", &"dark_balanced", 1, SEED, PlaytestPilot.Kind.COMPETENT
	)
	_b_pilot = _runner.last_pilot
	_route_world = _world_of(KOTH, 0)


func after_all() -> void:
	_runner.release()


# A world of the setup the runner would play.
func _world_of(mode: SkirmishRules.Mode, light_start: int, both_ai: bool = false) -> World:
	var setup: SkirmishSetup = _runner.make_setup(
		MAP, mode, MINUTES, BUDGET, &"light_balanced", &"dark_balanced", light_start, SEED, both_ai
	)
	return SkirmishSetup.create_world(setup, _catalog)


func _setup_of(mode: SkirmishRules.Mode, light_start: int) -> SkirmishSetup:
	return _runner.make_setup(MAP, mode, MINUTES, BUDGET, &"light_balanced", &"dark_balanced", light_start, SEED, false)


# ---- the two runs ----

func test_a_commander_against_commander_run_finishes_and_is_well_formed() -> void:
	assert_not_null(_a)
	assert_eq(_a.matrix, "A")
	assert_eq(_a.map_id, MAP)
	assert_eq(_a.mode, "king_of_the_hill")
	assert_eq(_a.minutes, MINUTES)
	assert_eq(_a.budget, BUDGET)
	assert_eq(_a.light_template, &"light_balanced")
	assert_eq(_a.dark_template, &"dark_balanced")
	assert_eq(_a.light_start, 0)
	assert_eq(_a.world_seed, SEED)
	assert_eq(_a.pilot, "ai", "no pilot played")
	assert_eq(_a.commands, 0)
	_assert_decided(_a)


func test_a_pilot_against_commander_run_finishes_and_is_well_formed() -> void:
	assert_not_null(_b)
	assert_eq(_b.matrix, "B")
	assert_eq(_b.pilot, "competent")
	assert_eq(_b.light_start, 1)
	assert_gt(_b.commands, 0, "the pilot gave orders")
	_assert_decided(_b)


# What every finished run shares: decided, in time, both armies fielded, and the
# scores in range.
func _assert_decided(r: SkirmishResult) -> void:
	assert_true(r.winner in [SkirmishResult.LIGHT, SkirmishResult.DARK, SkirmishResult.DRAW], "decided: " + r.winner)
	assert_true(r.end_reason in [SkirmishResult.REASON_TIME, SkirmishResult.REASON_ELIMINATION])
	assert_lte(r.end_tick, MINUTES * 60 * World.TICK_RATE, "decided by the time limit at the latest")
	if r.end_reason == SkirmishResult.REASON_TIME:
		assert_eq(r.end_tick, MINUTES * 60 * World.TICK_RATE)
	assert_gt(r.light_deployed, 0)
	assert_gt(r.dark_deployed, 0)
	assert_between(r.light_alive, 0, r.light_deployed)
	assert_between(r.dark_alive, 0, r.dark_deployed)
	assert_eq(r.light_kills, r.dark_lost(), "Light's kills are Dark's losses")
	assert_eq(r.dark_kills, r.light_lost())
	assert_between(r.light_hold_s, 0, MINUTES * 60)
	assert_between(r.dark_hold_s, 0, MINUTES * 60)
	assert_lte(r.light_hold_s + r.dark_hold_s, MINUTES * 60, "the hill is held by one side at a time")
	assert_ne(r.state_hash, "")
	assert_gte(r.wall_ms, 0)
	assert_true(r.notes.is_empty(), "nothing looked wrong: %s" % [r.notes])
	assert_string_contains(r.line(), "seed=%d" % SEED)
	var back: SkirmishResult = SkirmishResult.from_dict(JSON.parse_string(JSON.stringify(r.to_dict())))
	assert_not_null(back, "it survives JSON")
	assert_eq(back.to_dict(), r.to_dict())


func test_the_pilot_marches_at_the_hill_in_king_of_the_hill() -> void:
	var hill: Vector2i = _skirmish.skirmish_map(MAP).flag(_skirmish.skirmish_map(MAP).hill)
	var pilot: PlaytestPilot = _b_pilot
	assert_not_null(pilot)
	var marches: Array[AttackMoveCommand] = []
	for command: SimCommand in pilot.recorded:
		if command is AttackMoveCommand:
			marches.append(command as AttackMoveCommand)
	assert_false(marches.is_empty())
	var first: AttackMoveCommand = marches[0]
	assert_lt(Vector2(first.x - hill.x, first.z - hill.y).length(), 4000.0, "the melee's first order is for the hill")


func test_the_same_settings_replay_the_same_run() -> void:
	# Small armies, so the two extra runs are cheap; a pilot plays so its thinks are checked too.
	var hashes: Array[String] = []
	for i: int in 2:
		var r: SkirmishResult = _runner.play(
			MAP, KOTH, MINUTES, SMALL_BUDGET, &"light_balanced", &"dark_balanced", 1, SEED, PlaytestPilot.Kind.NAIVE
		)
		assert_not_null(r)
		hashes.append(r.state_hash)
		assert_gt(r.commands, 0)
	assert_eq(hashes[0], hashes[1])
	assert_ne(hashes[0], "")


func test_a_run_that_cannot_be_built_is_null() -> void:
	assert_null(_runner.make_setup(&"nowhere", KOTH, MINUTES, BUDGET, &"light_balanced", &"dark_balanced", 0, SEED, false))
	assert_push_error("no map nowhere")
	assert_null(
		_runner.make_setup(MAP, KOTH, MINUTES, BUDGET, &"dark_balanced", &"dark_balanced", 0, SEED, false),
		"a Dark template can't be Light's"
	)
	assert_push_error("must be a Light template")
	assert_null(_runner.make_setup(MAP, KOTH, MINUTES, BUDGET, &"light_balanced", &"light_balanced", 0, SEED, false))
	assert_push_error("must be a Light template")


# ---- where the pilot goes ----

func test_king_of_the_hill_goes_to_the_hill_and_holds() -> void:
	var map: SkirmishMap = _skirmish.skirmish_map(MAP)
	var route: Array[Vector2i] = SkirmishRunner.route_for(_setup_of(KOTH, 0), _route_world)
	assert_eq(route.size(), 1)
	assert_lt((route[0] - map.flag(map.hill)).length(), 4000.0)
	assert_true(SkirmishRunner.holds_at_end(KOTH))
	assert_true(SkirmishRunner.holds_at_end(CTF))
	assert_false(SkirmishRunner.holds_at_end(BC), "Body Count hunts")


func test_capture_the_flags_takes_every_flag_nearest_first_and_ends_on_the_hill() -> void:
	var map: SkirmishMap = _skirmish.skirmish_map(MAP)
	for start: int in 2:
		var from: Vector2i = map.spawn(start)
		var route: Array[Vector2i] = SkirmishRunner.route_for(_setup_of(CTF, start), _route_world)
		var flags: Array[Vector2i] = []
		for i: int in map.flag_count():
			flags.append(map.flag(i))
		flags.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return (a - from).length_squared() < (b - from).length_squared())
		assert_eq(route.size(), map.flag_count() + (0 if flags[flags.size() - 1] == map.flag(map.hill) else 1), "start %d" % start)
		for i: int in flags.size():
			assert_lt((route[i] - flags[i]).length(), 4000.0, "start %d: flag %d, nearest first" % [start, i])
		assert_lt((route[route.size() - 1] - map.flag(map.hill)).length(), 4000.0, "start %d: ends on the hill" % start)


func test_body_count_goes_to_the_middle_of_the_two_starts() -> void:
	var map: SkirmishMap = _skirmish.skirmish_map(MAP)
	var middle: Vector2 = Vector2(map.spawn(0) + map.spawn(1)) / 2.0
	var route: Array[Vector2i] = SkirmishRunner.route_for(_setup_of(BC, 1), _route_world)
	assert_eq(route.size(), 1)
	# Snapped to ground a soldier can walk to, so within a few cells of the middle.
	assert_lt((Vector2(route[0]) - middle).length(), 12000.0)


# ---- a draw is a draw ----

func test_a_draw_is_called_a_draw() -> void:
	assert_eq(SkirmishRunner.winner_name(LIGHT), "light")
	assert_eq(SkirmishRunner.winner_name(DARK), "dark")
	assert_eq(SkirmishRunner.winner_name(SkirmishRuntime.DRAW), "draw")
	assert_eq(SkirmishRunner.winner_name(SkirmishRuntime.NO_SIDE), "timeout", "never decided")
	assert_eq(PlaytestRunner.outcome_label(MissionRuntime.Outcome.DRAW), PlaytestResult.DRAW)
	assert_eq(PlaytestRunner.outcome_label(MissionRuntime.Outcome.WON), PlaytestResult.WON)
	assert_eq(PlaytestRunner.outcome_label(MissionRuntime.Outcome.LOST), PlaytestResult.LOST)
	assert_eq(PlaytestRunner.outcome_label(MissionRuntime.Outcome.NONE), PlaytestResult.TIMEOUT)


func test_a_world_never_decided_is_a_timeout_and_one_wiped_out_at_once_a_draw() -> void:
	var setup: SkirmishSetup = _runner.make_setup(MAP, BC, MINUTES, BUDGET, &"light_balanced", &"dark_balanced", 0, SEED, true)
	var w: World = SkirmishSetup.create_world(setup, _catalog)
	w.step()
	var undecided: SkirmishResult = _runner.summarize(setup, w, null, &"light_balanced")
	assert_eq(undecided.winner, SkirmishResult.TIMEOUT)
	assert_eq(undecided.end_reason, "")
	assert_eq(undecided.end_tick, w.tick)
	assert_false(undecided.notes.is_empty(), "a timeout says what it left")
	# Now both armies die on one tick.
	for unit: Unit in w.units:
		unit.kill()
	w.step()
	assert_eq(w.skirmish.winner, SkirmishRuntime.DRAW)
	assert_eq(w.mission.outcome, MissionRuntime.Outcome.DRAW)
	var r: SkirmishResult = _runner.summarize(setup, w, null, &"light_balanced")
	assert_eq(r.winner, SkirmishResult.DRAW)
	assert_eq(r.end_reason, SkirmishResult.REASON_ELIMINATION)
	assert_eq(r.light_alive, 0)
	assert_eq(r.dark_alive, 0)
	assert_string_contains(r.line(), "DRAW by elimination")


# ---- the tables ----

func _result(
	matrix: String, winner: String, minutes: float, light_lost: int, dark_lost: int, pilot: String = "ai",
	map_id: StringName = &"old_mill", mode: String = "king_of_the_hill"
) -> SkirmishResult:
	var r: SkirmishResult = SkirmishResult.new()
	r.matrix = matrix
	r.map_id = map_id
	r.mode = mode
	r.minutes = 10
	r.budget = 1000
	r.light_template = &"light_balanced"
	r.dark_template = &"dark_horde"
	r.pilot = pilot
	r.winner = winner
	r.end_reason = SkirmishResult.REASON_TIME if winner != SkirmishResult.TIMEOUT else ""
	r.end_tick = roundi(minutes * 60.0 * World.TICK_RATE)
	r.light_deployed = 20
	r.dark_deployed = 30
	r.light_alive = 20 - light_lost
	r.dark_alive = 30 - dark_lost
	return r


func test_matrix_a_is_tabled_by_side_map_mode_pairing_and_start() -> void:
	var results: Array[SkirmishResult] = [
		_result("A", "light", 10.0, 4, 30),
		_result("A", "dark", 6.0, 20, 5),
		_result("A", "draw", 10.0, 6, 6),
		_result("A", "light", 8.0, 2, 30, "ai", &"riverside", "body_count"),
	]
	results[3].light_start = 1
	var text: String = SkirmishReport.markdown(results, "T")
	assert_string_contains(text, "## Matrix A")
	assert_string_contains(text, "| all runs | 4 | 50% | 25% | 25% | 0% | 0% | 9.0 | 8.0 | 17.8 |")
	assert_string_contains(text, "| old_mill / king_of_the_hill | 3 | 33% | 33% | 33% |")
	assert_string_contains(text, "| riverside / body_count | 1 | 100% |")
	assert_string_contains(text, "| light_balanced vs dark_horde | 4 |")
	assert_string_contains(text, "| start B | 1 | 100% |")
	assert_true(text.find("riverside / body_count") < text.find("old_mill / king_of_the_hill"), "campaign order of maps")
	assert_false(text.contains("## Matrix B"))
	assert_string_contains(text, "None: every run was decided")


func test_matrix_b_is_tabled_per_pilot() -> void:
	var results: Array[SkirmishResult] = [
		_result("B", "light", 4.0, 3, 30, "competent"),
		_result("B", "light", 5.0, 5, 30, "competent"),
		_result("B", "dark", 6.0, 20, 2, "naive"),
		_result("B", "timeout", 11.0, 1, 1, "naive"),
	]
	var text: String = SkirmishReport.markdown(results, "T")
	assert_string_contains(text, "## Matrix B")
	assert_string_contains(text, "| competent | all | 2 | 100% | 0% | 0% | 0% |")
	assert_string_contains(text, "| naive | all | 2 | 0% | 50% | 0% | 50% |")
	assert_string_contains(text, "| competent | dark_horde | 2 |")
	assert_true(text.find("| competent | all") < text.find("| naive | all"), "competent first")
	assert_false(text.contains("## Matrix A"))
	assert_string_contains(text, "1 of 4 runs hit the safety cap")


func test_the_tables_read_back_from_json_lines() -> void:
	var originals: Array[SkirmishResult] = [
		_result("A", "light", 10.0, 4, 30), _result("B", "dark", 6.0, 20, 5, "naive"),
	]
	originals[0].world_seed = 5392023410520822974
	var read: Array[SkirmishResult] = []
	for r: SkirmishResult in originals:
		read.append(SkirmishResult.from_dict(JSON.parse_string(JSON.stringify(r.to_dict()))))
	assert_eq(read[0].world_seed, 5392023410520822974, "a 63-bit seed survives JSON")
	assert_eq(SkirmishReport.markdown(read, "T"), SkirmishReport.markdown(originals, "T"))
	assert_null(SkirmishResult.from_dict({"matrix": "A"}), "an incomplete line isn't a run")
	assert_null(SkirmishResult.from_dict("nonsense"))
