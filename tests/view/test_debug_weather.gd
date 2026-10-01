extends GutTest
## F6 (debug, like F9) cycles the weather through clear, rain, heavy rain, and
## snow. It changes the sim only through a SetWeatherCommand at the current
## tick, ramped over a few seconds, like any other order.


func test_presets_cycle_clear_rain_heavy_snow_and_back() -> void:
	var names: Array[String] = []
	var index: int = 0
	for _press: int in DebugWeather.PRESETS.size() + 1:
		index = DebugWeather.next(index)
		names.append(DebugWeather.name_of(index))
	assert_eq(names, ["rain", "heavy rain", "snow", "clear", "rain"])


func test_a_preset_reaches_the_sim_as_a_command_at_the_current_tick() -> void:
	var world: World = World.new(1)
	for _t: int in 10:
		world.step()
	var command: SetWeatherCommand = DebugWeather.command(DebugWeather.next(0), world.tick)
	assert_eq(command.tick, 10)
	assert_true(world.enqueue(command))
	for _t: int in DebugWeather.RAMP_TICKS + 1:
		world.step()
	assert_gt(world.weather.rain, 0)
	assert_eq(world.weather.snow, 0)
