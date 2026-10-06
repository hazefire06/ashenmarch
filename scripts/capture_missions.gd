extends SceneTree
## Visual check of the campaign: `CAPTURE=<dir> make capture` (windowed).
##
## For each mission of the campaign, launched the way the App launches it (a
## CampaignState plan, MissionSetup, MissionLaunch, campaign mode), it saves
## three screenshots of the real game window into <dir>:
## - the opening view, 2 s of real time after the mission starts;
## - the overhead map (Tab);
## - a mid-battle frame: the competent playtest pilot (scripts/playtest/pilot.gd)
##   plays SECONDS of game time as fast as the machine steps, then the camera
##   moves to the squad and the shot is taken.
## Files are named <n>-<mission>-<shot>.png, n counting up from FIRST, so a set
## sorts in the order it was taken. Nothing is written but those PNGs. It needs
## a window: headless has no framebuffer to read.
##
## Settings are environment variables:
##   CAPTURE   the output directory (required; created if it is missing)
##   MISSIONS  comma list of mission ids, default every mission of the campaign
##   TIER      difficulty tier 0..4, default 2 (the middle)
##   SEED      campaign seed, default 1000 (the playtest's first seed)
##   SECONDS   game seconds the pilot plays before the mid-battle frame, default 90
##   FIRST     number of the first file, default 40
## e.g. CAPTURE=/tmp/shots MISSIONS=old_mill SECONDS=180 FIRST=47 make capture

const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
const MAIN_SCENE: String = "res://view/main.tscn"
const DEFAULT_TIER: int = 2
const DEFAULT_SEED: int = 1000
const DEFAULT_SECONDS: int = 90
const DEFAULT_FIRST: int = 40
## Real seconds the mission runs before its opening view is taken, long enough
## for the first frames to settle.
const OPENING_SECONDS: float = 2.0
## Real seconds the game runs at its own pace after the fast-forward, so the
## cosmetic gibs (Godot physics, which the fast-forward doesn't step) land.
const SETTLE_SECONDS: float = 1.5
## Sim ticks stepped between two rendered frames while fast-forwarding.
const TICKS_PER_FRAME: int = 30
const M: float = 1000.0

var _dir: String = OS.get_environment("CAPTURE")
var _number: int = 0
var _main: MainView
var _pilot: PlaytestPilot
var _last_think: int = -1


func _initialize() -> void:
	if _dir.is_empty():
		push_error("capture_missions: set CAPTURE=<dir> to say where the screenshots go.")
		quit(1)
		return
	if DisplayServer.get_name() == "headless":
		push_error("capture_missions: needs a window; run it without --headless.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	_number = _number_of("FIRST", DEFAULT_FIRST)
	_run.call_deferred()


func _run() -> void:
	var campaign: CampaignDef = load(CAMPAIGN_PATH) as CampaignDef
	var wanted: PackedStringArray = _list("MISSIONS")
	for index: int in campaign.missions.size():
		var mission: MissionDef = campaign.missions[index]
		if not wanted.is_empty() and not wanted.has(String(mission.id)):
			continue
		await _capture(campaign, index)
	quit()


func _capture(campaign: CampaignDef, index: int) -> void:
	var mission: MissionDef = campaign.missions[index]
	var tier: int = _number_of("TIER", DEFAULT_TIER)
	var campaign_seed: int = _number_of("SEED", DEFAULT_SEED)
	var state: CampaignState = CampaignState.new_campaign(campaign_seed, tier)
	var plan: DeployPlan = state.plan_deploy(mission, PackedInt32Array(), campaign.soldier_names)
	var launch: MissionLaunch = MissionLaunch.new(
		mission, tier, state.mission_seed(index), plan.command(0, mission), true
	)
	_main = (load(MAIN_SCENE) as PackedScene).instantiate() as MainView
	_main.launch = launch
	root.add_child(_main)
	print("%s: tier %d, seed %d" % [mission.id, tier, campaign_seed])

	# The opening: real time, no pilot, the squad where the briefing puts it.
	await _run_for(OPENING_SECONDS)
	await _save(mission.id, "opening")
	var overhead: OverheadMap = _main.get_node("Hud/OverheadMap") as OverheadMap
	overhead.toggle()
	await _save(mission.id, "overhead")
	overhead.toggle()

	# The fast-forward: the competent pilot plays, a rendered frame at a time.
	_pilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT, mission)
	_last_think = -1
	await _fast_forward(_number_of("SECONDS", DEFAULT_SECONDS) * World.TICK_RATE)
	_look_at_the_squad()
	await _run_for(SETTLE_SECONDS)
	await _save(mission.id, "battle")
	print("  %.0f s of game time; %s" % [float(_main.world.tick) / World.TICK_RATE, _outcome_text(_main.world)])

	_pilot = null
	root.remove_child(_main)
	_main.queue_free()
	_main = null
	await process_frame


# Lets the game run on its own for this many real seconds. A campaign mission
# pauses when its window is not the focused one, which a window opened from a
# terminal is not at first, so every frame un-pauses it.
func _run_for(seconds: float) -> void:
	var started_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_ms < roundi(seconds * 1000.0):
		await process_frame
		_unpause()


# Steps the sim to this tick, TICKS_PER_FRAME at a time, with the pilot looking
# once a second as it does in the playtest. Godot's own physics tick is off for
# the duration, so the only steps are these: Engine.time_scale does not speed
# the physics tick up, and a window cannot be hurried any other way.
func _fast_forward(until: int) -> void:
	_main.set_physics_process(false)
	var report_ms: int = Time.get_ticks_msec()
	while _main.world.tick < until and not _main.is_frozen():
		_unpause()
		for _step: int in TICKS_PER_FRAME:
			if _main.world.tick >= until or _main.is_frozen():
				break
			_think()
			_main._physics_process(0.0)
		await process_frame
		if Time.get_ticks_msec() - report_ms >= 5000:
			report_ms = Time.get_ticks_msec()
			print("  tick %d of %d" % [_main.world.tick, until])
	_main.set_physics_process(true)


# The pilot reads the world between two ticks: on the first and on every whole
# second after it, as the playtest harness does.
func _think() -> void:
	var tick: int = _main.world.tick
	if tick != _last_think and (tick == 1 or tick % PlaytestPilot.THINK_TICKS == 0):
		_last_think = tick
		_pilot.think(_main.world)


# Puts the camera over the middle of the soldiers still standing, keeping its
# angle and distance: the opening view looks where the mission starts.
func _look_at_the_squad() -> void:
	var sum: Vector2 = Vector2.ZERO
	var count: int = 0
	for unit: Unit in _main.world.units:
		if unit.is_alive() and unit.faction == UnitType.Faction.LIGHT and not _main.world.ai.controls(unit.id):
			sum += Vector2(unit.x, unit.z) / M
			count += 1
	if count == 0:
		return
	var rig: RtsCamera = _main.get_node("CameraRig") as RtsCamera
	rig.set_pose(sum / count, rig.yaw, rig.distance)


func _unpause() -> void:
	if _main != null and _main.paused:
		_main.paused = false


# Saves what the window shows, after two frames so the last tick is drawn.
func _save(mission_id: StringName, shot: String) -> void:
	await process_frame
	await process_frame
	var path: String = _dir.path_join("%d-%s-%s.png" % [_number, String(mission_id).replace("_", "-"), shot])
	_number += 1
	var error: Error = root.get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("capture_missions: could not write %s (error %d)" % [path, error])
		return
	print("  saved ", path)


func _outcome_text(world: World) -> String:
	match world.mission.outcome:
		MissionRuntime.Outcome.WON:
			return "mission won"
		MissionRuntime.Outcome.LOST:
			return "mission lost"
	return "still running"


func _number_of(variable: String, fallback: int) -> int:
	var text: String = OS.get_environment(variable)
	return int(text) if text.is_valid_int() else fallback


func _list(variable: String) -> PackedStringArray:
	var text: String = OS.get_environment(variable).strip_edges()
	if text.is_empty():
		return PackedStringArray()
	return text.split(",", false)
