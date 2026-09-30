extends SceneTree
## Combat showcase: `make demo` (or DEMO_SPEED=2 make demo to run it faster).
##
## Runs the real game and stages the Phase 3 melee rules one event after
## another, each on its own patch of Riverside, with a caption and a live
## tally of where blows land:
## 1. Shield wall: a Shieldman line against as many Husks.
## 2. Surrounded: half as many Shieldmen, ringed by Husks.
## 3. Hammer and anvil: Reavers hit Husks locked onto a Shieldman line from
##    behind, which gibs them and earns the Reavers veterancy.
## 4. Ripper raid: Rippers run past Shieldmen to reach archers.
## 5. Finale: the standing test squads clash at the ford.
## When it ends the game is yours.
##
## DEMO_CAPTURE=<dir> saves a screenshot at each result and quits at the end,
## for checking the showcase without watching it.
##
## Units spawn and move through sim commands, exactly like player input. Bodies
## from each event stay where they fell.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const EVENTS: int = 5
## Seconds to read a caption before the fighting starts, and a result after.
const READ_BEFORE: float = 4.0
const READ_AFTER: float = 5.0
## An event that hasn't ended by then moves on anyway.
const FIGHT_TIMEOUT: float = 75.0
const FINALE_TIMEOUT: float = 90.0
## Yaw 0 looks north. The defenders stand north of their attackers, so a half
## turn puts the camera behind the defenders, looking at what's coming.
const BEHIND_LIGHT: float = PI
## Hammer and anvil: the Reavers charge once this many Husks are locked in
## combat, from this far (meters) behind the rearmost Husk.
const ANVIL_ENGAGED: int = 8
const HAMMER_BACK: float = 7.0
const LONGBOW_ID: StringName = &"longbow"

var _main: MainView
var _world: World
var _camera: RtsCamera
var _selection: SelectionController
var _caption: Label
var _tally: Label
## Units the tally watches this event.
var _watched: Dictionary[int, bool] = {}
## Blows landed on each side by aspect: index side * 3 + MeleeCombat.Aspect.
var _landed: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0])
var _blocked: PackedInt32Array = PackedInt32Array([0, 0])
var _gibbed: int = 0
## Ripper swings by the type of unit swung at, for the raid.
var _ripper_swings: Dictionary[StringName, int] = {}
var _last_tick: int = -1
## Where to save a screenshot at each result; empty for none.
var _capture_dir: String = OS.get_environment("DEMO_CAPTURE")
var _event: int = 0


func _initialize() -> void:
	var speed: String = OS.get_environment("DEMO_SPEED")
	Engine.time_scale = float(speed) if speed.is_valid_float() and float(speed) > 0.0 else 1.0
	# Lets the sim keep up at DEMO_SPEED > 1 instead of slowing down.
	Engine.max_physics_steps_per_frame = 16
	_main = load("res://view/main.tscn").instantiate() as MainView
	root.add_child(_main)
	_run.call_deferred()


func _physics_process(_delta: float) -> bool:
	if _world == null or _world.tick == _last_tick:
		return false
	# Each tick's events stay in the World until the next step, so reading
	# them once per new tick sees every event exactly once.
	_last_tick = _world.tick
	for event: CombatEvent in _world.combat_events:
		_count(event)
	_refresh_tally()
	return false


func _run() -> void:
	await process_frame
	_world = _main.world
	_camera = _main.get_node("CameraRig") as RtsCamera
	_selection = _main.get_node("Hud/Selection") as SelectionController
	_build_labels()
	await _shield_wall()
	await _surrounded()
	await _hammer_and_anvil()
	await _ripper_raid()
	await _finale()
	Engine.time_scale = 1.0
	if not _capture_dir.is_empty():
		quit()
		return
	_caption.text = "Demo over. You have control: select units, right-click or use the bar to move. F9 switches sides. Hover any unit or body for its tooltip."
	_tally.text = ""


func _shield_wall() -> void:
	var c: Vector2 = Vector2(390.0, 120.0)
	_begin(1, "Shield wall", "10 Shieldmen hold a line. 10 Husks attack it head on. Blue-grey flashes are shield blocks: they only work against blows from the front.", c, BEHIND_LIGHT, 22.0)
	var light: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c + Vector2(0.0, -4.0), 10, 1.4), Vector2i(0, 1))
	var dark: PackedInt32Array = await _spawn(&"husk", DARK, _row(c + Vector2(0.0, 8.0), 10, 1.4), Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(dark, c + Vector2(0.0, -10.0), Formations.Kind.SHORT_LINE)
	var seconds: float = await _fight(light, dark, FIGHT_TIMEOUT)
	_result("%d/10 Shieldmen standing, %d/10 Husks down in %.0f s. %d%% of the blows on the Shieldmen came from the front." % [
		_alive(light), 10 - _alive(dark), seconds, _front_share(LIGHT)
	])
	await _wait(READ_AFTER)


func _surrounded() -> void:
	var c: Vector2 = Vector2(380.0, 440.0)
	_begin(2, "Surrounded", "5 Shieldmen, 10 Husks closing from every side. A unit fights one enemy at a time and doesn't turn: the rest hit its flank (x1.2) and rear (x1.4), where shields don't help.", c, 0.6, 18.0)
	var spots: Array[Vector2] = [c, c + Vector2(1.4, 0.0), c + Vector2(-1.4, 0.0), c + Vector2(0.0, 1.4), c + Vector2(0.0, -1.4)]
	var light: PackedInt32Array = await _spawn(&"shieldman", LIGHT, spots, Vector2i(0, 1))
	var ring: Array[Vector2] = []
	for i: int in 10:
		var angle: float = TAU * i / 10.0
		ring.append(c + Vector2(cos(angle), sin(angle)) * 9.0)
	var dark: PackedInt32Array = await _spawn(&"husk", DARK, ring, Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(dark, c, Formations.Kind.CIRCLE)
	var seconds: float = await _fight(light, dark, FIGHT_TIMEOUT)
	_result("%d/5 Shieldmen standing, %d/10 Husks left after %.0f s. Only %d%% of the blows on the Shieldmen came from the front." % [
		_alive(light), _alive(dark), seconds, _front_share(LIGHT)
	])
	await _wait(READ_AFTER)


func _hammer_and_anvil() -> void:
	var c: Vector2 = Vector2(110.0, 160.0)
	_begin(3, "Hammer and anvil", "6 Shieldmen hold (the anvil). 14 Husks lock onto them...", c, BEHIND_LIGHT, 28.0)
	var light: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c + Vector2(0.0, -4.0), 6, 1.4), Vector2i(0, 1))
	var front: Array[Vector2] = _row(c + Vector2(0.0, 6.0), 7, 1.4)
	front.append_array(_row(c + Vector2(0.0, 7.4), 7, 1.4))
	var dark: PackedInt32Array = await _spawn(&"husk", DARK, front, Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(dark, c + Vector2(0.0, -10.0), Formations.Kind.SHORT_LINE)
	var rear_z: float = await _until_engaged(dark, ANVIL_ENGAGED, 10.0)
	_caption.text = "3/%d  Hammer and anvil\n...then 5 Reavers charge in from behind. The Husks can't turn away from the Shieldmen: rear blows hit x1.4, and a big enough overkill bursts the body into gibs." % EVENTS
	var reavers: PackedInt32Array = await _spawn(&"reaver", LIGHT, _row(Vector2(c.x, rear_z + HAMMER_BACK), 5, 2.0), Vector2i(0, -1))
	_attack_move(reavers, c + Vector2(0.0, -2.0), Formations.Kind.SHORT_LINE)
	light.append_array(reavers)
	var seconds: float = await _fight(light, dark, FIGHT_TIMEOUT)
	var ace: Unit = _top_killer(reavers)
	_result("%d/14 Husks down in %.0f s, %d gibbed, %d%% of the blows on them from the rear." % [
		14 - _alive(dark), seconds, _gibbed, _share(DARK, MeleeCombat.Aspect.REAR)
	])
	if ace != null and ace.kills > 0:
		_selection.selection.select(PackedInt32Array([ace.id]))
		_caption.text += "\nVeterancy: the top Reaver (selected) has %d kills: accuracy +%d, attack rate +%d%%, speed +%d%%. Hover it for its tooltip." % [
			ace.kills, Veterancy.accuracy_bonus(ace) / 10,
			Veterancy.attack_rate_bonus(ace) / 10, Veterancy.speed_bonus(ace) / 10,
		]
	await _wait(READ_AFTER + 3.0)
	_selection.selection.clear()


func _ripper_raid() -> void:
	var c: Vector2 = Vector2(340.0, 320.0)
	_begin(4, "Ripper raid", "3 Longbows (green) behind a screen of 6 Shieldmen. 6 Rippers attack. Rippers go for ranged and support units first, and run past the Shieldmen to reach them, while the Longbows shoot as they come.", c, BEHIND_LIGHT, 24.0)
	var archers: PackedInt32Array = await _spawn(LONGBOW_ID, LIGHT, _row(c + Vector2(0.0, -6.0), 3, 2.0), Vector2i(0, 1))
	var screen: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c, 6, 1.6), Vector2i(0, 1))
	var dark: PackedInt32Array = await _spawn(&"ripper", DARK, _row(c + Vector2(0.0, 18.0), 6, 1.6), Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(dark, c + Vector2(0.0, -12.0), Formations.Kind.RABBLE)
	var light: PackedInt32Array = archers.duplicate()
	light.append_array(screen)
	var seconds: float = await _fight(light, dark, FIGHT_TIMEOUT)
	_result("After %.0f s: %d/3 Longbows and %d/6 Shieldmen standing, %d/6 Rippers left. Ripper swings: %d at Longbows, %d at Shieldmen." % [
		seconds, _alive(archers), _alive(screen), _alive(dark),
		_ripper_swings.get(LONGBOW_ID, 0), _ripper_swings.get(&"shieldman", 0),
	])
	await _wait(READ_AFTER)


func _finale() -> void:
	var c: Vector2 = Vector2(280.0, 232.0)
	_begin(5, "Finale", "The test squads clash at the ford: Shieldmen and Reavers against Husks and Rippers. Living units wade the shallow ford; undead Husks cross the deep water anywhere.", c, 0.0, 70.0)
	var light: PackedInt32Array = PackedInt32Array()
	var dark: PackedInt32Array = PackedInt32Array()
	# The test squads are the first units MainView spawned.
	for unit: Unit in _world.units.slice(0, MainView.TEST_SQUAD_SIZE * 2 + MainView.TEST_SHOCK_ROW_SIZE * 2):
		if not unit.is_alive():
			continue
		if unit.faction == LIGHT:
			light.append(unit.id)
		else:
			dark.append(unit.id)
		_watched[unit.id] = true
	await _wait(READ_BEFORE)
	_attack_move(light, Vector2(255.0, 280.0), Formations.Kind.SHORT_LINE)
	_attack_move(dark, Vector2(295.0, 190.0), Formations.Kind.RABBLE)
	var seconds: float = await _fight(light, dark, FINALE_TIMEOUT)
	_result("After %.0f s: Light %d/%d standing, Dark %d/%d. %d gibbed." % [
		seconds, _alive(light), light.size(), _alive(dark), dark.size(), _gibbed
	])
	await _wait(READ_AFTER)


# --- staging ---


# Starts event n: resets the tally, sets the caption, and frames the camera.
func _begin(n: int, title: String, text: String, focus: Vector2, yaw: float, distance: float) -> void:
	_event = n
	_watched.clear()
	_landed = PackedInt32Array([0, 0, 0, 0, 0, 0])
	_blocked = PackedInt32Array([0, 0])
	_gibbed = 0
	_ripper_swings.clear()
	_caption.text = "%d/%d  %s\n%s" % [n, EVENTS, title, text]
	_camera.set_pose(focus, yaw, distance)


# Enqueues one spawn per spot (meters) and waits until they exist. Returns
# their ids and adds them to the tally.
func _spawn(type_id: StringName, side: UnitType.Faction, spots: Array[Vector2], face: Vector2i) -> PackedInt32Array:
	var before: int = _world.units.size()
	for p: Vector2 in spots:
		_world.enqueue(SpawnUnitCommand.new(
			_world.tick, type_id, side, roundi(p.x * M), roundi(p.y * M), face.x, face.y
		))
	while _world.units.size() < before + spots.size():
		await physics_frame
	var ids: PackedInt32Array = PackedInt32Array()
	for i: int in range(before, before + spots.size()):
		ids.append(_world.units[i].id)
		_watched[_world.units[i].id] = true
	return ids


func _attack_move(ids: PackedInt32Array, to: Vector2, formation: Formations.Kind) -> void:
	_world.enqueue(AttackMoveCommand.new(_world.tick, ids, roundi(to.x * M), roundi(to.y * M), formation))


# Waits until at least count of ids are fighting in reach (or timeout sim
# seconds pass). Returns the z (meters) of the rearmost of them still alive.
func _until_engaged(ids: PackedInt32Array, count: int, timeout: float) -> float:
	var start: int = _world.tick
	while _world.tick - start < roundi(timeout * World.TICK_RATE):
		var engaged: int = 0
		for unit_id: int in ids:
			if _world.get_unit(unit_id).state == Unit.State.ATTACKING:
				engaged += 1
		if engaged >= count:
			break
		await physics_frame
	var rear: float = -INF
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit.is_alive():
			rear = maxf(rear, unit.z / float(M))
	return rear


# Waits until one side is wiped out or timeout seconds pass; returns seconds.
func _fight(light: PackedInt32Array, dark: PackedInt32Array, timeout: float) -> float:
	var start: int = _world.tick
	while _world.tick - start < roundi(timeout * World.TICK_RATE):
		await physics_frame
		if _alive(light) == 0 or _alive(dark) == 0:
			break
	return float(_world.tick - start) / World.TICK_RATE


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _result(text: String) -> void:
	_caption.text += "\nResult: " + text
	print("event %d result: %s" % [_event, text])
	if not _capture_dir.is_empty():
		await process_frame
		await process_frame
		root.get_viewport().get_texture().get_image().save_png(
			_capture_dir.path_join("demo_event_%d.png" % _event)
		)


# count spots centered on center along x, spacing meters apart.
static func _row(center: Vector2, count: int, spacing: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i: int in count:
		out.append(center + Vector2((i - (count - 1) * 0.5) * spacing, 0.0))
	return out


# --- tally ---


func _count(event: CombatEvent) -> void:
	if not _watched.has(event.target_id):
		return
	var target: Unit = _world.get_unit(event.target_id)
	var attacker: Unit = _world.get_unit(event.attacker_id)
	match event.kind:
		CombatEvent.Kind.HIT, CombatEvent.Kind.KILL:
			_landed[target.faction * 3 + event.aspect] += 1
			if event.kind == CombatEvent.Kind.KILL and Gibs.should_gib(event.overkill, target.type.max_hp):
				_gibbed += 1
		CombatEvent.Kind.BLOCK:
			_blocked[target.faction] += 1
		CombatEvent.Kind.SWING:
			if attacker != null and attacker.type.id == &"ripper":
				_ripper_swings[target.type.id] = _ripper_swings.get(target.type.id, 0) + 1


func _refresh_tally() -> void:
	if _tally == null or _watched.is_empty():
		return
	var standing: PackedInt32Array = PackedInt32Array([0, 0])
	for unit_id: int in _watched:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			standing[unit.faction] += 1
	var lines: PackedStringArray = PackedStringArray()
	for side: int in [LIGHT, DARK]:
		lines.append("%s: %d standing · blows taken: front %d (+%d blocked) · flank %d · rear %d" % [
			"Light" if side == LIGHT else "Dark", standing[side],
			_landed[side * 3], _blocked[side], _landed[side * 3 + 1], _landed[side * 3 + 2],
		])
	if _gibbed > 0:
		lines.append("Gibbed: %d" % _gibbed)
	_tally.text = "\n".join(lines)


func _alive(ids: PackedInt32Array) -> int:
	var n: int = 0
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			n += 1
	return n


# Percent of the blows landed on side that came from the front.
func _front_share(side: UnitType.Faction) -> int:
	return _share(side, MeleeCombat.Aspect.FRONT)


func _share(side: UnitType.Faction, aspect: MeleeCombat.Aspect) -> int:
	var total: int = _landed[side * 3] + _landed[side * 3 + 1] + _landed[side * 3 + 2]
	return 100 * _landed[side * 3 + aspect] / maxi(total, 1)


func _top_killer(ids: PackedInt32Array) -> Unit:
	var best: Unit = null
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and (best == null or unit.kills > best.kills):
			best = unit
	return best


# --- setup ---


func _build_labels() -> void:
	var box: VBoxContainer = VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	box.offset_top = 34.0
	_caption = _label(22)
	_tally = _label(17)
	box.add_child(_caption)
	box.add_child(_tally)
	_main.get_node("Hud").add_child(box)


static func _label(font_size: int) -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_constant_override("outline_size", 8)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	return label
