extends GutTest
## Weather: rain and snow intensity and wind, changed by commands (a mission's
## schedule, or a debug key) and ramped linearly in integers; snow cover and
## wetness that build up and fade; all of it in the state hash.

const FULL: int = 1000


func test_a_new_world_is_clear_and_still() -> void:
	var w: Weather = World.new(1).weather
	assert_eq([w.rain, w.snow, w.wind_x, w.wind_z, w.snow_cover(), w.wetness()], [0, 0, 0, 0, 0, 0])


func test_a_change_applies_at_the_start_of_its_tick() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(10, 800, 0, 0, 0, 0))
	_run(world, 10)
	assert_eq(world.weather.rain, 0, "not before tick 10")
	_run(world, 1)
	assert_eq(world.weather.rain, 800, "in effect for tick 10 itself")


func test_a_ramp_is_linear_with_exact_endpoints() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(0, FULL, 0, -3000, 700, 90))
	_run(world, 1)
	assert_eq(world.weather.rain, 0, "the ramp starts from where it was")
	_run(world, 45)
	assert_eq(world.weather.rain, 500, "halfway at tick 45")
	assert_eq(world.weather.wind_x, -1500)
	assert_eq(world.weather.wind_z, 350)
	_run(world, 44)
	assert_eq(world.weather.rain, 989, "tick 89")
	_run(world, 1)
	assert_eq([world.weather.rain, world.weather.wind_x, world.weather.wind_z], [FULL, -3000, 700], "exact at tick 90")
	_run(world, 100)
	assert_eq(world.weather.rain, FULL, "and stays")


func test_a_new_change_ramps_from_the_current_values() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(0, FULL, 0, 0, 0, 100))
	world.enqueue(SetWeatherCommand.new(50, 0, 600, 0, 0, 10))
	_run(world, 51)
	assert_eq(world.weather.rain, 500, "the new ramp starts at 500")
	assert_eq(world.weather.snow, 0)
	_run(world, 5)
	assert_eq([world.weather.rain, world.weather.snow], [250, 300])
	_run(world, 5)
	assert_eq([world.weather.rain, world.weather.snow], [0, 600])


func test_snow_covers_the_ground_then_melts_once_it_stops() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(0, 0, FULL, 0, 0, 0))
	_run(world, Weather.SNOW_COVER_TICKS / 2)
	assert_almost_eq(world.weather.snow_cover(), 500, 2, "half covered after half the time")
	_run(world, Weather.SNOW_COVER_TICKS / 2 + 2)
	assert_eq(world.weather.snow_cover(), FULL, "fully covered")
	world.enqueue(SetWeatherCommand.new(world.tick, 0, 0, 0, 0, 0))
	_run(world, Weather.SNOW_MELT_TICKS / 2)
	assert_almost_eq(world.weather.snow_cover(), 500, 2, "half melted")
	_run(world, Weather.SNOW_MELT_TICKS / 2 + 2)
	assert_eq(world.weather.snow_cover(), 0)


func test_light_snow_covers_more_slowly() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(0, 0, 250, 0, 0, 0))
	_run(world, Weather.SNOW_COVER_TICKS / 2)
	assert_almost_eq(world.weather.snow_cover(), 125, 2)


func test_rain_soaks_the_ground_then_it_dries() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(0, FULL, 0, 0, 0, 0))
	_run(world, Weather.SOAK_TICKS + 2)
	assert_eq(world.weather.wetness(), FULL)
	world.enqueue(SetWeatherCommand.new(world.tick, 0, 0, 0, 0, 0))
	_run(world, Weather.DRY_TICKS / 2)
	assert_almost_eq(world.weather.wetness(), 500, 2, "half dry")
	_run(world, Weather.DRY_TICKS / 2 + 2)
	assert_eq(world.weather.wetness(), 0)


func test_snow_cover_can_be_set_outright() -> void:
	var world: World = World.new(1)
	world.enqueue(SetWeatherCommand.new(0, 0, 0, 0, 0, 0, 600))
	_run(world, 1)
	assert_almost_eq(world.weather.snow_cover(), 600, 1, "a map that starts white")
	world.enqueue(SetWeatherCommand.new(1, 0, 0, 0, 0, 0))
	_run(world, 1)
	assert_almost_eq(world.weather.snow_cover(), 600, 1, "-1 leaves it alone (less a tick of melt)")


func test_a_schedule_becomes_commands_that_drive_the_weather() -> void:
	var schedule: WeatherSchedule = _schedule([
		_change(0, 0, 0, 0, 0, -1),
		_change(30, 700, 0, 300, 10, -1),
		_change(90, 0, 0, 0, 30, -1),
	])
	assert_eq(schedule.validate(), PackedStringArray())
	var world: World = World.new(1)
	for command: SetWeatherCommand in schedule.commands():
		assert_true(world.enqueue(command))
	_run(world, 41)
	assert_eq([world.weather.rain, world.weather.wind_x], [700, 300])
	_run(world, 80)
	assert_eq(world.weather.rain, 0, "and it clears again")


func test_schedule_validation() -> void:
	assert_eq(_schedule([]).validate(), PackedStringArray(), "an empty schedule is clear weather")
	assert_true(_has_error(_schedule([_change(30, 0, 0, 0, 0, -1), _change(30, 0, 0, 0, 0, -1)]), "ascending"))
	assert_true(_has_error(_schedule([_change(-1, 0, 0, 0, 0, -1)]), "tick"))
	assert_true(_has_error(_schedule([_change(0, 1001, 0, 0, 0, -1)]), "rain"))
	assert_true(_has_error(_schedule([_change(0, 0, -5, 0, 0, -1)]), "snow"))
	assert_true(_has_error(_schedule([_change(0, 0, 0, 0, -1, -1)]), "ramp_ticks"))
	assert_true(_has_error(_schedule([_change(0, 0, 0, 0, 0, 1001)]), "snow_cover"))
	assert_true(_has_error(_schedule([null]), "null"))


func test_the_shipped_schedule_is_valid() -> void:
	var schedule: WeatherSchedule = load("res://data/weather/riverside_showers.tres") as WeatherSchedule
	assert_not_null(schedule)
	assert_eq(schedule.validate(), PackedStringArray())
	assert_gt(schedule.changes.size(), 1)


func test_weather_is_part_of_the_state_hash() -> void:
	var a: World = World.new(1)
	var b: World = World.new(1)
	var c: World = World.new(1)
	a.enqueue(SetWeatherCommand.new(5, 300, 0, 0, 0, 20))
	b.enqueue(SetWeatherCommand.new(5, 300, 0, 0, 0, 20))
	c.enqueue(SetWeatherCommand.new(5, 301, 0, 0, 0, 20))
	_run(a, 10)
	_run(b, 10)
	_run(c, 10)
	assert_eq(a.state_hash(), b.state_hash())
	assert_ne(a.state_hash(), c.state_hash())


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


func _change(tick: int, rain: int, snow: int, wind_x: int, ramp: int, cover: int) -> WeatherChange:
	var c: WeatherChange = WeatherChange.new()
	c.tick = tick
	c.rain = rain
	c.snow = snow
	c.wind_x = wind_x
	c.ramp_ticks = ramp
	c.snow_cover = cover
	return c


func _schedule(changes: Array) -> WeatherSchedule:
	var s: WeatherSchedule = WeatherSchedule.new()
	s.changes.assign(changes)
	return s


func _has_error(schedule: WeatherSchedule, fragment: String) -> bool:
	for error: String in schedule.validate():
		if error.contains(fragment):
			return true
	return false
