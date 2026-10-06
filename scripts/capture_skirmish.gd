extends SceneTree
## Visual check of skirmish: `CAPTURE=<dir> make capture-skirmish` (windowed).
##
## First the setup screen (SkirmishMenu) on its defaults, then for each map and
## mode asked for, a skirmish launched the way the App launches one
## (SkirmishSetup, MissionLaunch.for_skirmish), with these screenshots of the
## real game window into <dir>:
## - the opening view, 2 s of real time after it starts;
## - the F7 scoreboard over it;
## - the overhead map (Tab), with the flags;
## - a mid-battle frame after SECONDS of game time, stepped as fast as the
##   machine goes: as Light the competent playtest pilot plays the player's
##   army along the mode's route (SkirmishRunner's), as Dark the player's
##   army holds and the AI's Light comes to it;
## - the end, with its banner: played on until the skirmish is decided.
## Files are named <n>-<map>-<mode>-<shot>.png, n counting up from FIRST.
## Nothing is written but those PNGs. It needs a window.
##
## Settings are environment variables:
##   CAPTURE  the output directory (required; created if it is missing)
##   MAPS     comma list of map ids, default every map of the skirmish catalog
##   MODES    comma list of body_count, king_of_the_hill, capture_the_flags,
##            default all three
##   SIDE     light or dark, the player's side, default light
##   SEED     the world seed, default 1000
##   SECONDS  game seconds before the mid-battle frame, default 60
##   FIRST    number of the first file, default 60
## e.g. CAPTURE=/tmp/shots MAPS=old_mill MODES=king_of_the_hill SIDE=dark make capture-skirmish

const SKIRMISH_PATH: String = "res://data/skirmish/skirmish.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
const MAIN_SCENE: String = "res://view/main.tscn"
const MODE_NAMES: Array[String] = ["body_count", "king_of_the_hill", "capture_the_flags"]
const OPENING_SECONDS: float = 2.0
const SETTLE_SECONDS: float = 1.5
const TICKS_PER_FRAME: int = 30
## Game minutes on the clock; the end is played to whatever decides it.
const MINUTES: int = 10
const M: float = 1000.0

var _dir: String = OS.get_environment("CAPTURE")
var _number: int = 0
var _main: MainView
var _pilot: PlaytestPilot
var _last_think: int = -1
var _skirmish: SkirmishCatalog
var _catalog: UnitCatalog


func _initialize() -> void:
	if _dir.is_empty():
		push_error("capture_skirmish: set CAPTURE=<dir> to say where the screenshots go.")
		quit(1)
		return
	if DisplayServer.get_name() == "headless":
		push_error("capture_skirmish: needs a window; run it without --headless.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	# A window behind others may not be redrawn: bring it to the front.
	DisplayServer.window_move_to_foreground()
	_number = _number_of("FIRST", 60)
	_skirmish = load(SKIRMISH_PATH) as SkirmishCatalog
	_catalog = load(CATALOG_PATH) as UnitCatalog
	_run.call_deferred()


func _run() -> void:
	await _capture_menu()
	var maps: PackedStringArray = _list("MAPS")
	var modes: PackedStringArray = _list("MODES")
	for m: SkirmishMap in _skirmish.maps:
		if not maps.is_empty() and not maps.has(String(m.id)):
			continue
		for mode: int in MODE_NAMES.size():
			if not modes.is_empty() and not modes.has(MODE_NAMES[mode]):
				continue
			await _capture(m, mode as SkirmishRules.Mode)
	quit()


func _capture_menu() -> void:
	var menu: SkirmishMenu = SkirmishMenu.new()
	root.add_child(menu)
	menu.setup(_skirmish, _catalog)
	await _settle(0.5)
	await _save("setup", "menu")
	root.remove_child(menu)
	menu.queue_free()


func _capture(m: SkirmishMap, mode: SkirmishRules.Mode) -> void:
	var side: UnitType.Faction = (
		UnitType.Faction.DARK if OS.get_environment("SIDE") == "dark" else UnitType.Faction.LIGHT
	)
	var other: UnitType.Faction = (1 - side) as UnitType.Faction
	var names: Array[String] = ["light", "dark"]
	var setup: SkirmishSetup = SkirmishSetup.new()
	setup.map = m
	setup.rules = SkirmishRules.for_map(m, mode, MINUTES, side)
	setup.budget = _skirmish.default_budget
	setup.armies = [
		_skirmish.template(StringName("%s_balanced" % names[side])).fill(setup.budget, _catalog),
		_skirmish.template(StringName("%s_balanced" % names[other])).fill(setup.budget, _catalog),
	]
	setup.ai_template_id = StringName("%s_balanced" % names[other])
	setup.world_seed = _number_of("SEED", 1000)
	var tag: String = "%s-%s" % [String(m.id).replace("_", "-"), MODE_NAMES[mode].replace("_", "-")]
	_main = (load(MAIN_SCENE) as PackedScene).instantiate() as MainView
	_main.launch = MissionLaunch.for_skirmish(setup)
	root.add_child(_main)
	print("%s as %s, seed %d" % [tag, names[side], setup.world_seed])

	await _run_for(OPENING_SECONDS)
	await _save(tag, "opening")
	var hud: SkirmishHud = _main.get_node("Hud/SkirmishHud") as SkirmishHud
	hud.toggle_scoreboard()
	await _save(tag, "scoreboard")
	hud.toggle_scoreboard()
	var overhead: OverheadMap = _main.get_node("Hud/OverheadMap") as OverheadMap
	overhead.toggle()
	await _save(tag, "overhead")
	overhead.toggle()

	_pilot = null
	if side == UnitType.Faction.LIGHT:
		_pilot = PlaytestPilot.new(PlaytestPilot.Kind.COMPETENT)
		_pilot.set_route(SkirmishRunner.route_for(setup, _main.world), SkirmishRunner.holds_at_end(mode))
	_last_think = -1
	await _fast_forward(_number_of("SECONDS", 60) * World.TICK_RATE)
	_look_at_the_player(side)
	await _run_for(SETTLE_SECONDS)
	await _save(tag, "battle")
	await _fast_forward(setup.rules.time_limit_ticks + World.TICK_RATE)
	_look_at_the_player(side)
	await _run_for(SETTLE_SECONDS)
	await _save(tag, "end")
	var rt: SkirmishRuntime = _main.world.skirmish
	print("  ended at %.1f min: winner %d, reason %d, alive %s" % [
		float(rt.end_tick - rt.start_tick) / (60.0 * World.TICK_RATE), rt.winner, rt.end_reason, rt.alive,
	])
	root.remove_child(_main)
	_main.queue_free()
	_main = null
	await process_frame


func _run_for(seconds: float) -> void:
	var started_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_ms < roundi(seconds * 1000.0):
		await process_frame
		_unpause()


func _settle(seconds: float) -> void:
	var started_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_ms < roundi(seconds * 1000.0):
		await process_frame


# Steps the sim to this tick, TICKS_PER_FRAME at a time, with the pilot (if
# any) thinking once a second, as capture_missions does.
func _fast_forward(until: int) -> void:
	_main.set_physics_process(false)
	while _main.world.tick < until and not _main.is_frozen():
		_unpause()
		for _step: int in TICKS_PER_FRAME:
			if _main.world.tick >= until or _main.is_frozen():
				break
			var tick: int = _main.world.tick
			if _pilot != null and tick != _last_think and (tick == 1 or tick % PlaytestPilot.THINK_TICKS == 0):
				_last_think = tick
				_pilot.think(_main.world)
			_main._physics_process(0.0)
		await process_frame
	_main.set_physics_process(true)


# The camera over the middle of the player's living units (or, with none left,
# the enemy's), keeping its angle and distance.
func _look_at_the_player(side: UnitType.Faction) -> void:
	for wanted: int in [side, 1 - side]:
		var sum: Vector2 = Vector2.ZERO
		var count: int = 0
		for unit: Unit in _main.world.units:
			if unit.is_alive() and unit.faction == wanted:
				sum += Vector2(unit.x, unit.z) / M
				count += 1
		if count > 0:
			var rig: RtsCamera = _main.get_node("CameraRig") as RtsCamera
			rig.set_pose(sum / count, rig.yaw, rig.distance)
			return


func _unpause() -> void:
	if _main != null and _main.paused:
		_main.paused = false


# Saves what the window shows once two new frames have really been drawn: a
# window macOS hasn't brought up yet runs its loop without drawing, and its
# texture would be an old frame (2 s at most, then it saves what there is).
func _save(tag: String, shot: String) -> void:
	var drawn: int = Engine.get_frames_drawn()
	var started_ms: int = Time.get_ticks_msec()
	while Engine.get_frames_drawn() < drawn + 2 and Time.get_ticks_msec() - started_ms < 2000:
		await process_frame
		_unpause()
	var path: String = _dir.path_join("%d-%s-%s.png" % [_number, tag, shot])
	_number += 1
	var error: Error = root.get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("capture_skirmish: could not write %s (error %d)" % [path, error])
		return
	print("  saved ", path)


func _number_of(variable: String, fallback: int) -> int:
	var text: String = OS.get_environment(variable)
	return int(text) if text.is_valid_int() else fallback


func _list(variable: String) -> PackedStringArray:
	var text: String = OS.get_environment(variable).strip_edges()
	if text.is_empty():
		return PackedStringArray()
	return text.split(",", false)
