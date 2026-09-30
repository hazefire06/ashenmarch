extends SceneTree
## Projectile showcase: `make demo-projectiles` (DEMO_SPEED=2 to run faster).
##
## Runs the real game and stages the Phase 4 physics one event after another
## on Riverside, each with a caption and a live tally:
## 1. Volley: Longbows behind a Shieldman line shoot Husks coming at them,
##    lobbing over their own men; each archer's first shot is its fire arrow.
## 2. Bounce and roll: Sappers bombard a patch of ground. Grenades bounce,
##    roll, and burst on their fuses; now and then one fizzles into a dud.
## 3. Uphill: Sappers at the foot of Riverside's steepest slope throw 5.5 m
##    up it. The bottles land, roll back down, and burst among them.
## 4. Satchel line: a Sapper lays four charges across a path with T. Husks
##    walk into them and a second Sapper sets them off: one blast becomes
##    four, and each leaves a crater.
## 5. Finale: the standing squads at the ford, archers and Drifters and all.
## When it ends the game is yours.
##
## DEMO_CAPTURE=<dir> saves a screenshot at each result and quits at the end.
##
## Everything happens through sim commands, exactly like player input.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const EVENTS: int = 5
const READ_BEFORE: float = 4.0
const READ_AFTER: float = 5.0
const FIGHT_TIMEOUT: float = 60.0
const FINALE_TIMEOUT: float = 90.0
## Yaw 0 looks north; a half turn looks south.
const LOOK_SOUTH: float = PI
## Riverside's steepest dry slope (about 27 degrees), its foot, and the way
## up it (a unit vector, x and z).
const SLOPE_FOOT: Vector2 = Vector2(442.0, 271.0)
const UPHILL: Vector2 = Vector2(0.555, -0.832)
## How far up the slope the Sappers throw: short enough that the bottle
## comes back (see docs/architecture.md, Projectiles).
const UPHILL_THROW: float = 5.5

var _main: MainView
var _world: World
var _camera: RtsCamera
var _caption: Label
var _tally: Label
var _last_tick: int = -1
var _capture_dir: String = OS.get_environment("DEMO_CAPTURE")
var _event: int = 0
## This event's counts, by name.
var _counts: Dictionary[String, int] = {}
## Units the tally watches this event.
var _watched: Dictionary[int, bool] = {}


func _initialize() -> void:
	var speed: String = OS.get_environment("DEMO_SPEED")
	Engine.time_scale = float(speed) if speed.is_valid_float() and float(speed) > 0.0 else 1.0
	Engine.max_physics_steps_per_frame = 16
	_main = load("res://view/main.tscn").instantiate() as MainView
	root.add_child(_main)
	_run.call_deferred()


func _physics_process(_delta: float) -> bool:
	if _world == null or _world.tick == _last_tick:
		return false
	_last_tick = _world.tick
	for event: ProjectileEvent in _world.projectile_events:
		_count(event)
	for event: CombatEvent in _world.combat_events:
		if event.kind == CombatEvent.Kind.BLOCK and _watched.has(event.target_id):
			_bump("blocked")
	_refresh_tally()
	return false


func _run() -> void:
	await process_frame
	_world = _main.world
	_camera = _main.get_node("CameraRig") as RtsCamera
	_build_labels()
	await _volley()
	await _bounce_and_roll()
	await _uphill()
	await _satchel_line()
	await _finale()
	Engine.time_scale = 1.0
	if not _capture_dir.is_empty():
		quit()
		return
	_caption.text = "Demo over. You have control. Cmd/Ctrl+click the ground to bombard it, T for the special, Tab for the map. F9 switches sides."
	_tally.text = ""


func _volley() -> void:
	var c: Vector2 = Vector2(390.0, 120.0)
	_begin(1, "Volley", "6 Longbows stand behind 5 Shieldmen. 10 Husks come at them. Arrows are real objects: they arc, stick where they land, and hit whatever is in the way, friend or foe. The archers lob over their own line. Each fires its one fire arrow first (T).", c, LOOK_SOUTH, 38.0)
	var line: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c + Vector2(0.0, 2.0), 5, 1.6), Vector2i(0, 1))
	var archers: PackedInt32Array = await _spawn(&"longbow", LIGHT, _row(c + Vector2(0.0, -2.0), 6, 2.0), Vector2i(0, 1))
	var husks: PackedInt32Array = await _spawn(&"husk", DARK, _row(c + Vector2(0.0, 42.0), 10, 1.6), Vector2i(0, -1))
	_world.enqueue(UseSpecialCommand.new(_world.tick, archers))
	await _wait(READ_BEFORE)
	_attack_move(husks, c + Vector2(0.0, -6.0), Formations.Kind.SHORT_LINE)
	var light: PackedInt32Array = line.duplicate()
	light.append_array(archers)
	var seconds: float = await _fight(light, husks, FIGHT_TIMEOUT)
	_result("%d/10 Husks down in %.0f s. %d arrows loosed, %d struck a body (%d a friend), %d stuck in the ground. %d fire marks for Phase 5." % [
		10 - _alive(husks), seconds, _n("launch"), _n("hit"), _n("friendly hit"), _n("stick"), _n("fire mark")
	])
	await _wait(READ_AFTER)


func _bounce_and_roll() -> void:
	var c: Vector2 = Vector2(380.0, 440.0)
	_begin(2, "Bounce and roll", "3 Sappers bombard a patch of ground (Cmd/Ctrl+click). Bottle grenades are lobbed, bounce, roll downhill, and burst on a 3.5 s fuse. About 1 in 20 fizzles and lies there as a dud until a blast sets it off.", c, 0.0, 26.0)
	var sappers: PackedInt32Array = await _spawn(&"sapper", LIGHT, _row(c + Vector2(0.0, 12.0), 3, 3.0), Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_world.enqueue(GroundAttackCommand.new(_world.tick, sappers, roundi(c.x * M), roundi(c.y * M)))
	await _wait_sim(14.0)
	_world.enqueue(StopUnitsCommand.new(_world.tick, sappers))
	await _wait_sim(4.0)
	_result("%d grenades thrown: %d bounces, %d blasts, %d fizzled. Look for the craters." % [
		_n("launch"), _n("bounce"), _n("blast"), _n("fizzle")
	])
	await _wait(READ_AFTER)


func _uphill() -> void:
	var c: Vector2 = SLOPE_FOOT
	_begin(3, "Uphill", "3 Sappers at the foot of the steepest slope on the map (27 degrees) each throw once, %.1f m up it. Thrown explosives suffer far more uphill than arrows. Watch where the bottles end up." % UPHILL_THROW, c + UPHILL * 3.0, atan2(UPHILL.x, -UPHILL.y) + PI, 20.0)
	var along: Vector2 = Vector2(-UPHILL.y, UPHILL.x)
	var spots: Array[Vector2] = [c - along * 4.0, c, c + along * 4.0]
	var sappers: PackedInt32Array = await _spawn(&"sapper", LIGHT, spots, Vector2i(roundi(UPHILL.x * 1000), roundi(UPHILL.y * 1000)))
	await _wait(READ_BEFORE)
	for k: int in sappers.size():
		var at: Vector2 = spots[k] + UPHILL * UPHILL_THROW
		_world.enqueue(GroundAttackCommand.new(
			_world.tick, PackedInt32Array([sappers[k]]), roundi(at.x * M), roundi(at.y * M)
		))
	# One throw each, then hold.
	while _n("launch") < sappers.size():
		await physics_frame
	_world.enqueue(StopUnitsCommand.new(_world.tick, sappers))
	await _wait_sim(6.0)
	var hurt: int = 0
	for unit_id: int in sappers:
		var unit: Unit = _world.get_unit(unit_id)
		hurt += 1 if unit.hp < unit.type.max_hp else 0
	_result("%d of 3 Sappers hurt by their own grenades. Thrown farther up (7.5 m or more), the bottles would have stayed up there." % hurt)
	await _wait(READ_AFTER)


func _satchel_line() -> void:
	var c: Vector2 = Vector2(110.0, 160.0)
	_begin(4, "Satchel line", "A Sapper lays 4 satchel charges across the path with T. Charges never go off by themselves: any blast within 5 m sets them off, and each sets off the next. Husks are coming.", c, LOOK_SOUTH, 34.0)
	var layer: PackedInt32Array = await _spawn(&"sapper", LIGHT, [c + Vector2(-4.5, 0.0)], Vector2i(0, 1))
	for k: int in 4:
		_world.enqueue(UseSpecialCommand.new(_world.tick, layer))
		await _wait_sim(0.2)
		if k < 3:
			var next: Vector2 = c + Vector2(-4.5 + 3.0 * (k + 1), 0.0)
			_world.enqueue(MoveUnitsCommand.new(_world.tick, layer, roundi(next.x * M), roundi(next.y * M), Formations.Kind.SHORT_LINE))
			await _wait_sim(2.0)
	_world.enqueue(MoveUnitsCommand.new(_world.tick, layer, roundi(c.x * M), roundi((c.y - 22.0) * M), Formations.Kind.SHORT_LINE))
	var bait: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c + Vector2(0.0, -8.0), 5, 1.6), Vector2i(0, 1))
	var detonator: PackedInt32Array = await _spawn(&"sapper", LIGHT, [c + Vector2(0.0, -20.0)], Vector2i(0, 1))
	var husks: PackedInt32Array = await _spawn(&"husk", DARK, _row(c + Vector2(0.0, 26.0), 10, 1.4), Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(husks, c + Vector2(0.0, -10.0), Formations.Kind.SHORT_LINE)
	var started: int = _world.tick
	# Set the line off once the leading Husks reach it.
	while _nearest_to(husks, c.y) > 2.0:
		await physics_frame
	_world.enqueue(GroundAttackCommand.new(_world.tick, detonator, roundi(c.x * M), roundi(c.y * M)))
	await _wait_sim(6.0)
	_world.enqueue(StopUnitsCommand.new(_world.tick, detonator))
	var light: PackedInt32Array = bait.duplicate()
	light.append_array(layer)
	light.append_array(detonator)
	await _fight(light, husks, FIGHT_TIMEOUT)
	var seconds: float = float(_world.tick - started) / World.TICK_RATE
	_result("%d of 4 satchels went off (%d blasts in all, %d craters). %d/10 Husks down %.0f s after they set out; %d of 5 bait Shieldmen standing." % [
		_n("satchel blast"), _n("blast"), _n("crater"), 10 - _alive(husks), seconds, _alive(bait)
	])
	await _wait(READ_AFTER)


func _finale() -> void:
	_begin(5, "Finale", "The standing squads fight at the ford: Shieldmen, Reavers, Longbows and Sappers against Husks, Rippers, and floating Drifters that cross the deep water.", Vector2(285.0, 245.0), 0.0, 70.0)
	var light: PackedInt32Array = PackedInt32Array()
	var dark: PackedInt32Array = PackedInt32Array()
	for unit: Unit in _world.units:
		if not unit.is_alive() or _watched.has(unit.id) or unit.x < 230 * M or unit.x > 330 * M:
			continue
		if unit.z < 170 * M or unit.z > 300 * M:
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
	_result("After %.0f s: Light %d/%d standing, Dark %d/%d. %d arrows and %d grenades loosed, %d blasts." % [
		seconds, _alive(light), light.size(), _alive(dark), dark.size(),
		_n("launched arrow") + _n("launched fire_arrow"), _n("launched grenade"), _n("blast")
	])
	await _wait(READ_AFTER)


# --- staging ---


func _begin(n: int, title: String, text: String, focus: Vector2, yaw: float, distance: float) -> void:
	_event = n
	_watched.clear()
	_counts.clear()
	_caption.text = "%d/%d  %s\n%s" % [n, EVENTS, title, text]
	_camera.set_pose(focus, yaw, distance)


# Enqueues one spawn per spot (meters) and waits until they exist.
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


func _fight(light: PackedInt32Array, dark: PackedInt32Array, timeout: float) -> float:
	var start: int = _world.tick
	while _world.tick - start < roundi(timeout * World.TICK_RATE):
		await physics_frame
		if _alive(light) == 0 or _alive(dark) == 0:
			break
	return float(_world.tick - start) / World.TICK_RATE


# Waits this many seconds of sim time (it runs faster with DEMO_SPEED).
func _wait_sim(seconds: float) -> void:
	var until: int = _world.tick + roundi(seconds * World.TICK_RATE)
	while _world.tick < until:
		await physics_frame


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _result(text: String) -> void:
	_caption.text += "\nResult: " + text
	print("event %d result: %s" % [_event, text])
	if not _capture_dir.is_empty():
		await process_frame
		await process_frame
		root.get_viewport().get_texture().get_image().save_png(
			_capture_dir.path_join("demo_projectiles_%d.png" % _event)
		)


# Metres from z to the living unit among ids nearest it along z.
func _nearest_to(ids: PackedInt32Array, z: float) -> float:
	var best: float = INF
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			best = minf(best, absf(unit.z / float(M) - z))
	return best


static func _row(center: Vector2, count: int, spacing: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i: int in count:
		out.append(center + Vector2((i - (count - 1) * 0.5) * spacing, 0.0))
	return out


# --- tally ---


func _count(event: ProjectileEvent) -> void:
	match event.kind:
		ProjectileEvent.Kind.LAUNCH:
			if _watched.has(event.unit_id):
				_bump("launch")
				_bump("launched %s" % _world.catalog.projectile_types[event.type_index].id)
		ProjectileEvent.Kind.STICK:
			_bump("stick")
		ProjectileEvent.Kind.HIT:
			_bump("hit")
			var target: Unit = _world.get_unit(event.unit_id)
			if target != null and target.faction == LIGHT:
				_bump("friendly hit")
		ProjectileEvent.Kind.BOUNCE:
			_bump("bounce")
		ProjectileEvent.Kind.EXPLODE:
			_bump("blast")
			if event.crater > 0:
				_bump("crater")
			if _world.catalog.projectile_types[event.type_index].id == &"satchel":
				_bump("satchel blast")
		ProjectileEvent.Kind.FIZZLE:
			_bump("fizzle")
		ProjectileEvent.Kind.FIRE_MARK:
			_bump("fire mark")


func _bump(key: String) -> void:
	_counts[key] = _counts.get(key, 0) + 1


func _n(key: String) -> int:
	return _counts.get(key, 0)


func _refresh_tally() -> void:
	if _tally == null or _event == 0:
		return
	var parts: PackedStringArray = PackedStringArray()
	for key: String in ["launch", "stick", "hit", "friendly hit", "blocked", "bounce", "fizzle", "blast", "crater", "fire mark"]:
		if _counts.has(key):
			parts.append("%s %d" % [key, _counts[key]])
	var standing: PackedInt32Array = PackedInt32Array([0, 0])
	for unit_id: int in _watched:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			standing[unit.faction] += 1
	_tally.text = "Light %d · Dark %d standing    %s" % [standing[0], standing[1], " · ".join(parts)]


func _alive(ids: PackedInt32Array) -> int:
	var n: int = 0
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			n += 1
	return n


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
