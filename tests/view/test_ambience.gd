extends GutTest
## Ambience: the beds follow the weather and what's near the camera's focus,
## the march follows the visible movers and the ground under them, and a loop
## that has faded out stops its player.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog = load("res://data/units/catalog.tres") as UnitCatalog


# A 100 x 100 m field: every cell fill, except a 2 m creek of depth 2 across
# x = 60..61 when creek is true.
func _rows(fill: String, creek: bool = false) -> Array[String]:
	var rows: Array[String] = []
	for z: int in 100:
		var row: String = ""
		for x: int in 100:
			row += "2" if (creek and x >= 60 and x < 62) else fill
		rows.append(row)
	return rows


func _world(fill: String = ".", creek: bool = false) -> World:
	return World.new(1, TestTerrains.from_ascii(_rows(fill, creek)), _catalog)


func _bank() -> SoundBank:
	var variants: Dictionary = {}
	for id: StringName in Ambience.BEDS + Ambience.MARCHES:
		variants[id] = 1
	return AudioFixtures.bank(variants)


func _ambience(world: World, focus: Vector3, bank: SoundBank = null) -> Ambience:
	var camera: RtsCamera = RtsCamera.new()
	add_child_autofree(camera)
	camera.focus = focus
	var beds: Ambience = Ambience.new()
	add_child_autofree(beds)
	beds.setup(world, camera, bank if bank != null else _bank())
	return beds


func _mover(world: World, id: StringName, side: UnitType.Faction, x: float, z: float) -> Unit:
	var unit: Unit = world.spawn_unit(_catalog.index_of(id), side, roundi(x * M), roundi(z * M), 0, 1000)
	unit.state = Unit.State.MOVING
	return unit


func _light(world: World, x0: int, count: int, z: int) -> void:
	for i: int in count:
		world.fire.burn_end[z * world.terrain.size_x + x0 + i] = 9999


func test_the_beds_follow_the_rain_and_the_fire() -> void:
	var world: World = _world()
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
	assert_eq(beds.targets()[&"bed_rain"], 0.0, "clear")
	assert_eq(beds.targets()[&"bed_fire"], 0.0, "unburnt")
	world.weather.rain = 1000
	_light(world, 40, 150, 50)
	beds.after_step()
	assert_almost_eq(beds.targets()[&"bed_rain"], 1.0, 0.01, "rain at full")
	assert_almost_eq(beds.targets()[&"bed_fire"], 1.0, 0.01, "fire at full")


func test_rain_and_snow_drive_their_beds_and_duck_the_outdoor_bed() -> void:
	var world: World = _world()
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
	assert_almost_eq(beds.targets()[&"bed_outdoor"], 1.0, 0.001, "dry")
	world.weather.rain = 500
	world.weather.snow = 250
	beds.after_step()
	assert_almost_eq(beds.targets()[&"bed_rain"], 0.5, 0.001)
	assert_almost_eq(beds.targets()[&"bed_snow"], 0.25, 0.001)
	assert_almost_eq(beds.targets()[&"bed_outdoor"], 0.7, 0.001)
	world.weather.rain = 1000
	beds.after_step()
	assert_almost_eq(beds.targets()[&"bed_outdoor"], 0.4, 0.001, "ducked at full rain")


func test_only_fire_near_the_focus_counts() -> void:
	var world: World = _world()
	var beds: Ambience = _ambience(world, Vector3(10, 0, 50))
	for z: int in range(43, 58):
		_light(world, 35, 5, z)
	beds.after_step()
	assert_almost_eq(beds.targets()[&"bed_fire"], 0.5, 0.001, "30 m away counts")
	world.fire.burn_end.clear()
	_light(world, 90, 10, 50)
	beds.after_step()
	assert_eq(beds.targets()[&"bed_fire"], 0.0, "80 m away doesn't")


func test_water_near_the_focus_raises_the_creek_bed() -> void:
	var world: World = _world(".", true)
	var beds: Ambience = _ambience(world, Vector3(20, 0, 50))
	assert_eq(beds.targets()[&"bed_water"], 0.0, "far from the creek")
	beds._camera.focus = Vector3(60, 0, 50)
	beds.after_step()
	assert_gt(beds.targets()[&"bed_water"], 0.0, "at the creek")
	assert_lte(beds.targets()[&"bed_water"], 1.0)


func test_a_cloud_near_the_focus_hisses() -> void:
	var world: World = _world()
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
	world.clouds.append(GasCloud.new(1, 70 * M, 0, 50 * M, 5 * M, 100, 0, 0))
	beds.after_step()
	assert_almost_eq(beds.targets()[&"bed_gas"], 0.5, 0.001, "one cloud, 20 m off")
	world.clouds.append(GasCloud.new(2, 50 * M, 0, 80 * M, 5 * M, 100, 0, 0))
	world.clouds.append(GasCloud.new(3, 50 * M, 0, 20 * M, 5 * M, 100, 0, 0))
	beds.after_step()
	assert_eq(beds.targets()[&"bed_gas"], 1.0, "capped at two")
	world.clouds.clear()
	world.clouds.append(GasCloud.new(4, 95 * M, 0, 50 * M, 5 * M, 100, 0, 0))
	beds.after_step()
	assert_eq(beds.targets()[&"bed_gas"], 0.0, "45 m is out of reach")


func test_marching_follows_the_seen_movers_and_their_ground() -> void:
	var world: World = _world("s")
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
	for i: int in 3:
		_mover(world, &"shieldman", LIGHT, 45 + i, 50)
	beds.after_step()
	assert_almost_eq(beds.targets()[&"march_sand"], 0.5, 0.001, "3 movers")
	assert_eq(beds.targets()[&"march_grass"], 0.0)
	for i: int in 9:
		_mover(world, &"shieldman", LIGHT, 45 + i, 52)
	beds.after_step()
	assert_almost_eq(beds.targets()[&"march_sand"], 1.0, 0.001, "12 movers")
	# Out of reach: nobody counts.
	var far: World = _world("s")
	var far_beds: Ambience = _ambience(far, Vector3(5, 0, 5))
	_mover(far, &"shieldman", LIGHT, 90, 90)
	far_beds.after_step()
	assert_eq(far_beds.targets()[&"march_sand"], 0.0)


func test_marching_picks_the_ground_by_majority() -> void:
	for pair: Array in [["r", &"march_rock"], [".", &"march_grass"], ["b", &"march_grass"], ["1", &"march_water"]]:
		var world: World = _world(pair[0])
		var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
		_mover(world, &"shieldman", LIGHT, 50, 50)
		beds.after_step()
		assert_gt(beds.targets()[pair[1]], 0.0, str(pair[0]))
		var others: float = 0.0
		for id: StringName in Ambience.MARCHES:
			if id != pair[1]:
				others += beds.targets()[id]
		assert_eq(others, 0.0, "only one ground plays for " + str(pair[0]))


# The march loops are men in boots. Riverside's camera opens on seven patrolling Husks, and they marched
# the whole time the squad stood still.
func test_undead_make_no_march_for_either_side() -> void:
	var world: World = _world(".")
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
	for i: int in 7:
		_mover(world, &"husk", DARK, 45 + i, 50)
	beds.after_step()
	assert_eq(beds.targets()[&"march_grass"], 0.0, "seen, near, moving, and undead")
	beds.set_viewer(DARK)
	assert_eq(beds.targets()[&"march_grass"], 0.0, "not even for their own side")
	_mover(world, &"shieldman", LIGHT, 50, 52)
	beds.after_step()
	assert_gt(beds.targets()[&"march_grass"], 0.0, "a living mover marches, whoever is listening")


func test_a_silent_loop_stops_its_player() -> void:
	var world: World = _world()
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50))
	world.weather.rain = 1000
	beds.after_step()
	for i: int in 30:
		beds._process(0.1)
	var rain: AudioStreamPlayer = beds._players[&"bed_rain"]
	assert_true(rain.playing, "rising rain plays")
	world.weather.rain = 0
	beds.after_step()
	for i: int in 60:
		beds._process(0.1)
	assert_false(rain.playing, "and stops once it has faded out")


func test_a_loop_with_no_stream_stays_silent() -> void:
	var world: World = _world()
	var empty: SoundBank = SoundBank.new()
	var beds: Ambience = _ambience(world, Vector3(50, 0, 50), empty)
	for i: int in 10:
		beds._process(0.1)
	for id: StringName in beds._players:
		assert_false(beds._players[id].playing, str(id))
	assert_true(empty.warned().has(&"bed_outdoor"), "the bank warned")
