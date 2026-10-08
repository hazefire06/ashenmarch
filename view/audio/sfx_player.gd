class_name SfxPlayer
extends Node3D
## Plays the battlefield's sounds from what the sim reports each tick: blows,
## blocks and deaths (World.combat_events), bows, impacts, bounces, blasts,
## fires and lightning (World.projectile_events), gas clouds as they appear,
## and the acknowledgement of the player's orders. Positional sounds come from
## a fixed pool of VOICES players on the Effects bus; the order sounds from
## one 2D player on the Interface bus.
##
## A big fight reports far more than can usefully be heard, so each sound
## plays at most MAX_PER_TICK times a tick and at most MAX_TICK_TOTAL sounds
## start in all; sounds farther than CULL_DISTANCE from the camera's focus
## aren't played. When every voice is busy the one that started first is
## taken. View only, and random only in pitch (so never the sim's RNG).

const VOICES: int = 24
const MAX_PER_TICK: int = 3
const MAX_TICK_TOTAL: int = 8
const CULL_DISTANCE: float = 160.0
## Melee sounds only for blows between units this close (meters): further
## apart, it was an arrow or a blast, whose own sounds play.
const MELEE_REACH: float = 4.0
const PITCH_SPREAD: float = 0.06
const UNIT_SIZE: float = 40.0
## The sound a launch makes, by projectile type id.
const LAUNCH_SOUNDS: Dictionary[StringName, StringName] = {
	&"arrow": &"bow_release", &"fire_arrow": &"bow_release",
	&"grenade": &"grenade_bounce", &"satchel": &"grenade_bounce",
	&"gas_packet": &"grenade_bounce", &"body_part": &"grenade_bounce",
}

var _world: World
var _camera: RtsCamera
var _voices: Array[AudioStreamPlayer3D] = []
var _next_voice: int = 0
var _interface: AudioStreamPlayer
var _counts: Dictionary[StringName, int] = {}
var _started: int = 0
var _seen_clouds: Dictionary[int, bool] = {}


func setup(world: World, camera: RtsCamera) -> void:
	_world = world
	_camera = camera
	for i: int in VOICES:
		var voice: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		voice.bus = &"Effects"
		voice.unit_size = UNIT_SIZE
		voice.max_distance = CULL_DISTANCE * 2.0
		add_child(voice)
		_voices.append(voice)
	_interface = AudioStreamPlayer.new()
	_interface.bus = &"Interface"
	add_child(_interface)
	for cloud: GasCloud in world.clouds:
		_seen_clouds[cloud.id] = true


## Reads the last step's events. Call once per step, after it.
func after_step() -> void:
	_counts.clear()
	_started = 0
	for event: CombatEvent in _world.combat_events:
		_on_combat(event)
	for event: ProjectileEvent in _world.projectile_events:
		_on_projectile(event)
	for cloud: GasCloud in _world.clouds:
		if not _seen_clouds.has(cloud.id):
			_seen_clouds[cloud.id] = true
			play_at(&"gas_hiss", _meters(cloud.x, cloud.y, cloud.z))


## The player's order was sent.
func acknowledge() -> void:
	play_ui(&"order_ack")


## How many sounds this tick has started; for tests.
func started_this_tick() -> int:
	return _started


## Plays `sound` at `at` (meters), within the caps and the cull distance.
## Returns whether it played.
func play_at(sound: StringName, at: Vector3) -> bool:
	if _started >= MAX_TICK_TOTAL or _counts.get(sound, 0) >= MAX_PER_TICK:
		return false
	if _camera != null:
		var focus: Vector3 = _camera.focus
		if Vector2(at.x - focus.x, at.z - focus.z).length() > CULL_DISTANCE:
			return false
	var voice: AudioStreamPlayer3D = _free_voice()
	voice.stream = SfxBank.stream(sound)
	voice.volume_db = SfxBank.level_db(sound)
	voice.pitch_scale = 1.0 + randf_range(-PITCH_SPREAD, PITCH_SPREAD)
	voice.position = at
	voice.play()
	_counts[sound] = _counts.get(sound, 0) + 1
	_started += 1
	return true


## Plays `sound` unplaced, on the Interface bus.
func play_ui(sound: StringName) -> void:
	_interface.stream = SfxBank.stream(sound)
	_interface.volume_db = SfxBank.level_db(sound)
	_interface.play()


func _on_combat(event: CombatEvent) -> void:
	var target: Unit = _world.get_unit(event.target_id)
	if target == null:
		return
	var at: Vector3 = _meters(target.x, target.y, target.z)
	if event.kind == CombatEvent.Kind.HEAL:
		play_at(&"heal", at)
		return
	if event.kind == CombatEvent.Kind.KILL:
		play_at(&"death", at)
	var attacker: Unit = _world.get_unit(event.attacker_id)
	if attacker == null:
		return
	var apart: float = Vector2(attacker.x - target.x, attacker.z - target.z).length() / World.UNITS_PER_METER
	if apart > MELEE_REACH:
		return
	match event.kind:
		CombatEvent.Kind.HIT, CombatEvent.Kind.KILL:
			play_at(&"sword_hit", at)
		CombatEvent.Kind.BLOCK:
			play_at(&"shield_block", at)


func _on_projectile(event: ProjectileEvent) -> void:
	var at: Vector3 = _meters(event.x, event.y, event.z)
	match event.kind:
		ProjectileEvent.Kind.LAUNCH:
			var shooter: Unit = _world.get_unit(event.unit_id)
			var sound: StringName = _launch_sound(event.type_index)
			if shooter != null and sound != &"":
				play_at(sound, _meters(shooter.x, shooter.y, shooter.z))
		ProjectileEvent.Kind.STICK, ProjectileEvent.Kind.HIT:
			play_at(&"arrow_impact", at)
		ProjectileEvent.Kind.BOUNCE, ProjectileEvent.Kind.DROP:
			play_at(&"grenade_bounce", at)
		ProjectileEvent.Kind.EXPLODE:
			play_at(&"explosion", at)
		ProjectileEvent.Kind.FIZZLE:
			play_at(&"gas_hiss", at)
		ProjectileEvent.Kind.IGNITE:
			play_at(&"fire_ignite", at)
		ProjectileEvent.Kind.BOLT:
			play_at(&"lightning", at)
		ProjectileEvent.Kind.CANT_REACH:
			play_ui(&"order_deny")
		ProjectileEvent.Kind.PICK_UP:
			play_at(&"ui_click", at)


# A bow for arrows, a toss for anything thrown; nothing for lightning, a
# Blightbag's burst or a herb, whose own events have their sounds.
func _launch_sound(type_index: int) -> StringName:
	if _world.catalog == null or type_index < 0 or type_index >= _world.catalog.projectile_types.size():
		return &""
	return LAUNCH_SOUNDS.get(_world.catalog.projectile_types[type_index].id, &"")


func _free_voice() -> AudioStreamPlayer3D:
	for k: int in VOICES:
		var voice: AudioStreamPlayer3D = _voices[(_next_voice + k) % VOICES]
		if not voice.playing:
			_next_voice = (_next_voice + k + 1) % VOICES
			return voice
	# All busy: take the one whose turn it is, the oldest started.
	var oldest: AudioStreamPlayer3D = _voices[_next_voice]
	_next_voice = (_next_voice + 1) % VOICES
	return oldest


static func _meters(x: int, y: int, z: int) -> Vector3:
	return Vector3(x, y, z) / float(World.UNITS_PER_METER)
