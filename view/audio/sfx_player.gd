class_name SfxPlayer
extends Node3D
## Plays the battlefield's sounds from what the sim reports each tick: blows,
## blocks and deaths (World.combat_events), bows, impacts, bounces, blasts,
## fires and lightning (World.projectile_events), gas clouds as they appear,
## and the acknowledgement of the player's orders. Positional sounds come from
## a fixed pool of VOICES players on the Effects bus; the order sounds from
## one 2D player on the Interface bus. Every cue is the sound bank's, chosen
## by the sound map; a sound a unit makes plays only if the viewer's side can
## see that unit (Visibility.seen_by), so a Husk lying in deep water is silent.
##
## A big fight reports far more than can usefully be heard, so each sound
## plays at most MAX_PER_TICK times a tick and at most MAX_TICK_TOTAL sounds
## start in all; sounds farther than CULL_DISTANCE from the camera's focus
## aren't played. When every voice is busy the one that started first is
## taken. Each cue also has its own cap on voices playing at once. View only:
## its RNG, which tests can seed, is never the sim's.

const VOICES: int = 24
const MAX_PER_TICK: int = 3
const MAX_TICK_TOTAL: int = 8
const CULL_DISTANCE: float = 160.0
## Melee sounds only for blows between units this close (meters): further
## apart, it was an arrow or a blast, whose own sounds play.
const MELEE_REACH: float = 4.0
## A blast at least this large (milli-units) is the large one: between the
## grenade's 5000 and the satchel's 7000.
const EXPLOSION_LARGE_RADIUS: int = 6000
## A bounce at this speed (um/tick) or faster is at full volume.
const BOUNCE_FULL_SPEED: int = 300
## Undead groan when seen within this many meters of the focus, at most once
## per GROAN_GAP_TICKS, with this chance each tick once the gap has passed.
const GROAN_RADIUS: float = 40.0
const GROAN_GAP_TICKS: int = 90
const GROAN_CHANCE: float = 0.03
## Tuned for a listener on the ground at the focus, not up with the camera.
const UNIT_SIZE: float = 12.0

## Cue ids this class names itself; the rest come from the sound map.
const SWING_PREFIX: String = "swing_"
const HIT_PREFIX: String = "hit_"
const BLOCK_SHIELD: StringName = &"block_shield"
const HEAL: StringName = &"heal"
const HEAL_SEAR: StringName = &"heal_sear"
const ARROW_SPLASH: StringName = &"arrow_splash"
const EXPLOSION_SMALL: StringName = &"explosion_small"
const EXPLOSION_LARGE: StringName = &"explosion_large"
const EXPLOSION_WATER: StringName = &"explosion_water"
const GAS_BURST: StringName = &"gas_burst"
const FIZZLE_HISS: StringName = &"fizzle_hiss"
const FIZZLE_WATER: StringName = &"fizzle_water"
const SATCHEL_THUD: StringName = &"satchel_thud"
const FIRE_WHOOMP: StringName = &"fire_whoomp"
const GRAB: StringName = &"grab"
const THUNDER: StringName = &"thunder"
const UI_DENY: StringName = &"ui_deny"
const GAS_RELEASE: StringName = &"gas_release"
const ORDER_ACK: StringName = &"order_ack"
## The projectile whose burst is a gas cloud, not a blast.
const BLIGHT_BURST: StringName = &"blight_burst"
## Every fixed cue above, for the test that checks the bank declares them.
const NAMED_CUES: Array[StringName] = [
	BLOCK_SHIELD, HEAL, HEAL_SEAR, ARROW_SPLASH, EXPLOSION_SMALL, EXPLOSION_LARGE,
	EXPLOSION_WATER, GAS_BURST, FIZZLE_HISS, FIZZLE_WATER, SATCHEL_THUD, FIRE_WHOOMP,
	GRAB, THUNDER, UI_DENY, GAS_RELEASE, ORDER_ACK,
]

## Plays nothing while false (the audio budget's audio=0).
var enabled: bool = true
## The view's own RNG for variants, pitch and groans; never the sim's.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## The bank every sound comes from, and who makes which.
var bank: SoundBank = null
var map: SoundMap = null

var _world: World
var _camera: RtsCamera
var _listener: AudioListener3D
var _viewer: UnitType.Faction = UnitType.Faction.LIGHT
var _voices: Array[AudioStreamPlayer3D] = []
## The cue each voice last started, parallel to _voices.
var _voice_cue: Array[StringName] = []
var _next_voice: int = 0
var _interface: AudioStreamPlayer
var _counts: Dictionary[StringName, int] = {}
var _started: int = 0
var _played: Array[Dictionary] = []
var _seen_clouds: Dictionary[int, bool] = {}
var _last_groan: int = -GROAN_GAP_TICKS


func setup(
	world: World, camera: RtsCamera, sound_bank: SoundBank = SoundBank.shared(),
	sound_map: SoundMap = SoundMap.shared()
) -> void:
	_world = world
	_camera = camera
	bank = sound_bank
	map = sound_map
	for i: int in VOICES:
		var voice: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		voice.bus = &"Effects"
		voice.unit_size = UNIT_SIZE
		voice.max_distance = CULL_DISTANCE * 2.0
		add_child(voice)
		_voices.append(voice)
		_voice_cue.append(&"")
	_interface = AudioStreamPlayer.new()
	_interface.bus = &"Interface"
	add_child(_interface)
	_listener = AudioListener3D.new()
	_listener.name = "Listener"
	add_child(_listener)
	_listener.make_current()
	for cloud: GasCloud in world.clouds:
		_seen_clouds[cloud.id] = true


## The listener stands at the camera's ground focus, turned as the camera is,
## so loudness follows distance across the ground, not the zoom.
func _process(_delta: float) -> void:
	if _camera == null or _camera.get_camera() == null or _listener == null:
		return
	_listener.global_position = _camera.focus
	_listener.global_basis = Basis(Vector3.UP, _camera.get_camera().global_rotation.y)


## The side whose eyes and ears these are; units it can't see make no sound.
func set_viewer(side: UnitType.Faction) -> void:
	_viewer = side


func viewer() -> UnitType.Faction:
	return _viewer


## Restarts the view RNG, so tests (and replays of the view) pick the same variants.
func seed(value: int) -> void:
	rng.seed = value


## Reads the last step's events. Call once per step, after it.
func after_step() -> void:
	_counts.clear()
	_started = 0
	_played.clear()
	for event: CombatEvent in _world.combat_events:
		_on_combat(event)
	for event: ProjectileEvent in _world.projectile_events:
		_on_projectile(event)
	for cloud: GasCloud in _world.clouds:
		if not _seen_clouds.has(cloud.id):
			_seen_clouds[cloud.id] = true
			play_at(GAS_RELEASE, _meters(cloud.x, cloud.y, cloud.z))
	_groan()


## The player's order was sent.
func acknowledge() -> void:
	play_ui(ORDER_ACK)


## How many sounds this tick has started; for tests.
func started_this_tick() -> int:
	return _started


## Every cue this tick played, in order, each {"cue": StringName, "db": float}
## (the level before pitch jitter); for tests.
func played_this_tick() -> Array[Dictionary]:
	return _played


## Plays `cue` at `at` (meters), within the caps and the cull distance, `gain_db`
## louder than the cue's own level. A cue with no stream plays nothing and
## costs nothing. Returns whether it played.
func play_at(cue: StringName, at: Vector3, gain_db: float = 0.0) -> bool:
	if not enabled or not bank.has(cue):
		return false
	if _started >= MAX_TICK_TOTAL or _counts.get(cue, 0) >= MAX_PER_TICK:
		return false
	if _camera != null:
		var focus: Vector3 = _camera.focus
		if Vector2(at.x - focus.x, at.z - focus.z).length() > CULL_DISTANCE:
			return false
	var sound: SoundCue = bank.cue(cue)
	if _playing(cue) >= sound.max_voices:
		return false
	var slot: int = _free_voice()
	var voice: AudioStreamPlayer3D = _voices[slot]
	voice.stream = bank.pick(cue, rng)
	voice.bus = sound.bus
	voice.volume_db = sound.level_db + gain_db
	voice.pitch_scale = 1.0 + rng.randf_range(-sound.pitch_spread, sound.pitch_spread)
	voice.playback_type = sound.playback
	voice.position = at
	voice.play()
	_voice_cue[slot] = cue
	_counts[cue] = _counts.get(cue, 0) + 1
	_started += 1
	_played.append({"cue": cue, "db": sound.level_db + gain_db})
	return true


## Plays `cue` unplaced, on the cue's own bus.
func play_ui(cue: StringName) -> void:
	if not enabled or not bank.has(cue):
		return
	var sound: SoundCue = bank.cue(cue)
	_interface.stream = bank.pick(cue, rng)
	_interface.bus = sound.bus
	_interface.volume_db = sound.level_db
	_interface.play()
	_played.append({"cue": cue, "db": sound.level_db})


func _on_combat(event: CombatEvent) -> void:
	var target: Unit = _world.get_unit(event.target_id)
	if target == null:
		return
	var target_at: Vector3 = _meters(target.x, target.y, target.z)
	var attacker: Unit = _world.get_unit(event.attacker_id)
	match event.kind:
		CombatEvent.Kind.SWING, CombatEvent.Kind.MISS:
			if attacker != null and _close(attacker, target) and _heard(attacker):
				var sound: UnitSound = map.for_unit(attacker.type)
				if sound != null:
					play_at(StringName(SWING_PREFIX + sound.weapon), _meters(attacker.x, attacker.y, attacker.z))
		CombatEvent.Kind.HIT:
			if attacker != null and _close(attacker, target) and _heard(target):
				_play_hit(target, target_at)
		CombatEvent.Kind.BLOCK:
			if attacker != null and _close(attacker, target) and _heard(target):
				play_at(BLOCK_SHIELD, target_at)
		CombatEvent.Kind.KILL:
			if not _heard(target):
				return
			if attacker != null and _close(attacker, target):
				_play_hit(target, target_at)
			play_at(map.death_cue(target.type, bank), target_at)
		CombatEvent.Kind.HEAL:
			if _heard(target):
				var undead: bool = target.type.nature == UnitType.Nature.UNDEAD
				play_at(HEAL_SEAR if undead else HEAL, target_at)


func _on_projectile(event: ProjectileEvent) -> void:
	var at: Vector3 = _meters(event.x, event.y, event.z)
	var sound: ProjectileSound = _projectile_sound(event.type_index)
	match event.kind:
		ProjectileEvent.Kind.LAUNCH:
			var shooter: Unit = _world.get_unit(event.unit_id)
			if shooter != null and shooter.is_alive() and sound != null and _heard(shooter):
				play_at(sound.launch, _meters(shooter.x, shooter.y, shooter.z))
		ProjectileEvent.Kind.STICK:
			if event.depth > 0:
				play_at(ARROW_SPLASH, at)
			elif sound != null:
				play_at(sound.stick, at)
		ProjectileEvent.Kind.HIT:
			if sound != null:
				play_at(sound.hit, at)
		ProjectileEvent.Kind.BOUNCE:
			if sound != null:
				var gain: float = linear_to_db(clampf(float(event.speed) / BOUNCE_FULL_SPEED, 0.25, 1.0))
				play_at(sound.bounce, at, gain)
		ProjectileEvent.Kind.EXPLODE:
			play_at(_explosion_cue(event), at)
		ProjectileEvent.Kind.FIZZLE:
			play_at(FIZZLE_WATER if event.depth > 0 else FIZZLE_HISS, at)
		ProjectileEvent.Kind.DROP:
			play_at(SATCHEL_THUD, at)
		ProjectileEvent.Kind.IGNITE:
			play_at(FIRE_WHOOMP, at)
		ProjectileEvent.Kind.BOLT:
			play_at(THUNDER, at)
		ProjectileEvent.Kind.CANT_REACH:
			var unit: Unit = _world.get_unit(event.unit_id)
			if unit != null and unit.faction == _viewer:
				play_ui(UI_DENY)
		ProjectileEvent.Kind.PICK_UP:
			var unit: Unit = _world.get_unit(event.unit_id)
			if unit != null and _heard(unit):
				play_at(GRAB, at)


func _explosion_cue(event: ProjectileEvent) -> StringName:
	var catalog: UnitCatalog = _world.catalog
	if catalog != null and event.type_index >= 0 and event.type_index < catalog.projectile_types.size():
		if catalog.projectile_types[event.type_index].id == BLIGHT_BURST:
			return GAS_BURST
	if _world.terrain.water_depth_at(event.x, event.z) > 0:
		return EXPLOSION_WATER
	return EXPLOSION_LARGE if event.radius >= EXPLOSION_LARGE_RADIUS else EXPLOSION_SMALL


func _play_hit(target: Unit, at: Vector3) -> void:
	var sound: UnitSound = map.for_unit(target.type)
	if sound != null:
		play_at(StringName(HIT_PREFIX + sound.body), at)


## One seen undead near the focus groans now and then.
func _groan() -> void:
	if _camera == null or _world.tick - _last_groan < GROAN_GAP_TICKS:
		return
	if rng.randf() >= GROAN_CHANCE:
		return
	var focus: Vector3 = _camera.focus
	var groaners: Array[Unit] = []
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.type.nature != UnitType.Nature.UNDEAD:
			continue
		var at: Vector3 = _meters(unit.x, unit.y, unit.z)
		if Vector2(at.x - focus.x, at.z - focus.z).length() > GROAN_RADIUS:
			continue
		if _heard(unit) and map.groan_cue(unit.type, bank) != &"":
			groaners.append(unit)
	if groaners.is_empty():
		return
	var chosen: Unit = groaners[rng.randi_range(0, groaners.size() - 1)]
	if play_at(map.groan_cue(chosen.type, bank), _meters(chosen.x, chosen.y, chosen.z)):
		_last_groan = _world.tick


func _heard(unit: Unit) -> bool:
	return Visibility.seen_by(_world, unit, _viewer)


static func _close(a: Unit, b: Unit) -> bool:
	return Vector2(a.x - b.x, a.z - b.z).length() / World.UNITS_PER_METER <= MELEE_REACH


func _projectile_sound(type_index: int) -> ProjectileSound:
	var catalog: UnitCatalog = _world.catalog
	if catalog == null or type_index < 0 or type_index >= catalog.projectile_types.size():
		return null
	return map.for_projectile(catalog.projectile_types[type_index].id)


## How many voices are playing this cue now.
func _playing(cue: StringName) -> int:
	var n: int = 0
	for i: int in VOICES:
		if _voice_cue[i] == cue and _voices[i].playing:
			n += 1
	return n


## A voice not playing, else the one whose turn it is, the oldest started.
func _free_voice() -> int:
	for k: int in VOICES:
		var slot: int = (_next_voice + k) % VOICES
		if not _voices[slot].playing:
			_next_voice = (slot + 1) % VOICES
			return slot
	var oldest: int = _next_voice
	_next_voice = (_next_voice + 1) % VOICES
	return oldest


static func _meters(x: int, y: int, z: int) -> Vector3:
	return Vector3(x, y, z) / float(World.UNITS_PER_METER)
