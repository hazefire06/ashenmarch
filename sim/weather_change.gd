class_name WeatherChange
extends Resource
## One entry of a WeatherSchedule: at tick, start ramping to these values
## over ramp_ticks. See Weather.change_to().
##
## Unlike unit stats, 0 is a meaningful value for every field here (clear,
## calm, now), so defaults are 0 rather than invalid. snow_cover defaults to
## -1, which leaves the snow on the ground as it is.

@export var tick: int = 0
## Permille, 0..1000.
@export var rain: int = 0
@export var snow: int = 0
## mm/s. Visual only.
@export var wind_x: int = 0
@export var wind_z: int = 0
@export var ramp_ticks: int = 0
## Permille 0..1000 to set the snow on the ground outright; -1 leaves it.
@export var snow_cover: int = -1


## Problems with this entry, or an empty array. where names it in messages.
func validate(where: String) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if tick < 0:
		errors.append("%s: tick can't be negative" % where)
	if rain < 0 or rain > Weather.PERMILLE:
		errors.append("%s: rain must be 0..1000" % where)
	if snow < 0 or snow > Weather.PERMILLE:
		errors.append("%s: snow must be 0..1000" % where)
	if ramp_ticks < 0:
		errors.append("%s: ramp_ticks can't be negative" % where)
	if snow_cover < -1 or snow_cover > Weather.PERMILLE:
		errors.append("%s: snow_cover must be -1 (keep) or 0..1000" % where)
	return errors


func to_command() -> SetWeatherCommand:
	return SetWeatherCommand.new(tick, rain, snow, wind_x, wind_z, ramp_ticks, snow_cover)
