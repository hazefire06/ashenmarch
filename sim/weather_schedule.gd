class_name WeatherSchedule
extends Resource
## A mission's weather over time (data/weather/*.tres): WeatherChanges in
## ascending tick order. It reaches the sim as SetWeatherCommands enqueued at
## mission start, so the weather is part of the same command stream a replay
## records, like the mission's spawns. An empty schedule is clear weather.

@export var changes: Array[WeatherChange] = []


## Problems that make the schedule unusable, or an empty array.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var who: String = resource_path if not resource_path.is_empty() else "weather schedule"
	var last_tick: int = -1
	for i: int in changes.size():
		var change: WeatherChange = changes[i]
		var where: String = "%s change %d" % [who, i]
		if change == null:
			errors.append("%s is null" % where)
			continue
		errors.append_array(change.validate(where))
		if change.tick <= last_tick:
			errors.append("%s: ticks must be strictly ascending" % where)
		last_tick = change.tick
	return errors


## One command per change, to enqueue before the mission's first tick.
func commands() -> Array[SetWeatherCommand]:
	var out: Array[SetWeatherCommand] = []
	for change: WeatherChange in changes:
		out.append(change.to_command())
	return out
