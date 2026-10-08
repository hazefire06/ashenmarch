extends SceneTree
## The performance benchmark: `make bench` (windowed; it needs a GPU and a
## window). Phase 10's target is 100 units and 200 projectiles at 60 fps on the
## Mac, so this stages exactly that and measures it:
## - a skirmish on Riverside, AI against AI, 50 Light (Shieldmen, Reavers,
##   Longbows, Sappers) against 50 Dark (Husks, Rippers, Drifters,
##   Stormcallers, Blightbags), launched through MainView as the game launches
##   one;
## - every unit's health topped up between ticks, so the hundred keep fighting
##   for the whole run instead of thinning out;
## - arrows dropped over the fight between ticks to keep PROJECTILES in the air
##   on top of what the armies throw.
## This is a load harness, not a game: the top-ups and extra arrows change the
## world from outside the command stream, which is fine here and nowhere else.
##
## After WARMUP seconds it records every frame for DURATION seconds, with vsync
## off and no frame cap, and prints one line: frame time p50/p95/p99/max,
## average fps, the tick (World.step() plus the views reading it) mean and
## max (the harness steps MainView itself to time it) and World.step() alone,
## draw calls, nodes, and the units and projectiles alive on average.
##
## Settings are environment variables:
##   DURATION=60        seconds measured
##   WARMUP=5           seconds before measuring
##   WINDOW=1920x1080   window size in pixels (ignored with FULLSCREEN=1)
##   FULLSCREEN=0       1 for fullscreen at the screen's native resolution
##   PROJECTILES=200    projectiles kept in the air
##   OUT=<file>         also append the result line to this file
## e.g. FULLSCREEN=1 DURATION=30 make bench

const MAIN_SCENE: String = "res://view/main.tscn"
const CATALOG_PATH: String = "res://data/units/catalog.tres"

var _main: MainView
var _scenario: BenchScenario
var _measuring: bool = false
var _frame_ms: PackedFloat64Array = PackedFloat64Array()
var _physics_ms: PackedFloat64Array = PackedFloat64Array()
var _step_ms: PackedFloat64Array = PackedFloat64Array()
var _draw_calls: PackedFloat64Array = PackedFloat64Array()
var _alive: PackedFloat64Array = PackedFloat64Array()
var _in_air: PackedFloat64Array = PackedFloat64Array()
## Frames over HITCH_MS: when, and what the last tick did.
var _hitches: PackedStringArray = PackedStringArray()
var _last_tick_note: String = ""
var _ticks_this_frame: int = 0
var _tick_ms_this_frame: float = 0.0
const HITCH_MS: float = 33.0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("bench: needs a window; run it without --headless.")
		quit(1)
		return
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if _env("FULLSCREEN", "0") == "1":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		var size: PackedStringArray = _env("WINDOW", "1920x1080").split("x")
		DisplayServer.window_set_size(Vector2i(size[0].to_int(), size[1].to_int()))
	DisplayServer.window_move_to_foreground()
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	_scenario = BenchScenario.new(load(CATALOG_PATH) as UnitCatalog, int(_env("PROJECTILES", "200")))
	_main = (load(MAIN_SCENE) as PackedScene).instantiate() as MainView
	var launch: MissionLaunch = MissionLaunch.for_skirmish(BenchScenario.setup())
	# Not the campaign: losing focus mustn't pause the run.
	launch.campaign_mode = false
	_main.launch = launch
	root.add_child(_main)
	# The harness steps MainView itself, to time each tick exactly.
	_main.set_physics_process(false)
	physics_frame.connect(_between_ticks)
	await _wait(float(_env("WARMUP", "5")))
	_measuring = true
	var last_us: int = Time.get_ticks_usec()
	var end_us: int = last_us + int(float(_env("DURATION", "60")) * 1_000_000)
	while Time.get_ticks_usec() < end_us:
		await process_frame
		var now_us: int = Time.get_ticks_usec()
		var frame: float = (now_us - last_us) / 1000.0
		_frame_ms.append(frame)
		if frame > HITCH_MS and _hitches.size() < 12:
			var vp: RID = root.get_viewport_rid()
			_hitches.append("%.0f ms at tick %d: %d ticks taking %.1f ms; process %.1f ms, render cpu %.1f gpu %.1f ms (last: %s)" % [
				frame, _main.world.tick, _ticks_this_frame, _tick_ms_this_frame,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				RenderingServer.viewport_get_measured_render_time_cpu(vp),
				RenderingServer.viewport_get_measured_render_time_gpu(vp), _last_tick_note,
			])
		_ticks_this_frame = 0
		_tick_ms_this_frame = 0.0
		last_us = now_us
		_draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_measuring = false
	_report()
	quit()


# Each tick: the scenario's top-ups, then MainView's tick, timed.
func _between_ticks() -> void:
	var world: World = _main.world
	if world == null:
		return
	_scenario.between_ticks(world)
	var started_us: int = Time.get_ticks_usec()
	_main._physics_process(1.0 / World.TICK_RATE)
	_ticks_this_frame += 1
	_tick_ms_this_frame += (Time.get_ticks_usec() - started_us) / 1000.0
	var explodes: int = 0
	for event: ProjectileEvent in world.projectile_events:
		if event.kind == ProjectileEvent.Kind.EXPLODE:
			explodes += 1
	_last_tick_note = "tick %.1f ms, %d blasts, %d kills" % [
		(Time.get_ticks_usec() - started_us) / 1000.0, explodes,
		world.combat_events.filter(func(e: CombatEvent) -> bool: return e.kind == CombatEvent.Kind.KILL).size(),
	]
	if _measuring:
		_physics_ms.append((Time.get_ticks_usec() - started_us) / 1000.0)
		_step_ms.append(_main.last_step_ms)
		_alive.append(_scenario.alive)
		_in_air.append(_scenario.flying)


func _report() -> void:
	var frames: PackedFloat64Array = _frame_ms.duplicate()
	frames.sort()
	var seconds: float = 0.0
	for ms: float in _frame_ms:
		seconds += ms / 1000.0
	var line: String = (
		"bench %s: %d frames, frame ms p50 %.2f p95 %.2f p99 %.2f max %.2f, %.1f fps; "
		+ "tick ms (step + views) mean %.2f max %.2f, step alone mean %.2f max %.2f; "
		+ "draw calls %.0f; nodes %d; units %.0f; projectiles in air %.0f"
	) % [
		_window_text(), frames.size(), _pct(frames, 0.50), _pct(frames, 0.95), _pct(frames, 0.99),
		frames[frames.size() - 1] if not frames.is_empty() else 0.0,
		frames.size() / maxf(seconds, 0.001), _mean(_physics_ms), _max(_physics_ms), _mean(_step_ms),
		_max(_step_ms), _mean(_draw_calls),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), _mean(_alive), _mean(_in_air),
	]
	print(line)
	for hitch: String in _hitches:
		print("  hitch: " + hitch)
	var out: String = _env("OUT", "")
	if out != "":
		var file: FileAccess = FileAccess.open(out, FileAccess.READ_WRITE if FileAccess.file_exists(out) else FileAccess.WRITE)
		if file != null:
			file.seek_end()
			file.store_line(line)
			file.close()


func _window_text() -> String:
	var size: Vector2i = DisplayServer.window_get_size()
	var mode: String = "fullscreen" if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else "windowed"
	return "%dx%d %s" % [size.x, size.y, mode]


func _wait(seconds: float) -> void:
	var until: int = Time.get_ticks_usec() + int(seconds * 1_000_000)
	while Time.get_ticks_usec() < until:
		await process_frame


static func _pct(sorted: PackedFloat64Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(ceil(q * sorted.size())) - 1, 0, sorted.size() - 1)]


static func _mean(values: PackedFloat64Array) -> float:
	var total: float = 0.0
	for v: float in values:
		total += v
	return total / maxf(values.size(), 1)


static func _max(values: PackedFloat64Array) -> float:
	var top: float = 0.0
	for v: float in values:
		top = maxf(top, v)
	return top


static func _env(key: String, fallback: String) -> String:
	var value: String = OS.get_environment(key)
	return value if value != "" else fallback
