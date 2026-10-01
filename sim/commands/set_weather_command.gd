class_name SetWeatherCommand
extends SimCommand
## Starts the weather ramping to new values (Weather.change_to). Enqueued from
## a mission's WeatherSchedule at mission start, or by the debug weather key.

var rain: int
var snow: int
var wind_x: int
var wind_z: int
var ramp_ticks: int
## Permille to set the snow on the ground outright; -1 leaves it.
var snow_cover: int


func _init(
	at_tick: int, to_rain: int, to_snow: int, to_wind_x: int, to_wind_z: int,
	ramp: int, cover: int = -1
) -> void:
	super(at_tick)
	rain = to_rain
	snow = to_snow
	wind_x = to_wind_x
	wind_z = to_wind_z
	ramp_ticks = ramp
	snow_cover = cover


func apply(world: World) -> void:
	world.weather.change_to(world.tick, rain, snow, wind_x, wind_z, ramp_ticks, snow_cover)
