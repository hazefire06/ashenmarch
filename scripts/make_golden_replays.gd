extends SceneTree
## Records the golden replays (`make golden-replays`) into
## data/replays/golden: the files every build is checked against for
## determinism (`make verify-replays`, the exported apps, the web build). They
## are recorded once, here, and played everywhere else; the playtest pilot
## that gives the orders thinks in float vectors, so it must never be re-run
## on another platform to make "the same" game.
##
##   riverside_t2   Riverside at Normal, the competent pilot, to the outcome.
##   old_mill_t4    Old Mill at the hardest tier, the competent pilot: waves of
##                  every Dark type, rain mid-mission, fire arrows, satchels,
##                  grenades, gas and lightning.
##   skirmish_ctf   AI against AI on The Ford, Capture the Flags: no commands at
##                  all, so it checks the commanders and the scoring alone.
##   riverside_orders_t2
##                  Riverside at Normal for DRILL_TICKS, the player's side
##                  given every Phase 11 order (OrdersDrill): facing, rotate,
##                  guard, scatter, retreat, a loop and a back-and-forth.
##
## GOLDEN=name,name (`make golden-replays GOLDEN=riverside_orders_t2`) records
## only those, so adding a golden doesn't re-record the rest.
##
## Regenerate them, deliberately, whenever a change alters what the sim does
## (any balance or rule change does): `make verify-replays` fails until then.
## Each prints its length, outcome, commands and final hash.

const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
const SKIRMISH_PATH: String = "res://data/skirmish/skirmish.tres"
## The campaign seed the mission goldens are played from.
const CAMPAIGN_SEED: int = 20261007
const SKIRMISH_SEED: int = 20261008
## A run that hasn't ended by now is cut here.
const MAX_TICKS: int = 15 * 60 * World.TICK_RATE
## The orders drill is cut here: it isn't trying to win.
const DRILL_TICKS: int = 200 * World.TICK_RATE

var _catalog: UnitCatalog


func _initialize() -> void:
	quit(_run())


func _run() -> int:
	_catalog = load(CATALOG_PATH) as UnitCatalog
	var campaign: CampaignDef = load(CAMPAIGN_PATH) as CampaignDef
	var only: PackedStringArray = OS.get_environment("GOLDEN").split(",", false)
	var failed: int = 0
	if _wanted(only, "riverside_t2"):
		failed += _mission(campaign, 0, 2, "riverside_t2")
	if _wanted(only, "old_mill_t4"):
		failed += _mission(campaign, 2, 4, "old_mill_t4")
	if _wanted(only, "skirmish_ctf"):
		failed += _skirmish("skirmish_ctf")
	if _wanted(only, "riverside_orders_t2"):
		failed += _drill(campaign, 0, 2, "riverside_orders_t2")
	return 1 if failed > 0 else 0


static func _wanted(only: PackedStringArray, file_name: String) -> bool:
	return only.is_empty() or only.has(file_name)


func _mission(campaign: CampaignDef, index: int, tier: int, file_name: String) -> int:
	var mission: MissionDef = campaign.missions[index]
	var state: CampaignState = CampaignState.new_campaign(CAMPAIGN_SEED, tier)
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), campaign.soldier_names)
	var deploy: DeployCommand = plan.command(0, mission)
	var world_seed: int = state.mission_seed(index)
	var world: World = MissionSetup.create_world(mission, tier, world_seed, deploy, _catalog)
	if world == null:
		printerr("golden: %s didn't build" % file_name)
		return 1
	var replay: Replay = Replay.for_mission(mission.resource_path, tier, world_seed, deploy)
	var recorder: ReplayRecorder = ReplayRecorder.new(replay)
	world.recorder = recorder
	var pilot: PlaytestPilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT, mission)
	world.step()
	while world.mission.outcome == MissionRuntime.Outcome.NONE and world.tick < MAX_TICKS:
		if world.tick == 1 or world.tick % PlaytestPilot.THINK_TICKS == 0:
			pilot.think(world)
		world.step()
	var outcome: String = MissionRuntime.Outcome.keys()[world.mission.outcome]
	return _save(world, recorder, replay, file_name, "%s (tier %d)" % [mission.display_name, tier], "Campaign", outcome)


func _drill(campaign: CampaignDef, index: int, tier: int, file_name: String) -> int:
	var mission: MissionDef = campaign.missions[index]
	var state: CampaignState = CampaignState.new_campaign(CAMPAIGN_SEED, tier)
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), campaign.soldier_names)
	var deploy: DeployCommand = plan.command(0, mission)
	var world_seed: int = state.mission_seed(index)
	var world: World = MissionSetup.create_world(mission, tier, world_seed, deploy, _catalog)
	if world == null:
		printerr("golden: %s didn't build" % file_name)
		return 1
	var replay: Replay = Replay.for_mission(mission.resource_path, tier, world_seed, deploy)
	var recorder: ReplayRecorder = ReplayRecorder.new(replay)
	world.recorder = recorder
	world.step()
	while world.mission.outcome == MissionRuntime.Outcome.NONE and world.tick < DRILL_TICKS:
		for command: SimCommand in OrdersDrill.orders(world, UnitType.Faction.LIGHT):
			world.enqueue(command)
		world.step()
	var outcome: String = MissionRuntime.Outcome.keys()[world.mission.outcome]
	return _save(
		world, recorder, replay, file_name, "%s (tier %d), every Phase 11 order" % [mission.display_name, tier],
		"Campaign", outcome
	)


func _skirmish(file_name: String) -> int:
	var runner: SkirmishRunner = SkirmishRunner.new(_catalog, load(SKIRMISH_PATH) as SkirmishCatalog)
	var setup: SkirmishSetup = runner.make_setup(
		&"the_ford", SkirmishRules.Mode.CAPTURE_THE_FLAGS, 10, 1000, &"light_balanced", &"dark_balanced",
		0, SKIRMISH_SEED, true
	)
	var world: World = SkirmishSetup.create_world(setup, _catalog) if setup != null else null
	if world == null:
		printerr("golden: %s didn't build" % file_name)
		return 1
	var replay: Replay = Replay.for_skirmish(setup)
	var recorder: ReplayRecorder = ReplayRecorder.new(replay)
	world.recorder = recorder
	while world.mission.outcome == MissionRuntime.Outcome.NONE and world.tick < MAX_TICKS:
		world.step()
	var outcome: String = MissionRuntime.Outcome.keys()[world.mission.outcome]
	return _save(world, recorder, replay, file_name, "The Ford, AI against AI", "Capture the Flags", outcome)


func _save(
	world: World, recorder: ReplayRecorder, replay: Replay, file_name: String, title: String,
	mode: String, outcome: String
) -> int:
	recorder.finish(world)
	replay.game_version = str(ProjectSettings.get_setting("application/config/version", ""))
	replay.summary = {"title": title, "mode": mode, "outcome": outcome, "recorded_at": 0, "golden": true}
	var path: String = ReplayStore.GOLDEN_DIR.path_join("%s.%s" % [file_name, ReplayStore.EXTENSION])
	var error: Error = ReplayStore.save(replay, ProjectSettings.globalize_path(path))
	if error != OK:
		printerr("golden: couldn't write %s (%s)" % [path, error_string(error)])
		return 1
	print("golden: %s  %s  %d ticks (%d:%02d)  %s  %d commands  %d checkpoints  final %s" % [
		file_name, title, replay.end_tick, replay.seconds() / 60, replay.seconds() % 60, outcome,
		replay.commands.size(), replay.checkpoints.size(), replay.final_hash.left(16),
	])
	return 0
