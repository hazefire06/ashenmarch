class_name Ambience
extends Node
## The beds under a battle and the march of the units on it: outdoor air, rain,
## snow, fire, water and gas near the camera's focus, and one of four marching
## loops under the visible living movers, by the ground they cross. Every loop is its
## own player on its cue's bus; each eases toward its level, and stops when it
## has faded out, so a still, clear field costs nothing. A loop with no stream
## yet stays silent (the bank warns once).

## Burning cells at which the fire bed is at full level.
const FIRE_FULL_CELLS: int = 150
## Fire counts within this many metres of the focus.
const FIRE_RADIUS: float = 50.0
## Gas clouds count within this many metres of the focus (plus their own radius).
const GAS_RADIUS: float = 30.0
## The water sample grid: WATER_GRID x WATER_GRID points, this far apart.
const WATER_GRID: int = 7
const WATER_SPACING: float = 5.0
## Marching counts the visible movers within this many metres of the focus.
const MARCH_RADIUS: float = 40.0
## Movers at which the march is at full level.
const MARCH_FULL: float = 12.0
## How fast a bed eases toward its level, per second.
const EASE_RATE: float = 1.5
## The march eases faster: it follows the boots, silent about a second after the last step.
const MARCH_EASE_RATE: float = 4.0
const SILENT_DB: float = -60.0
const M: float = 1000.0

const BEDS: Array[StringName] = [
	&"bed_outdoor", &"bed_rain", &"bed_snow", &"bed_fire", &"bed_water", &"bed_gas"
]
const MARCHES: Array[StringName] = [&"march_grass", &"march_sand", &"march_rock", &"march_water"]

var _world: World
var _camera: RtsCamera
var _bank: SoundBank
var _viewer: UnitType.Faction = UnitType.Faction.LIGHT
var _players: Dictionary[StringName, AudioStreamPlayer] = {}
var _levels: Dictionary[StringName, float] = {}
var _targets: Dictionary[StringName, float] = {}
## Set by MainView: while paused the levels hold (loops keep sounding, easing stops).
var paused: bool = false


func setup(world: World, camera: RtsCamera, bank: SoundBank = SoundBank.shared()) -> void:
	_world = world
	_camera = camera
	_bank = bank
	for id: StringName in BEDS + MARCHES:
		_players[id] = _loop(id)
		_levels[id] = 0.0
		_targets[id] = 0.0
	after_step()


## The side whose eyes these are; movers it can't see make no march.
func set_viewer(side: UnitType.Faction) -> void:
	_viewer = side
	if _world != null:
		after_step()


## Reads the weather, the fire, the water, the gas and the movers around the
## focus. Call once per step, after it.
func after_step() -> void:
	var weather: Weather = _world.weather
	var rain: float = clampf(weather.rain / 1000.0, 0.0, 1.0)
	_targets[&"bed_outdoor"] = 1.0 - 0.6 * rain
	_targets[&"bed_rain"] = rain
	_targets[&"bed_snow"] = clampf(weather.snow / 1000.0, 0.0, 1.0)
	var focus: Vector2 = _focus()
	_targets[&"bed_fire"] = clampf(float(_burning_near(focus)) / FIRE_FULL_CELLS, 0.0, 1.0)
	_targets[&"bed_water"] = _water_near(focus)
	_targets[&"bed_gas"] = _gas_near(focus)
	_march(focus)


## Each loop's target level, 0..1, by cue id. For tests.
func targets() -> Dictionary[StringName, float]:
	return _targets


func _process(delta: float) -> void:
	if _world == null or paused:
		return
	var bed_blend: float = 1.0 - exp(-EASE_RATE * delta)
	var march_blend: float = 1.0 - exp(-MARCH_EASE_RATE * delta)
	for id: StringName in _players:
		_levels[id] = lerpf(_levels[id], _targets[id], march_blend if id in MARCHES else bed_blend)
		_drive(_players[id], _levels[id], id)


func _drive(player: AudioStreamPlayer, level: float, sound: StringName) -> void:
	if level < 0.01 or player.stream == null:
		if player.playing:
			player.stop()
		return
	var cue: SoundCue = _bank.cue(sound)
	player.volume_db = maxf((cue.level_db if cue != null else 0.0) + linear_to_db(level), SILENT_DB)
	if not player.playing:
		player.play()


func _loop(sound: StringName) -> AudioStreamPlayer:
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.stream = _bank.pick(sound, RandomNumberGenerator.new())
	var cue: SoundCue = _bank.cue(sound)
	if cue != null:
		player.bus = cue.bus
		player.playback_type = cue.playback
	else:
		player.bus = &"Ambient"
	add_child(player)
	return player


## The camera's focus on the ground, in metres: x, z.
func _focus() -> Vector2:
	if _camera == null:
		return Vector2.ZERO
	return Vector2(_camera.focus.x, _camera.focus.z)


func _burning_near(focus: Vector2) -> int:
	if _world.fire == null:
		return 0
	var terrain: Terrain = _world.terrain
	var count: int = 0
	for k: int in _world.fire.burn_end:
		var at: Vector2 = Vector2(k % terrain.size_x, k / terrain.size_x) * terrain.cell_size / M
		if at.distance_to(focus) <= FIRE_RADIUS:
			count += 1
	return count


## Twice the share of wet samples in a coarse grid round the focus, capped at 1.
func _water_near(focus: Vector2) -> float:
	var wet: int = 0
	var half: int = WATER_GRID / 2
	for i: int in WATER_GRID:
		for j: int in WATER_GRID:
			var x: int = roundi((focus.x + (i - half) * WATER_SPACING) * M)
			var z: int = roundi((focus.y + (j - half) * WATER_SPACING) * M)
			if _world.terrain.water_depth_at(x, z) >= 1:
				wet += 1
	return minf(2.0 * wet / (WATER_GRID * WATER_GRID), 1.0)


func _gas_near(focus: Vector2) -> float:
	var near: int = 0
	for cloud: GasCloud in _world.clouds:
		var at: Vector2 = Vector2(cloud.x, cloud.z) / M
		if at.distance_to(focus) <= GAS_RADIUS + cloud.radius / M:
			near += 1
	return mini(near, 2) / 2.0


## The march: how many visible living movers are near, and what they walk on.
## The loops are men in boots, so the undead make none. The level is the share
## of a full column, not its square root: the loop is a group, and one or two
## stragglers reaching their spots shouldn't sound like a squad still marching.
func _march(focus: Vector2) -> void:
	var count: int = 0
	var votes: Dictionary[StringName, int] = {}
	for unit: Unit in _world.units:
		if unit.state != Unit.State.MOVING or not unit.is_alive():
			continue
		if unit.type.nature != UnitType.Nature.LIVING:
			continue
		if Vector2(unit.x, unit.z).distance_to(focus * M) > MARCH_RADIUS * M:
			continue
		if not Visibility.seen_by(_world, unit, _viewer):
			continue
		count += 1
		var ground: StringName = _ground_under(unit)
		votes[ground] = votes.get(ground, 0) + 1
	var level: float = minf(count / MARCH_FULL, 1.0)
	var best: StringName = &""
	var best_votes: int = 0
	for id: StringName in MARCHES:
		if votes.get(id, 0) > best_votes:
			best = id
			best_votes = votes[id]
	for id: StringName in MARCHES:
		_targets[id] = level if id == best else 0.0


func _ground_under(unit: Unit) -> StringName:
	var terrain: Terrain = _world.terrain
	if terrain.water_depth_at(unit.x, unit.z) >= 1:
		return &"march_water"
	match terrain.ground_at(unit.x, unit.z):
		Terrain.Ground.SAND:
			return &"march_sand"
		Terrain.Ground.ROCK:
			return &"march_rock"
	return &"march_grass"
