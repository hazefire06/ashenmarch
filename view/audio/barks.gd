class_name Barks
extends Node3D
## The light side's spoken lines. A unit speaks when it is selected, ordered,
## kills, is hurt, dies, catches a status, heals the undead, fizzles a fire
## arrow, or the mission is won. Each bark floats as text over the speaker and
## plays its voice too, if the line has one: with no voices bought, barks are
## text only. When a bark is allowed is BarkRules'; what is said is the
## BarkBook's. View only: its time is `now` in view seconds and its chance is
## the rules' own RNG, never the sim's.

const BARK_COLOR: Color = Color(0.80, 0.92, 1.0)
const VOICES: int = 3
## A unit speaks of being hurt below this share of its max HP, and again only
## after it has been above HURT_REARM_PERCENT.
const HURT_BELOW_PERCENT: int = 35
const HURT_REARM_PERCENT: int = 50
## Event barks (kill, death, hurt, status) only come from units this near the focus.
const HEAR_DISTANCE: float = SfxPlayer.CULL_DISTANCE
## Launches whose projectile is gone are dropped this often (steps).
const PRUNE_STEPS: int = 300

## Plays no voice while false; the text still shows.
var enabled: bool = true
## View seconds. `_process` adds the frame's delta; tests set it.
var now: float = 0.0
## Set by MainView: while paused the clock holds, so cooldowns don't expire behind a frozen battle.
var paused: bool = false
var rules: BarkRules = BarkRules.new()
var book: BarkBook = null
var map: SoundMap = null

var _world: World
var _camera: RtsCamera
var _units_view: UnitsView
var _controller: SelectionController
var _viewer: UnitType.Faction = UnitType.Faction.LIGHT
var _players: Array[AudioStreamPlayer3D] = []
## When each player last started, parallel to _players.
var _started_at: Array[float] = []
## Units that have not yet spoken of being hurt since last above the re-arm line.
var _hurt_armed: Dictionary[int, bool] = {}
## Each unit's status bits at the last step (bit per StatusEffects.Kind).
var _statuses: Dictionary[int, int] = {}
## Units whose death bark this step had a voice.
var _voiced_deaths: Dictionary[int, bool] = {}
var _last: Dictionary = {}
## Fire arrows in flight: projectile id to the unit that launched it. The sim
## drops a doused arrow before the view reads its FIZZLE.
var _launched: Dictionary[int, int] = {}
var _steps: int = 0


func setup(
	world: World, camera: RtsCamera, units_view: UnitsView, lines: BarkBook = BarkBook.shared(),
	sound_map: SoundMap = SoundMap.shared()
) -> void:
	_world = world
	_camera = camera
	_units_view = units_view
	book = lines
	map = sound_map
	for i: int in VOICES:
		var player: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		player.bus = &"Voice"
		player.unit_size = SfxPlayer.UNIT_SIZE
		player.max_distance = SfxPlayer.CULL_DISTANCE * 2.0
		add_child(player)
		_players.append(player)
		_started_at.append(-INF)


func _process(delta: float) -> void:
	if paused:
		return
	now += delta


## The side whose units speak; only the Light side does.
func set_viewer(side: UnitType.Faction) -> void:
	_viewer = side


## Listens to what the player selects, orders and arranges.
func connect_selection(controller: SelectionController) -> void:
	_controller = controller
	controller.player_selected.connect(on_player_selected)
	controller.order_given.connect(on_order)
	controller.formation_changed.connect(on_formation)
	controller.group_changed.connect(on_group)


func last_bark() -> Dictionary:
	return _last


## True when this step's death bark for the unit has a voice, so the cry that
## would have played is skipped.
func voiced_death(unit_id: int) -> bool:
	return _voiced_deaths.get(unit_id, false)


func on_player_selected(ids: PackedInt32Array) -> void:
	# A box over nothing, or a toggle-off, selects no one.
	if ids.is_empty():
		return
	var trigger: StringName = &"select"
	if ids.size() == 1 and rules.click(ids[0], now):
		trigger = &"annoyed"
	_speak(_nearest(ids), trigger, PackedInt32Array())


## A recalled group speaks as a selection; slot -1 is "no group".
func on_group(slot: int) -> void:
	if slot < 0 or _controller == null:
		return
	var ids: PackedInt32Array = _controller.selection.ids()
	if not ids.is_empty():
		_speak(_nearest(ids), &"select", PackedInt32Array())


func on_order(ids: PackedInt32Array, kind: SelectionController.OrderKind) -> void:
	var trigger: StringName = &""
	match kind:
		SelectionController.OrderKind.MOVE:
			trigger = &"move"
		SelectionController.OrderKind.ATTACK:
			trigger = &"attack"
		SelectionController.OrderKind.SPECIAL:
			trigger = &"special"
		SelectionController.OrderKind.RETREAT:
			trigger = &"retreat"
	if trigger != &"" and not ids.is_empty():
		_speak(_nearest(ids), trigger, ids)


func on_formation(kind: Formations.Kind) -> void:
	if _controller == null:
		return
	var ids: PackedInt32Array = _controller.selection.ids()
	if ids.is_empty():
		return
	var name: String = String(Formations.Kind.keys()[kind]).to_lower()
	_speak(_nearest(ids), StringName("formation_" + name), PackedInt32Array())


## Reads the last step's events. Call once per step, after it and before SfxPlayer's.
func after_step() -> void:
	_voiced_deaths.clear()
	_steps += 1
	for event: CombatEvent in _world.combat_events:
		match event.kind:
			CombatEvent.Kind.KILL:
				var attacker: Unit = _world.get_unit(event.attacker_id)
				var target: Unit = _world.get_unit(event.target_id)
				# No crowing over friendly fire or a self-kill.
				if attacker != null and target != null and attacker.faction != target.faction:
					_speak(attacker, &"kill", PackedInt32Array(), true)
				if target != null and _speak(target, &"death", PackedInt32Array(), true):
					if _last.get("voiced", false):
						_voiced_deaths[target.id] = true
			CombatEvent.Kind.HEAL:
				var healed: Unit = _world.get_unit(event.target_id)
				if healed != null and healed.type.nature == UnitType.Nature.UNDEAD:
					_speak(_world.get_unit(event.attacker_id), &"heal_undead", PackedInt32Array(), true)
	for event: ProjectileEvent in _world.projectile_events:
		_on_projectile(event)
	if _steps % PRUNE_STEPS == 0:
		for id: int in _launched.keys():
			if _world.get_entity(id) == null:
				_launched.erase(id)
	_watch_units()
	for event: MissionEvent in _world.mission_events:
		if event.kind == MissionEvent.Kind.WON:
			_victory()


func _on_projectile(event: ProjectileEvent) -> void:
	match event.kind:
		ProjectileEvent.Kind.LAUNCH:
			_launched[event.projectile_id] = event.unit_id
		ProjectileEvent.Kind.FIZZLE:
			var thrower: int = _launched.get(event.projectile_id, -1)
			if thrower < 0:
				var projectile: Projectile = _world.get_entity(event.projectile_id) as Projectile
				if projectile != null:
					thrower = projectile.instigator_id
			_speak(_world.get_unit(thrower), &"fizzle", PackedInt32Array(), true)
			_launched.erase(event.projectile_id)
		ProjectileEvent.Kind.EXPLODE, ProjectileEvent.Kind.STICK, ProjectileEvent.Kind.HIT:
			_launched.erase(event.projectile_id)


# Hurt and status barks come from watching each of the viewer's units. A unit's
# first sighting only sets its state, so the wounded and burning at the start
# say nothing; units gone or dead are forgotten.
func _watch_units() -> void:
	if _viewer != UnitType.Faction.LIGHT:
		_hurt_armed.clear()
		_statuses.clear()
		return
	var present: Dictionary[int, bool] = {}
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.faction != _viewer:
			continue
		present[unit.id] = true
		var scaled: int = unit.hp * 100
		var max_hp: int = unit.type.max_hp
		var bits: int = 0
		for kind: int in StatusEffects.Kind.values():
			if StatusEffects.has(_world, unit, kind as StatusEffects.Kind):
				bits |= 1 << kind
		if not _statuses.has(unit.id):
			_statuses[unit.id] = bits
			_hurt_armed[unit.id] = scaled >= HURT_BELOW_PERCENT * max_hp
			continue
		if scaled > HURT_REARM_PERCENT * max_hp:
			_hurt_armed[unit.id] = true
		elif scaled < HURT_BELOW_PERCENT * max_hp and _hurt_armed.get(unit.id, true):
			if _speak(unit, &"hurt", PackedInt32Array(), true):
				_hurt_armed[unit.id] = false
		var fresh: int = bits & ~_statuses[unit.id]
		_statuses[unit.id] = bits
		if fresh != 0:
			var trigger: StringName = _status_trigger(fresh)
			if trigger != &"":
				_speak(unit, trigger, PackedInt32Array(), true)
	for id: int in _statuses.keys():
		if not present.has(id):
			_statuses.erase(id)
			_hurt_armed.erase(id)


static func _status_trigger(fresh: int) -> StringName:
	if fresh & (1 << StatusEffects.Kind.BURNING) != 0:
		return &"status_burning"
	if fresh & (1 << StatusEffects.Kind.PARALYSIS) != 0:
		return &"status_paralyzed"
	if fresh & (1 << StatusEffects.Kind.CONFUSION) != 0:
		return &"status_confused"
	return &""


# The living unit of yours nearest the camera's focus speaks for the win.
func _victory() -> void:
	var best: Unit = null
	var best_d: float = INF
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.faction != _viewer:
			continue
		var d: float = _distance(unit)
		if d < best_d:
			best_d = d
			best = unit
	_speak(best, &"victory", PackedInt32Array())


# The unit among `ids` nearest the focus (null when none is a live unit).
func _nearest(ids: PackedInt32Array) -> Unit:
	var best: Unit = null
	var best_d: float = INF
	for id: int in ids:
		var unit: Unit = _world.get_unit(id)
		if unit == null or not unit.is_alive():
			continue
		var d: float = _distance(unit)
		if d < best_d:
			best_d = d
			best = unit
	return best


## Meters across the ground from the camera's focus.
func _distance(unit: Unit) -> float:
	var focus: Vector3 = _camera.focus
	var at: Vector2 = Vector2(unit.x, unit.z) / float(World.UNITS_PER_METER)
	return at.distance_to(Vector2(focus.x, focus.z))


## Speaks `trigger` for `unit` if it may. Returns whether a bark began.
func _speak(unit: Unit, trigger: StringName, squad: PackedInt32Array, near_only: bool = false) -> bool:
	if unit == null or _viewer != UnitType.Faction.LIGHT or unit.faction != UnitType.Faction.LIGHT:
		return false
	if not unit.is_alive() and trigger != &"death":
		return false
	var voice: StringName = map.voice_for(unit)
	if voice == &"":
		return false
	if near_only and _distance(unit) > HEAR_DISTANCE:
		return false
	# Refused barks stop here, before they roll the clan chance or build lists.
	if not rules.allow(trigger, now, squad):
		return false
	var clan: bool = rules.clan_turn()
	var lines: Array[BarkLine] = []
	var key: StringName = StringName("%s/%s" % [voice, trigger])
	if clan:
		lines = _spoken_by(book.clan_lines(), voice)
		key = StringName("%s/clan" % voice)
	if lines.is_empty():
		clan = false
		lines = _spoken_by(book.lines_for(unit.type.id, trigger), voice)
		key = StringName("%s/%s" % [voice, trigger])
	if lines.is_empty():
		return false
	var line: BarkLine = lines[rules.pick(key, lines.size())]
	rules.note_clan(clan)
	var seconds: float = line.seconds(voice)
	_units_view.show_text(unit.id, line.text, BARK_COLOR, seconds, true)
	var voiced: bool = enabled and line.streams.has(voice)
	if voiced:
		voiced = _play(line.streams[voice], unit, trigger == &"death")
	rules.started(trigger, now, seconds, squad)
	_last = {
		"unit_id": unit.id, "line_id": line.id, "text": line.text, "trigger": trigger, "voiced": voiced,
	}
	return true


static func _spoken_by(lines: Array[BarkLine], voice: StringName) -> Array[BarkLine]:
	var found: Array[BarkLine] = []
	for line: BarkLine in lines:
		if line.voices.has(voice):
			found.append(line)
	return found


# A free player, else (for a death) the oldest; any other bark waits. Returns
# whether the voice started.
func _play(stream: AudioStream, unit: Unit, takes_oldest: bool) -> bool:
	var slot: int = -1
	for i: int in VOICES:
		if not _players[i].playing:
			slot = i
			break
	if slot < 0:
		if not takes_oldest:
			return false
		slot = _started_at.find(_started_at.min())
	var player: AudioStreamPlayer3D = _players[slot]
	var at: Vector3 = _units_view.sprite_position(unit.id)
	if at == Vector3.ZERO:
		at = Vector3(unit.x, unit.y, unit.z) / float(World.UNITS_PER_METER)
	player.stream = stream
	player.position = at
	player.play()
	_started_at[slot] = now
	return true
