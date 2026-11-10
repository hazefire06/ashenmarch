class_name Music
extends Node
## The music under a battle: a calm layer and a combat layer, both streamed,
## started together and looping, so they stay in step; only their volumes move.
## The fighting the viewer can see decides the mix, with hysteresis so a skirmish
## flickering at the threshold doesn't pump the music. A layer with no stream yet
## stays silent (the bank warns once).

## Combat comes in at this many visible fighters held for COMBAT_IN_S, fading in
## over FADE_IN_S.
const COMBAT_IN_UNITS: int = 4
const COMBAT_IN_S: float = 1.5
const FADE_IN_S: float = 2.0
## It goes out at this many or fewer held for COMBAT_OUT_S, fading out over FADE_OUT_S.
const COMBAT_OUT_UNITS: int = 1
const COMBAT_OUT_S: float = 10.0
const FADE_OUT_S: float = 6.0
const SILENT_DB: float = -60.0

var _world: World
var _bank: SoundBank
var _pair: MusicPair
var _viewer: UnitType.Faction = UnitType.Faction.LIGHT
var _calm: AudioStreamPlayer
var _combat: AudioStreamPlayer
var _fighters: int = 0
var _in_combat: bool = false
## Seconds the fighting has held above the in-threshold, or below the out-threshold.
var _held_s: float = 0.0
## The combat layer's level, 0..1; calm is 1 minus it.
var _combat_level: float = 0.0


func setup(world: World, pair: MusicPair, bank: SoundBank = SoundBank.shared()) -> void:
	_world = world
	_pair = pair
	_bank = bank
	_calm = _layer(pair.calm)
	_combat = _layer(pair.combat)
	# Together, so the two stay in step from the first sample.
	for player: AudioStreamPlayer in [_calm, _combat]:
		if player.stream != null:
			player.play()
	_drive()
	after_step()


## The side whose eyes these are; fighters it can't see don't count.
func set_viewer(side: UnitType.Faction) -> void:
	_viewer = side
	if _world != null:
		after_step()


## Counts the visible units that are fighting, either side. Call once per step, after it.
func after_step() -> void:
	var count: int = 0
	for unit: Unit in _world.units:
		if unit.state != Unit.State.ATTACKING and unit.state != Unit.State.SHOOTING:
			continue
		if unit.is_alive() and Visibility.seen_by(_world, unit, _viewer):
			count += 1
	_fighters = count


func in_combat() -> bool:
	return _in_combat


## The calm and combat levels, 0..1, as x and y.
func levels() -> Vector2:
	return Vector2(1.0 - _combat_level, _combat_level)


## Moves the hysteresis timers and the fades on by seconds.
func advance(seconds: float) -> void:
	if _in_combat:
		_held_s = _held_s + seconds if _fighters <= COMBAT_OUT_UNITS else 0.0
		if _held_s >= COMBAT_OUT_S:
			_in_combat = false
			_held_s = 0.0
	else:
		_held_s = _held_s + seconds if _fighters >= COMBAT_IN_UNITS else 0.0
		if _held_s >= COMBAT_IN_S:
			_in_combat = true
			_held_s = 0.0
	var rate: float = 1.0 / (FADE_IN_S if _in_combat else FADE_OUT_S)
	_combat_level = move_toward(_combat_level, 1.0 if _in_combat else 0.0, rate * seconds)
	_drive()


func _process(delta: float) -> void:
	if _world != null:
		advance(delta)


func _drive() -> void:
	_set_level(_calm, _pair.calm, 1.0 - _combat_level)
	_set_level(_combat, _pair.combat, _combat_level)


func _set_level(player: AudioStreamPlayer, sound: StringName, level: float) -> void:
	var cue: SoundCue = _bank.cue(sound)
	var base_db: float = cue.level_db if cue != null else 0.0
	player.volume_db = maxf(base_db + linear_to_db(maxf(level, 0.0)), SILENT_DB)


func _layer(sound: StringName) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = _bank.pick(sound, RandomNumberGenerator.new())
	var cue: SoundCue = _bank.cue(sound)
	if cue != null:
		player.bus = cue.bus
		player.playback_type = cue.playback
	else:
		player.bus = &"Music"
	add_child(player)
	return player
