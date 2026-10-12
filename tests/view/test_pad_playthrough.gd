extends GutTest
## Riverside played with a pad alone (PadPilot), start to finish: from the
## main menu through a new campaign at Normal and the briefing by focus, into
## the mission, everyone selected from the order wheel and saved as a group
## with the D-pad, then attack-moves sent from the overhead map with the
## cursor steered by the stick, to Victory and the results screen. Every
## input is a synthetic pad event. About four minutes of game time, a quarter
## of a minute here. `make pad-playthrough TIER= SEED=` plays others.

const DIR: String = "user://test_pad_playthrough"
const TIER: int = 2
## The pilot wins in about four minutes; this is a generous cut.
const MAX_TICKS: int = 12 * 60 * World.TICK_RATE

var _physics_rate: int = 0
var _window_size: Vector2i


func before_all() -> void:
	_physics_rate = Engine.physics_ticks_per_second
	_window_size = get_window().size
	get_window().size = Vector2i(1280, 720)


func after_all() -> void:
	get_window().size = _window_size
	Engine.physics_ticks_per_second = _physics_rate
	_clean()


func after_each() -> void:
	PadEvents.release_all()
	await get_tree().process_frame


func test_riverside_is_won_with_a_pad_alone() -> void:
	_clean()
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = CampaignStore.new(DIR + "/campaign.json")
	app.settings_path = DIR + "/settings.cfg"
	app.replays_dir = DIR
	app.rng.seed = 20261008
	add_child_autofree(app)
	await get_tree().process_frame
	InputDeviceTracker.tracker().use(InputBindings.Device.PAD)
	var pilot: PadPilot = PadPilot.new(app)
	assert_true(await pilot.start_campaign(TIER), "into Riverside by the menus: %s" % [pilot.notes])
	var main: MainView = pilot.mission_view()
	if main == null:
		return
	assert_eq(main.launch.mission.id, &"riverside")
	var outcome: MissionRuntime.Outcome = pilot.play(MAX_TICKS)
	var ticks: int = main.world.tick
	var kinds: Array[int] = []
	for record: Array in main.recording.commands:
		kinds.append(record[0])
	gut.p("pad pilot: %s; %d attack orders; %s at tick %d" % [
		pilot.notes, pilot.attacks, MissionRuntime.Outcome.keys()[outcome], ticks,
	])
	assert_eq(outcome, MissionRuntime.Outcome.WON, "Riverside is cleared")
	assert_has(kinds, CommandCodec.Kind.ATTACK_MOVE, "by the pad's attack-moves")
	var screen: Node = await pilot.to_results()
	assert_true(screen is Results, "and the results come up")


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)
