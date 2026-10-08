class_name Ambience
extends Node
## The beds under a battle: rain as loud as the rain is heavy, and fire
## crackling as more of the ground burns. Two looping players on the Ambient
## bus; each eases toward its level, and stops when it has faded out, so a
## clear, unburnt field costs nothing.

## Burning cells at which the fire bed is at full level.
const FIRE_FULL_CELLS: int = 150
## How fast a bed eases toward its level, per second.
const EASE_RATE: float = 1.5
const SILENT_DB: float = -60.0

var _world: World
var _rain: AudioStreamPlayer
var _fire: AudioStreamPlayer
var _rain_level: float = 0.0
var _fire_level: float = 0.0
var _rain_target: float = 0.0
var _fire_target: float = 0.0


func setup(world: World) -> void:
	_world = world
	_rain = _bed(&"rain_loop")
	_fire = _bed(&"fire_loop")
	after_step()


## Reads the weather and the fire. Call once per step, after it.
func after_step() -> void:
	_rain_target = clampf(_world.weather.rain / 1000.0, 0.0, 1.0)
	var burning: int = _world.fire.burn_end.size() if _world.fire != null else 0
	_fire_target = clampf(float(burning) / FIRE_FULL_CELLS, 0.0, 1.0)


## The levels the beds are easing toward, 0..1: [rain, fire]. For tests.
func targets() -> Vector2:
	return Vector2(_rain_target, _fire_target)


func _process(delta: float) -> void:
	if _world == null:
		return
	var blend: float = 1.0 - exp(-EASE_RATE * delta)
	_rain_level = lerpf(_rain_level, _rain_target, blend)
	_fire_level = lerpf(_fire_level, _fire_target, blend)
	_drive(_rain, _rain_level, &"rain_loop")
	_drive(_fire, _fire_level, &"fire_loop")


func _drive(player: AudioStreamPlayer, level: float, sound: StringName) -> void:
	if level < 0.01:
		if player.playing:
			player.stop()
		return
	player.volume_db = maxf(SfxBank.level_db(sound) + linear_to_db(level), SILENT_DB)
	if not player.playing:
		player.play()


func _bed(sound: StringName) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = SfxBank.stream(sound)
	player.bus = &"Ambient"
	add_child(player)
	return player
