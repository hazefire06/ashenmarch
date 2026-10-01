class_name Weather
extends RefCounted
## Rain, snow, and wind, plus what they leave on the ground: snow cover and
## wetness. World.step() calls update() right after the tick's commands, so a
## change takes effect for the tick it is scheduled at.
##
## Changes come from SetWeatherCommand (a mission's WeatherSchedule, a debug
## key) or, later, mission triggers, all through change_to(). Each ramps
## linearly from where the weather is to the new values over ramp_ticks, in
## integers, with exact endpoints.
##
## What reads it:
## - ProjectileSystem: burning projectiles fizzle more in rain and snow, and
##   on snow-covered ground.
## - Fire: rain puts burning cells out; rain, wet ground, and snow cover slow
##   the spread.
## - The view: precipitation, wind drift, wet and snowy ground tints.
## Wind is visual only: nothing in the sim reads it.
##
## Intensities, cover, and wetness are permille (0..1000). Cover and wetness
## are kept in parts per million so slow build-up and fading are exact per
## tick. No randomness.

const PERMILLE: int = 1000
const PPM: int = 1_000_000
## mm/s either way along each axis (a 180 km/h gale). Wind is clamped to it,
## so a ramp's products can't overflow whatever the data says.
const MAX_WIND: int = 50_000
## Ticks of full snow from bare ground to fully covered (about 67 s). Lighter
## snow covers in proportion.
const SNOW_COVER_TICKS: int = 2000
## Ticks without snow for full cover to melt away (about 167 s).
const SNOW_MELT_TICKS: int = 5000
## Ticks of full rain from dry ground to soaked (about 33 s).
const SOAK_TICKS: int = 1000
## Ticks without rain for soaked ground to dry (about 133 s).
const DRY_TICKS: int = 4000

## Precipitation intensity, permille.
var rain: int = 0
var snow: int = 0
## Wind, mm/s along x and z. Visual only.
var wind_x: int = 0
var wind_z: int = 0
var snow_cover_ppm: int = 0
var wetness_ppm: int = 0

## The ramp in progress: values (rain, snow, wind_x, wind_z) at its start
## and its end, the tick it started, and its length.
var _from: PackedInt64Array = PackedInt64Array([0, 0, 0, 0])
var _to: PackedInt64Array = PackedInt64Array([0, 0, 0, 0])
var _ramp_start: int = 0
var _ramp_ticks: int = 0


## Starts ramping from wherever the weather is at start_tick to the given
## values, reaching them at start_tick + ramp_ticks (0 is immediate).
## snow_cover_permille >= 0 also sets the snow on the ground outright, for a
## map that starts white; -1 leaves it alone.
func change_to(
	start_tick: int, to_rain: int, to_snow: int, to_wind_x: int, to_wind_z: int,
	ramp_ticks: int, snow_cover_permille: int = -1
) -> void:
	_from = _values_at(start_tick)
	_to = PackedInt64Array([
		clampi(to_rain, 0, PERMILLE), clampi(to_snow, 0, PERMILLE),
		clampi(to_wind_x, -MAX_WIND, MAX_WIND), clampi(to_wind_z, -MAX_WIND, MAX_WIND),
	])
	_ramp_start = start_tick
	_ramp_ticks = maxi(0, ramp_ticks)
	if snow_cover_permille >= 0:
		snow_cover_ppm = mini(snow_cover_permille, PERMILLE) * (PPM / PERMILLE)


## Advances the ramp to this tick, then lets the ground respond: snow builds
## cover and rain soaks it while they fall; cover melts and the ground dries
## while they don't.
func update(tick: int) -> void:
	var now: PackedInt64Array = _values_at(tick)
	rain = now[0]
	snow = now[1]
	wind_x = now[2]
	wind_z = now[3]
	if snow > 0:
		snow_cover_ppm = mini(PPM, snow_cover_ppm + snow * (PPM / SNOW_COVER_TICKS) / PERMILLE)
	else:
		snow_cover_ppm = maxi(0, snow_cover_ppm - PPM / SNOW_MELT_TICKS)
	if rain > 0:
		wetness_ppm = mini(PPM, wetness_ppm + rain * (PPM / SOAK_TICKS) / PERMILLE)
	else:
		wetness_ppm = maxi(0, wetness_ppm - PPM / DRY_TICKS)


## Snow on the ground, permille.
func snow_cover() -> int:
	return snow_cover_ppm / (PPM / PERMILLE)


## How wet the ground is, permille.
func wetness() -> int:
	return wetness_ppm / (PPM / PERMILLE)


func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = PackedInt64Array([
		rain, snow, wind_x, wind_z, snow_cover_ppm, wetness_ppm, _ramp_start, _ramp_ticks,
	])
	fields.append_array(_from)
	fields.append_array(_to)
	return fields


# The ramp's values at tick: its start values before it, its end values
# from start + length on, linear (rounded) in between.
func _values_at(tick: int) -> PackedInt64Array:
	var elapsed: int = tick - _ramp_start
	if elapsed >= _ramp_ticks:
		return _to.duplicate()
	if elapsed <= 0:
		return _from.duplicate()
	var out: PackedInt64Array = PackedInt64Array()
	for k: int in _from.size():
		out.append(_from[k] + FixedMath.div_round((_to[k] - _from[k]) * elapsed, _ramp_ticks))
	return out
