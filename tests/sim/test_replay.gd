extends GutTest
## Replays: a campaign mission played by the playtest pilot and a skirmish
## given scripted orders are recorded, pushed through var_to_bytes as a file
## would be, and played back to identical checkpoints and final hash. A
## tampered replay diverges and names the part of the state that differs;
## damaged replays are refused with a reason; the recorder never records the
## setup's own commands; subsystem hashes localize a difference.

const CAMPAIGN: String = "res://data/campaign/campaign.tres"
const SKIRMISH_CATALOG: String = "res://data/skirmish/skirmish.tres"
const MISSION_TICKS: int = 2400
const SKIRMISH_TICKS: int = 1500
const SEED: int = 4242
const M: int = 1000

var _catalog: UnitCatalog
var _campaign: CampaignDef
# Recorded once, shared (recording is the slow part).
var _mission_replay: Replay
var _skirmish_replay: Replay
var _mission_world: World
var _skirmish_world: World


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	_campaign = load(CAMPAIGN) as CampaignDef
	_record_mission()
	_record_skirmish()


func test_a_recorded_mission_plays_back_identically() -> void:
	assert_eq(_mission_replay.end_tick, MISSION_TICKS)
	assert_gt(_mission_replay.commands.size(), 10, "the pilot gave orders")
	assert_eq(_mission_replay.checkpoints.size(), MISSION_TICKS / ReplayRecorder.CHECKPOINT_TICKS)
	var player: ReplayPlayer = _play(_through_bytes(_mission_replay))
	assert_eq(player.error, "")
	assert_true(player.verified(), "every checkpoint and the end match: %s" % player.divergence)
	assert_eq(player.matched, _mission_replay.checkpoints.size())
	assert_eq(player.world.state_hash(), _mission_world.state_hash())


func test_a_recorded_skirmish_plays_back_identically() -> void:
	var player: ReplayPlayer = _play(_through_bytes(_skirmish_replay))
	assert_eq(player.error, "")
	assert_true(player.verified(), "every checkpoint and the end match: %s" % player.divergence)
	assert_eq(player.world.state_hash(), _skirmish_world.state_hash())
	assert_not_null(player.world.skirmish)


func test_playback_can_be_spread_over_calls() -> void:
	var player: ReplayPlayer = ReplayPlayer.new(_through_bytes(_skirmish_replay), _catalog)
	var played: int = 0
	while not player.is_done():
		played += player.advance(97)
	assert_eq(played, SKIRMISH_TICKS)
	assert_eq(player.advance(10), 0, "nothing plays past the end")
	assert_true(player.verified())


func test_a_changed_order_diverges_and_says_where() -> void:
	var tampered: Replay = _through_bytes(_mission_replay)
	var index: int = _first_move_index(tampered)
	assert_gt(index, -1, "the pilot moved someone")
	var record: Array = tampered.commands[index]
	record[3] = (record[3] as int) + 15 * M
	var player: ReplayPlayer = _play(tampered)
	assert_false(player.verified())
	assert_false(player.divergence.is_empty())
	var order_tick: int = record[1]
	assert_gt(player.divergence["tick"], order_tick, "found at the first checkpoint after the order")
	assert_lte(
		player.divergence["tick"], order_tick + ReplayRecorder.CHECKPOINT_TICKS, "and no later"
	)
	assert_has(player.divergence["parts"], "entities")
	assert_eq(player.matched * ReplayRecorder.CHECKPOINT_TICKS, (player.divergence["tick"] as int) - ReplayRecorder.CHECKPOINT_TICKS)


func test_a_changed_seed_diverges_in_the_header() -> void:
	var tampered: Replay = _through_bytes(_skirmish_replay)
	tampered.setup["seed"] = (tampered.setup["seed"] as int) + 1
	var player: ReplayPlayer = _play(tampered)
	assert_eq(player.divergence.get("tick"), ReplayRecorder.CHECKPOINT_TICKS)
	assert_has(player.divergence["parts"], "header")


func test_the_recorder_leaves_out_the_setups_own_commands() -> void:
	var world: World = SkirmishSetup.create_world(_skirmish_setup(), _catalog)
	var replay: Replay = Replay.new()
	world.recorder = ReplayRecorder.new(replay)
	for t: int in 5:
		world.step()
	assert_eq(replay.commands, [], "the deploy and herbs were queued before it was attached")
	world.enqueue(StopUnitsCommand.new(world.tick, PackedInt32Array([1])))
	assert_eq(replay.commands.size(), 1)
	assert_false(world.enqueue(StopUnitsCommand.new(0, PackedInt32Array([1]))), "a late command")
	assert_eq(replay.commands.size(), 1, "is refused and not recorded")


func test_the_skirmish_setup_survives_its_dictionary() -> void:
	var setup: SkirmishSetup = _skirmish_setup()
	var data: Dictionary = setup.to_dict()
	var back: SkirmishSetup = SkirmishSetup.from_dict(bytes_to_var(var_to_bytes(data)))
	assert_not_null(back)
	assert_eq(back.to_dict(), data)
	assert_eq(back.validate(_catalog), PackedStringArray())
	var no_map: Dictionary = data.duplicate(true)
	no_map["map"] = "res://maps/nowhere/skirmish.tres"
	assert_null(SkirmishSetup.from_dict(no_map))
	var bad_mode: Dictionary = data.duplicate(true)
	bad_mode["mode"] = 9
	assert_null(SkirmishSetup.from_dict(bad_mode))


func test_damaged_replays_are_refused_with_a_reason() -> void:
	var good: Dictionary = _mission_replay.to_dict()
	var cases: Dictionary[String, Variant] = {
		"not a replay": "hello",
		"replay format 2": _with(good, "format", 2),
		"wrong type": _with(good, "end_tick", "long"),
		"unknown replay kind": _with(good, "kind", 7),
		"command record": _with(good, "commands", [[99, 0]]),
		"out of order": _with(good, "commands", [
			CommandCodec.encode(StopUnitsCommand.new(50, PackedInt32Array([1]))),
			CommandCodec.encode(StopUnitsCommand.new(40, PackedInt32Array([1]))),
		]),
		"checkpoint is malformed": _with(good, "checkpoints", [[300, "abc"]]),
		"deploy doesn't decode": _with(good, "setup", {
			"mission": "res://x.tres", "tier": 2, "seed": 1, "deploy": [1, 0],
		}),
	}
	for reason: String in cases:
		var problems: Array[String] = []
		assert_null(Replay.from_dict(cases[reason], problems), reason)
		assert_eq(problems.size(), 1, reason)
		if problems.size() == 1:
			assert_string_contains(problems[0], reason)
	assert_not_null(Replay.from_dict(good), "and the original still loads")


func test_a_replay_of_something_this_build_lacks_says_so() -> void:
	var missing: Replay = _through_bytes(_mission_replay)
	missing.setup["mission"] = "res://data/missions/nowhere.tres"
	var player: ReplayPlayer = ReplayPlayer.new(missing, _catalog)
	assert_null(player.world)
	assert_string_contains(player.error, "no mission")
	assert_true(player.is_done())
	assert_false(player.verified())
	var broken: Replay = _through_bytes(_skirmish_replay)
	broken.setup["map"] = "res://maps/nowhere/skirmish.tres"
	assert_null(ReplayPlayer.new(broken, _catalog).world)


func test_subsystem_hashes_point_at_the_part_that_differs() -> void:
	var a: World = SkirmishSetup.create_world(_skirmish_setup(), _catalog)
	var b: World = SkirmishSetup.create_world(_skirmish_setup(), _catalog)
	for t: int in 3:
		a.step()
		b.step()
	assert_eq(a.subsystem_hashes(), b.subsystem_hashes())
	assert_has(a.subsystem_hashes().keys(), "fire")
	var lit: bool = false
	for spot: int in range(60, 400, 20):
		lit = b.ignite(spot * M, spot * M, 0)
		if lit:
			break
	assert_true(lit, "found grass to light")
	var differing: PackedStringArray = ReplayPlayer.differing_parts(
		ReplayRecorder.plain_hashes(a), ReplayRecorder.plain_hashes(b)
	)
	assert_eq(differing, PackedStringArray(["fire"]))
	assert_ne(a.state_hash(), b.state_hash())


# Riverside, the campaign's first mission at Normal, played by the competent
# pilot for MISSION_TICKS with a recorder attached, as MainView will attach one.
func _record_mission() -> void:
	var mission: MissionDef = _campaign.missions[0]
	var state: CampaignState = CampaignState.new_campaign(SEED, 2)
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), _campaign.soldier_names)
	var deploy: DeployCommand = plan.command(0, mission)
	var world_seed: int = state.mission_seed(0)
	_mission_world = MissionSetup.create_world(mission, 2, world_seed, deploy, _catalog)
	_mission_replay = Replay.for_mission(mission.resource_path, 2, world_seed, deploy)
	var recorder: ReplayRecorder = ReplayRecorder.new(_mission_replay)
	_mission_world.recorder = recorder
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT, mission)
	_mission_world.step()
	while _mission_world.tick < MISSION_TICKS:
		if _mission_world.tick == 1 or _mission_world.tick % PlaytestPilot.THINK_TICKS == 0:
			pilot.think(_mission_world)
		_mission_world.step()
	recorder.finish(_mission_world)


# Old Mill Capture the Flags, the player's army marched about by hand.
func _record_skirmish() -> void:
	var setup: SkirmishSetup = _skirmish_setup()
	_skirmish_world = SkirmishSetup.create_world(setup, _catalog)
	_skirmish_replay = Replay.for_skirmish(setup)
	var recorder: ReplayRecorder = ReplayRecorder.new(_skirmish_replay)
	_skirmish_world.recorder = recorder
	_skirmish_world.step()
	var mine: PackedInt32Array = PackedInt32Array()
	for unit: Unit in _skirmish_world.units:
		if unit.faction == setup.player_faction():
			mine.append(unit.id)
	var flag: Vector2i = setup.map.flag(0)
	while _skirmish_world.tick < SKIRMISH_TICKS:
		match _skirmish_world.tick:
			30:
				_skirmish_world.enqueue(AttackMoveCommand.new(30, mine, flag.x, flag.y, Formations.Kind.BOX))
			600:
				_skirmish_world.enqueue(StopUnitsCommand.new(600, mine.slice(0, 3)))
			700:
				_skirmish_world.enqueue(UseSpecialCommand.new(700, mine))
			900:
				_skirmish_world.enqueue(MoveUnitsCommand.new(900, mine, flag.x + 20 * M, flag.y, Formations.Kind.WEDGE))
		_skirmish_world.step()
	recorder.finish(_skirmish_world)


func _skirmish_setup() -> SkirmishSetup:
	var runner: SkirmishRunner = SkirmishRunner.new(_catalog, load(SKIRMISH_CATALOG) as SkirmishCatalog)
	return runner.make_setup(
		&"old_mill", SkirmishRules.Mode.CAPTURE_THE_FLAGS, 5, 400, &"light_balanced", &"dark_balanced",
		0, SEED, false
	)


# The replay as it comes back from a file: to_dict, var_to_bytes and back.
func _through_bytes(replay: Replay) -> Replay:
	var back: Replay = Replay.from_dict(bytes_to_var(var_to_bytes(replay.to_dict())))
	assert_not_null(back, "the replay survives bytes")
	return back


func _play(replay: Replay) -> ReplayPlayer:
	var player: ReplayPlayer = ReplayPlayer.new(replay, _catalog)
	player.advance(replay.end_tick + 1)
	return player


func _first_move_index(replay: Replay) -> int:
	for i: int in replay.commands.size():
		var kind: int = replay.commands[i][0]
		if kind == CommandCodec.Kind.MOVE or kind == CommandCodec.Kind.ATTACK_MOVE:
			return i
	return -1


func _with(data: Dictionary, key: String, value: Variant) -> Dictionary:
	var changed: Dictionary = data.duplicate(true)
	changed[key] = value
	return changed
