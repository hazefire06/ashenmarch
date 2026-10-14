extends SceneTree
## `make pad-playthrough`: Riverside played to the end with a pad alone
## (PadPilot), from the main menu to the results, every input a synthetic pad
## event. TIER picks the difficulty (default 2, Normal); SEED the App's
## campaign seed. Prints what the pilot did and how it ended; exits 0 on a
## victory that reaches the results screen, 1 otherwise.

const DIR: String = "user://pad_playthrough"
const MAX_TICKS: int = 20 * 60 * World.TICK_RATE


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# A window the cursor can point in: the headless one is 64 pixels square.
	await process_frame
	root.size = Vector2i(1280, 720)
	await process_frame
	var tier: int = int(OS.get_environment("TIER")) if OS.get_environment("TIER") != "" else 2
	var seed_value: int = int(OS.get_environment("SEED")) if OS.get_environment("SEED") != "" else 20261008
	_clean()
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = CampaignStore.new(DIR + "/campaign.json")
	app.settings_path = DIR + "/settings.cfg"
	app.replays_dir = DIR
	app.rng.seed = seed_value
	root.add_child(app)
	await process_frame
	InputDeviceTracker.tracker().use(InputBindings.Device.PAD)
	var pilot: PadPilot = PadPilot.new(app)
	var started_ms: int = Time.get_ticks_msec()
	if not await pilot.start_campaign(tier):
		print("pad playthrough: couldn't start: %s" % [pilot.notes])
		quit(1)
		return
	var main: MainView = pilot.mission_view()
	var outcome: MissionRuntime.Outcome = pilot.play(MAX_TICKS)
	var ticks: int = main.world.tick
	var screen: Node = await pilot.to_results()
	var won: bool = outcome == MissionRuntime.Outcome.WON
	var results: bool = screen is Results
	print("pad playthrough: Riverside tier %d seed %d: %s at tick %d (%d:%02d), %d attack orders, %d s real; results screen: %s" % [
		tier, seed_value, MissionRuntime.Outcome.keys()[outcome], ticks, ticks / World.TICK_RATE / 60,
		ticks / World.TICK_RATE % 60, pilot.attacks, (Time.get_ticks_msec() - started_ms) / 1000, results,
	])
	print("pad playthrough: %s" % " / ".join(pilot.notes))
	if not won:
		print("pad playthrough: left standing: %s" % _standing(main.world))
	PadEvents.release_all()
	app.queue_free()
	await process_frame
	_clean()
	quit(0 if won and results else 1)


# Who is still alive at the end, for a run that didn't win: each side's count,
# and where the Dark ones are (submerged ones marked).
func _standing(world: World) -> String:
	var light: int = 0
	var dark: PackedStringArray = PackedStringArray()
	for unit: Unit in world.units:
		if not unit.is_alive():
			continue
		if unit.faction == UnitType.Faction.LIGHT:
			light += 1
		else:
			dark.append("%s at (%d, %d)%s" % [
				unit.type.id, unit.x / 1000, unit.z / 1000,
				" submerged" if Visibility.is_submerged(world.terrain, unit) else "",
			])
	return "%d Light; %d Dark: %s" % [light, dark.size(), ", ".join(dark)]


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)
