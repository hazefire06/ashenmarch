extends SceneTree
## Phase 6 showcase: `make demo-abilities` (DEMO_SPEED=2 to run faster).
##
## Runs the real game and stages the new units and status effects on
## Riverside, one event after another, each with a caption and a live tally:
## 1. Gas: a Blightbag walks into a Shieldman line and bursts. The cloud
##    paralyzes everyone in it, Husks included, and leaves two gas packets.
## 2. Herbs: a Warden heals a burning and a paralyzed Shieldman, a Shieldman
##    strikes a herb plant for two more herbs, and a Husk that comes close is
##    killed by a herb.
## 3. Lightning: a Stormcaller casts down a file of Shieldmen; one bolt
##    strikes everyone on its line. Ordered to strike the ground at a satchel
##    lying among them, it sets the satchel off. Reavers then run it down:
##    struck, it can't finish a cast.
## 4. Scavengers: Sappers lay satchels in front of their line; Rippers pick
##    them up and throw them back at the Sappers.
## 5. Finale: the standing squads at the ford, the whole roster.
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
const FIGHT_TIMEOUT: float = 45.0
const FINALE_TIMEOUT: float = 90.0
## Yaw 0 looks north; a half turn looks south.
const LOOK_SOUTH: float = PI
## Where MainView stood the Dark test squad (meters) until Phase 7 made the
## Dark side the Riverside AI mission; the finale stands one there again.
const DARK_ORIGIN: Vector2 = Vector2(250.0, 275.0)
const DARK_SPACING: float = 2.0

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
## Watched units seen paralyzed this event.
var _paralyzed: Dictionary[int, bool] = {}
## Bolts cast before the Reavers charged, in the lightning event.
var _bolts_before_reavers: int = 0


func _initialize() -> void:
	var speed: String = OS.get_environment("DEMO_SPEED")
	Engine.time_scale = float(speed) if speed.is_valid_float() and float(speed) > 0.0 else 1.0
	Engine.max_physics_steps_per_frame = 16
	_main = load("res://view/main.tscn").instantiate() as MainView
	# No Riverside AI mission: its 29 Dark units would hunt across every
	# event. The finale stands its own Dark squad (_finale).
	_main.mission_path = ""
	root.add_child(_main)
	_run.call_deferred()


func _physics_process(_delta: float) -> bool:
	if _world == null or _world.tick == _last_tick:
		return false
	_last_tick = _world.tick
	for event: ProjectileEvent in _world.projectile_events:
		_count(event)
	for event: CombatEvent in _world.combat_events:
		if event.kind == CombatEvent.Kind.HEAL:
			_bump("heal")
		elif event.kind == CombatEvent.Kind.KILL and _watched.has(event.target_id):
			_bump("killed")
	for unit_id: int in _watched:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and StatusEffects.paralyzed(_world, unit) and not _paralyzed.has(unit_id):
			_paralyzed[unit_id] = true
			_bump("paralyzed")
	_refresh_tally()
	return false


func _run() -> void:
	await process_frame
	_world = _main.world
	_camera = _main.get_node("CameraRig") as RtsCamera
	_build_labels()
	await _gas()
	await _herbs()
	await _lightning()
	await _scavengers()
	await _finale()
	Engine.time_scale = 1.0
	if not _capture_dir.is_empty():
		quit()
		return
	_caption.text = "Demo over. You have control. T with a Warden selected, then click a unit, to heal it. Right-click a herb plant or a loose object to use it. F8 cycles status effects on the selection; F9 switches sides."
	_tally.text = ""


func _gas() -> void:
	var c: Vector2 = Vector2(392.0, 122.0)
	_begin(1, "Gas", "A Blightbag walks into 5 Shieldmen. It bursts on contact (and whenever it dies): a blast, and a cloud that paralyzes everyone inside, either side. 6 Husks come behind it to take advantage. Paralyzed units can't move, fight, or block.", c, LOOK_SOUTH, 24.0)
	var line: PackedInt32Array = await _spawn(&"shieldman", LIGHT, _row(c, 5, 1.6), Vector2i(0, 1))
	var bag: PackedInt32Array = await _spawn(&"blightbag", DARK, [c + Vector2(0.0, 14.0)], Vector2i(0, -1))
	var husks: PackedInt32Array = await _spawn(&"husk", DARK, _row(c + Vector2(0.0, 24.0), 6, 1.6), Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(bag, c + Vector2(0.0, -4.0), Formations.Kind.SHORT_LINE)
	await _wait_sim(3.0)
	_attack_move(husks, c + Vector2(0.0, -4.0), Formations.Kind.SHORT_LINE)
	await _fight(line, husks, FIGHT_TIMEOUT)
	_result("%d units paralyzed by the gas. %d gas packets left lying. Shieldmen standing: %d/5; Husks: %d/6." % [
		_n("paralyzed"), _packets_near(c, 12.0), _alive(line), _alive(husks)
	])
	await _wait(READ_AFTER)


func _herbs() -> void:
	var c: Vector2 = Vector2(380.0, 440.0)
	_begin(2, "Herbs", "A Warden carries 6 healing herbs. It heals a burning Shieldman and a paralyzed one (T, then click). A Shieldman strikes a herb plant (right-click it): 2 more herbs fall, and the Warden picks them up. Then a Husk wanders close: a herb kills the undead.", c, 0.0, 20.0)
	var warden: PackedInt32Array = await _spawn(&"warden", LIGHT, [c], Vector2i(0, -1))
	var hurt: PackedInt32Array = await _spawn(&"shieldman", LIGHT, [c + Vector2(-4.0, -3.0), c + Vector2(4.0, -3.0)], Vector2i(0, -1))
	_world.enqueue(SpawnHerbPlantCommand.new(_world.tick, roundi((c.x + 8.0) * M), roundi((c.y + 5.0) * M)))
	await _wait_sim(0.1)
	var plant: HerbPlant = _world.herb_plants[_world.herb_plants.size() - 1]
	_world.enqueue(ApplyStatusCommand.new(_world.tick, PackedInt32Array([hurt[0]]), StatusEffects.Kind.BURNING, 150))
	_world.enqueue(ApplyStatusCommand.new(_world.tick, PackedInt32Array([hurt[1]]), StatusEffects.Kind.PARALYSIS, 600))
	await _wait(READ_BEFORE)
	_world.enqueue(HealCommand.new(_world.tick, warden, hurt[0]))
	await _wait_sim(3.0)
	_world.enqueue(HealCommand.new(_world.tick, warden, hurt[1]))
	await _wait_sim(3.0)
	_world.enqueue(InteractCommand.new(_world.tick, PackedInt32Array([hurt[0]]), plant.id))
	await _wait_sim(4.0)
	_world.enqueue(MoveUnitsCommand.new(_world.tick, warden, plant.x, plant.z, Formations.Kind.SHORT_LINE))
	await _wait_sim(5.0)
	var husk: PackedInt32Array = await _spawn(&"husk", DARK, [c + Vector2(0.0, 14.0)], Vector2i(0, -1))
	_world.enqueue(MoveUnitsCommand.new(_world.tick, husk, roundi(c.x * M), roundi((c.y + 6.0) * M), Formations.Kind.SHORT_LINE))
	await _wait_sim(4.0)
	_world.enqueue(HealCommand.new(_world.tick, warden, husk[0]))
	await _wait_sim(5.0)
	var w: Unit = _world.get_unit(warden[0])
	_result("%d heals. The Warden has %d/6 herbs. The Husk is %s." % [
		_n("heal"), w.special_left, "dead" if _alive(husk) == 0 else "still standing"
	])
	await _wait(READ_AFTER)


func _lightning() -> void:
	var c: Vector2 = Vector2(110.0, 160.0)
	_begin(3, "Lightning", "A Stormcaller's lightning is a straight line: it strikes every body on it, friend or foe, and sets off charges it passes. 4 Shieldmen stand in a file in front of it, with a satchel among them it will be ordered to strike. It can't hit anything closer than 8 m, and can't finish a cast while it's being struck. Then 3 Reavers charge it.", c + Vector2(0.0, 10.0), 0.0, 30.0)
	var caller: PackedInt32Array = await _spawn(&"stormcaller", DARK, [c], Vector2i(0, -1))
	var file: Array[Vector2] = []
	for k: int in 4:
		file.append(c + Vector2(0.0, 14.0 + 3.0 * k))
	var shieldmen: PackedInt32Array = await _spawn(&"shieldman", LIGHT, file, Vector2i(0, -1))
	var sapper: PackedInt32Array = await _spawn(&"sapper", LIGHT, [c + Vector2(0.0, 18.5)], Vector2i(0, -1))
	_world.enqueue(UseSpecialCommand.new(_world.tick, sapper))
	await _wait_sim(0.2)
	_world.enqueue(MoveUnitsCommand.new(_world.tick, sapper, roundi((c.x + 20.0) * M), roundi((c.y + 30.0) * M), Formations.Kind.SHORT_LINE))
	await _wait(READ_BEFORE)
	_world.enqueue(StopUnitsCommand.new(_world.tick, caller))
	await _wait_sim(6.0)
	var satchel_at: Vector2 = c + Vector2(0.0, 18.5)
	_world.enqueue(GroundAttackCommand.new(_world.tick, caller, roundi(satchel_at.x * M), roundi(satchel_at.y * M)))
	await _wait_sim(6.0)
	_world.enqueue(StopUnitsCommand.new(_world.tick, caller))
	var struck: int = _n("struck")
	_bolts_before_reavers = _n("bolt")
	var reavers: PackedInt32Array = await _spawn(&"reaver", LIGHT, _row(c + Vector2(0.0, -16.0), 3, 2.0), Vector2i(0, 1))
	_attack_move(reavers, c, Formations.Kind.SHORT_LINE)
	var started: int = _world.tick
	while _alive(caller) > 0 and _world.tick - started < roundi(FIGHT_TIMEOUT * World.TICK_RATE):
		await physics_frame
	_result("%d bolts struck %d bodies and set off %d satchels. The Reavers cut the Stormcaller down %.0f s after they charged; it cast %d more bolts in that time." % [
		_n("bolt"), struck, _n("satchel blast"), float(_world.tick - started) / World.TICK_RATE,
		_n("bolt") - _bolts_before_reavers
	])
	await _wait(READ_AFTER)


func _scavengers() -> void:
	var c: Vector2 = Vector2(150.0, 400.0)
	_begin(4, "Scavengers", "2 Sappers lay satchel charges in front of their line (T), and step back. 3 Rippers come. A Ripper with nothing better to do picks up what lies near (charges, gas packets, body parts) and throws it at Sappers, Longbows, and Wardens first.", c, LOOK_SOUTH, 26.0)
	var sappers: PackedInt32Array = await _spawn(&"sapper", LIGHT, _row(c, 2, 4.0), Vector2i(0, 1))
	for k: int in 2:
		_world.enqueue(UseSpecialCommand.new(_world.tick, sappers))
		await _wait_sim(0.3)
		_world.enqueue(MoveUnitsCommand.new(_world.tick, sappers, roundi(c.x * M), roundi((c.y + 2.0 + 2.0 * k) * M), Formations.Kind.SHORT_LINE))
		await _wait_sim(1.5)
	_world.enqueue(MoveUnitsCommand.new(_world.tick, sappers, roundi(c.x * M), roundi((c.y - 10.0) * M), Formations.Kind.SHORT_LINE))
	var rippers: PackedInt32Array = await _spawn(&"ripper", DARK, _row(c + Vector2(0.0, 26.0), 3, 2.0), Vector2i(0, -1))
	await _wait(READ_BEFORE)
	_attack_move(rippers, c + Vector2(0.0, 2.0), Formations.Kind.SHORT_LINE)
	await _wait_sim(25.0)
	_result("%d pick-ups, %d throws. Sappers standing: %d/2; Rippers: %d/3." % [
		_n("pick-up"), _n("throw"), _alive(sappers), _alive(rippers)
	])
	await _wait(READ_AFTER)


func _finale() -> void:
	_begin(5, "Finale", "The standing squads fight at the ford: the whole roster. Wardens behind the line, Blightbags and Stormcallers with the Husks and Rippers, herb plants on both banks.", Vector2(285.0, 245.0), 0.0, 70.0)
	# The whole Dark test squad as MainView laid it out before Phase 7: 20
	# Husks in a block south of the creek with 3 Blightbags in front, then
	# rows of 5 Rippers, 6 Drifters and 2 Stormcallers behind. MainView spawns
	# no Dark units since Phase 7.
	var back: Vector2 = DARK_ORIGIN + Vector2(0.0, 4.0 * DARK_SPACING)
	var dark: PackedInt32Array = await _spawn(&"husk", DARK, _grid(DARK_ORIGIN, 20, 5, DARK_SPACING), Vector2i(0, -1))
	dark.append_array(await _spawn(&"ripper", DARK, _grid(back, 5, 5, DARK_SPACING), Vector2i(0, -1)))
	dark.append_array(await _spawn(&"drifter", DARK, _grid(back + Vector2(0.0, DARK_SPACING), 6, 6, DARK_SPACING), Vector2i(0, -1)))
	dark.append_array(await _spawn(&"blightbag", DARK, _grid(DARK_ORIGIN - Vector2(0.0, DARK_SPACING), 3, 3, 2.0 * DARK_SPACING), Vector2i(0, -1)))
	dark.append_array(await _spawn(&"stormcaller", DARK, _grid(back + Vector2(0.0, 2.0 * DARK_SPACING), 2, 2, 4.0 * DARK_SPACING), Vector2i(0, -1)))
	# The Light side: whatever of MainView's test squad stands at the ford.
	var light: PackedInt32Array = PackedInt32Array()
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.faction != LIGHT or _watched.has(unit.id):
			continue
		if unit.x < 230 * M or unit.x > 330 * M or unit.z < 165 * M or unit.z > 305 * M:
			continue
		light.append(unit.id)
		_watched[unit.id] = true
	await _wait(READ_BEFORE)
	_attack_move(light, Vector2(255.0, 280.0), Formations.Kind.SHORT_LINE)
	_attack_move(dark, Vector2(295.0, 190.0), Formations.Kind.RABBLE)
	var seconds: float = await _fight(light, dark, FINALE_TIMEOUT)
	_result("After %.0f s: Light %d/%d standing, Dark %d/%d. %d bolts, %d heals, %d paralyzed, %d pick-ups." % [
		seconds, _alive(light), light.size(), _alive(dark), dark.size(),
		_n("bolt"), _n("heal"), _n("paralyzed"), _n("pick-up")
	])
	await _wait(READ_AFTER)


# --- staging ---


func _begin(n: int, title: String, text: String, focus: Vector2, yaw: float, distance: float) -> void:
	_event = n
	_watched.clear()
	_counts.clear()
	_paralyzed.clear()
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
			_capture_dir.path_join("demo_abilities_%d.png" % _event)
		)


func _packets_near(c: Vector2, radius: float) -> int:
	var n: int = 0
	for p: Projectile in _world.projectiles:
		if p.removed or p.type.id != &"gas_packet":
			continue
		if Vector2(p.x / float(M), p.z / float(M)).distance_to(c) <= radius:
			n += 1
	return n


# count spots in rows of columns, spacing meters apart, from origin toward +x
# and +z (MainView's old squad layout).
static func _grid(origin: Vector2, count: int, columns: int, spacing: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i: int in count:
		out.append(origin + Vector2((i % columns) * spacing, (i / columns) * spacing))
	return out


static func _row(center: Vector2, count: int, spacing: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i: int in count:
		out.append(center + Vector2((i - (count - 1) * 0.5) * spacing, 0.0))
	return out


# --- tally ---


func _count(event: ProjectileEvent) -> void:
	match event.kind:
		ProjectileEvent.Kind.BOLT:
			_bump("bolt")
		ProjectileEvent.Kind.PICK_UP:
			_bump("pick-up")
		ProjectileEvent.Kind.LAUNCH:
			var thrower: Unit = _world.get_unit(event.unit_id)
			if thrower != null and thrower.type.throws_carried:
				_bump("throw")
		ProjectileEvent.Kind.EXPLODE:
			_bump("blast")
			if _world.catalog.projectile_types[event.type_index].id == &"satchel":
				_bump("satchel blast")
	if event.kind == ProjectileEvent.Kind.BOLT:
		# Bodies the bolt touched: every hit this tick from the caster.
		for e: CombatEvent in _world.combat_events:
			if e.attacker_id == event.unit_id and (e.kind == CombatEvent.Kind.HIT or e.kind == CombatEvent.Kind.KILL):
				_bump("struck")


func _bump(key: String) -> void:
	_counts[key] = _counts.get(key, 0) + 1


func _n(key: String) -> int:
	return _counts.get(key, 0)


func _refresh_tally() -> void:
	if _tally == null or _event == 0:
		return
	var parts: PackedStringArray = PackedStringArray()
	for key: String in ["paralyzed", "heal", "bolt", "struck", "pick-up", "throw", "blast", "killed"]:
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
