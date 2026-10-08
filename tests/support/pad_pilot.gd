class_name PadPilot
extends RefCounted
## Plays the game with a pad alone: every move it makes is a pad event sent
## as a real pad's is (PadEvents), into the real App. It looks at the screen
## and the World to decide, as a player looks, but never calls a game method
## to act. Used by the pad-only playthrough (tests/view/test_pad_playthrough.gd
## and `make pad-playthrough`).
##
## The menus: focus is walked to a button with the D-pad (the direction
## toward it, one step at a time), then A.
##
## A mission, a plain strategy: select everyone with the order wheel's
## Select all and keep them as group 1 (D-pad up held); then every
## REORDER_TICKS, recall group 1 (D-pad left then right), arm Attack-move from
## the order wheel, open the overhead map (View), steer the cursor with the
## left stick to the enemy nearest the army, and press X. It doesn't try to be
## clever: it proves a pad can play, not how well.
##
## Frames are stepped by hand: the pad, the camera, the selection, the
## sprites and MainView's _process every frame, the sim every other (30 ticks
## a second at 60 frames), so a run is as fast as the machine allows.

const FRAME: float = 1.0 / 60.0
## Pixels from its target the cursor must get to.
const STEER_CLOSE: float = 5.0
const MAX_STEER_FRAMES: int = 400
## Ticks between attack orders.
const REORDER_TICKS: int = 240
const MAX_FOCUS_STEPS: int = 30

var app: App
## What the pilot did, a line each, for a report.
var notes: PackedStringArray = PackedStringArray()
var frames: int = 0
## Attack orders given.
var attacks: int = 0


func _init(the_app: App) -> void:
	app = the_app


# ---- menus -------------------------------------------------------------------


## Walks focus to the button named `button_name` on the screen (or overlay)
## and presses A. False if focus can't reach it.
func press(button_name: String) -> bool:
	await _settle()
	var root: Node = app.current_overlay() if app.current_overlay() != null else app.current_screen()
	var target: Control = MenuFixtures.named(root, button_name) as Control
	if target == null:
		notes.append("no %s on %s" % [button_name, root.name])
		return false
	if not focus_to(target):
		notes.append("focus can't reach %s" % button_name)
		return false
	PadEvents.tap(JOY_BUTTON_A)
	notes.append("pressed %s" % button_name)
	await _settle()
	return true


## Moves focus to `target` with the D-pad. True once it is there.
func focus_to(target: Control) -> bool:
	var viewport: Viewport = target.get_viewport()
	for step: int in MAX_FOCUS_STEPS:
		var focus: Control = viewport.gui_get_focus_owner()
		if focus == target:
			return true
		if focus == null:
			return false
		var d: Vector2 = target.get_global_rect().get_center() - focus.get_global_rect().get_center()
		var button: JoyButton
		if absf(d.y) >= absf(d.x):
			button = JOY_BUTTON_DPAD_DOWN if d.y > 0.0 else JOY_BUTTON_DPAD_UP
		else:
			button = JOY_BUTTON_DPAD_RIGHT if d.x > 0.0 else JOY_BUTTON_DPAD_LEFT
		PadEvents.tap(button)
	return viewport.gui_get_focus_owner() == target


## From the main menu, a new campaign at `tier`, through the briefing, into
## the first mission. True if it got there.
func start_campaign(tier: int) -> bool:
	if not await press("CampaignButton"):
		return false
	if not await press("NewCampaignButton"):
		return false
	if tier != MenuKit.DEFAULT_TIER and not await press("Tier%d" % tier):
		return false
	if not await press("BeginButton"):
		return false
	if not await press("StartButton"):
		return false
	for wait: int in 10:
		if app.current_screen() is MainView:
			break
		await app.get_tree().process_frame
	var main: MainView = mission_view()
	if main == null:
		notes.append("no mission started")
		return false
	# From here on this pilot steps the scene itself.
	main.set_physics_process(false)
	return true


# ---- a mission ---------------------------------------------------------------


func mission_view() -> MainView:
	return app.current_screen() as MainView


## Plays the mission in view until it is decided or `max_ticks` have passed;
## `stop` (a Callable taking the World), if given and true, ends it early.
## The outcome (NONE if undecided).
func play(max_ticks: int, stop: Callable = Callable()) -> MissionRuntime.Outcome:
	var main: MainView = mission_view()
	step(30)
	_wheel(JOY_BUTTON_RIGHT_SHOULDER, PadController.ORDER_WHEEL.find("Select all"), PadController.ORDER_WHEEL.size())
	_hold(JOY_BUTTON_DPAD_UP, PadController.GROUP_HOLD)
	notes.append("selected %d and saved them as group 1" % main._selection.selection.size())
	var next_order: int = 0
	while main.world.mission.outcome == MissionRuntime.Outcome.NONE and main.world.tick < max_ticks:
		if stop.is_valid() and stop.call(main.world):
			break
		if main.world.tick >= next_order:
			_attack_nearest_enemy()
			next_order = main.world.tick + REORDER_TICKS
		step(1)
	return main.world.mission.outcome


## Steps `count` frames by hand (the sim every other one).
func step(count: int) -> void:
	var main: MainView = mission_view()
	if main == null:
		return
	for i: int in count:
		main.pad()._process(FRAME)
		main._camera._process(FRAME)
		main._selection._process(FRAME)
		main._units_view._process(FRAME)
		main._process(FRAME)
		frames += 1
		if frames % 2 == 0 and not main.is_frozen():
			main._physics_process(1.0 / World.TICK_RATE)


## Once the mission is decided: steps until the App shows its results.
func to_results() -> Node:
	for i: int in 600:
		if not app.current_screen() is MainView:
			break
		step(1)
	for wait: int in 10:
		await app.get_tree().process_frame
		if not app.current_screen() is MainView:
			break
	return app.current_screen()


func _attack_nearest_enemy() -> void:
	var main: MainView = mission_view()
	# Group 1 back: away to slot 0 and onto it again recalls it.
	PadEvents.tap(JOY_BUTTON_DPAD_LEFT)
	PadEvents.tap(JOY_BUTTON_DPAD_RIGHT)
	var army: PackedInt32Array = main._selection.selection.ids()
	if army.is_empty():
		return
	var target: Unit = _nearest_enemy(main.world, army)
	if target == null:
		return
	_wheel(JOY_BUTTON_RIGHT_SHOULDER, PadController.ORDER_WHEEL.find("Attack-move"), PadController.ORDER_WHEEL.size())
	PadEvents.tap(JOY_BUTTON_BACK)
	var map_point: Vector2 = main._overhead_map._world_to_screen(Vector2(target.x, target.z) / float(World.UNITS_PER_METER))
	var reached: bool = _steer_to(map_point)
	PadEvents.tap(JOY_BUTTON_X)
	PadEvents.tap(JOY_BUTTON_BACK)
	attacks += 1
	if OS.get_environment("PAD_PILOT_TRACE") != "":
		var lead: Unit = main.world.get_unit(army[0])
		print("t%d target %s (%d, %d) cursor %s want %s reached %s; lead order %s to (%d, %d) at (%d, %d)" % [
			main.world.tick, target.type.id, target.x / 1000, target.z / 1000, main.pad().cursor.at, map_point,
			reached, Unit.Order.keys()[lead.order], lead.order_x / 1000, lead.order_z / 1000, lead.x / 1000, lead.z / 1000,
		])


# The living enemy nearest the army's middle that the player can see (else
# any living one).
func _nearest_enemy(world: World, army: PackedInt32Array) -> Unit:
	var center: Vector2 = Vector2.ZERO
	for unit_id: int in army:
		var unit: Unit = world.get_unit(unit_id)
		center += Vector2(unit.x, unit.z)
	center /= army.size()
	var best: Unit = null
	var best_seen: bool = false
	var best_d: float = INF
	for unit: Unit in world.units:
		if not unit.is_alive() or unit.faction == UnitType.Faction.LIGHT:
			continue
		var seen: bool = Visibility.seen_by(world, unit, UnitType.Faction.LIGHT)
		var d: float = center.distance_to(Vector2(unit.x, unit.z))
		if best == null or (seen and not best_seen) or (seen == best_seen and d < best_d):
			best = unit
			best_seen = seen
			best_d = d
	return best


# Steers the pad's cursor to a screen point with the left stick.
func _steer_to(target: Vector2) -> bool:
	var pad: PadController = mission_view().pad()
	for i: int in MAX_STEER_FRAMES:
		var d: Vector2 = target - pad.cursor.at
		if d.length() <= STEER_CLOSE:
			break
		PadEvents.left_stick(d.normalized() * clampf(d.length() / 150.0, 0.5, 1.0))
		step(1)
	PadEvents.left_stick(Vector2.ZERO)
	step(1)
	return pad.cursor.at.distance_to(target) <= STEER_CLOSE * 2.0


# Holds a shoulder button, points the left stick at choice `index` of
# `count`, and lets go.
func _wheel(shoulder: JoyButton, index: int, count: int) -> void:
	PadEvents.press(shoulder)
	var angle: float = index * TAU / count
	PadEvents.left_stick(Vector2(sin(angle), -cos(angle)))
	step(1)
	PadEvents.release(shoulder)
	PadEvents.left_stick(Vector2.ZERO)
	step(1)


func _hold(button: JoyButton, seconds: float) -> void:
	PadEvents.press(button)
	step(ceili(seconds / FRAME) + 2)
	PadEvents.release(button)


func _settle() -> void:
	for i: int in 2:
		await app.get_tree().process_frame
