class_name DebugWeather
extends RefCounted
## F6 (debug, like F9): cycles clear, rain, heavy rain, snow. The sim only
## changes through a SetWeatherCommand at the current tick, ramped over
## RAMP_TICKS, like any other order, so the mission's own weather change (a
## trigger's SET_WEATHER) takes over again when it fires.

## Ticks each change takes to ramp in.
const RAMP_TICKS: int = 90
## name, rain, snow (permille), wind x, wind z (mm/s).
const PRESETS: Array[Array] = [
	["clear", 0, 0, 1500, 500],
	["rain", 600, 0, 3000, 1000],
	["heavy rain", 1000, 0, 5000, 1500],
	["snow", 0, 800, 2000, -1000],
]


## The preset after index, wrapping.
static func next(index: int) -> int:
	return (index + 1) % PRESETS.size()


static func name_of(index: int) -> String:
	return PRESETS[index][0]


## The command that turns the weather to preset index from tick on.
static func command(index: int, tick: int) -> SetWeatherCommand:
	var p: Array = PRESETS[index]
	return SetWeatherCommand.new(tick, p[1], p[2], p[3], p[4], RAMP_TICKS)
