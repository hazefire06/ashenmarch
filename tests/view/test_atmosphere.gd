extends GutTest
## Atmosphere: a mission's look as plain data (the view applies it), and the
## range checks that keep a hand-written .tres from producing a black screen.


func _errors(a: Atmosphere) -> PackedStringArray:
	return a.validate()


func _mentions(errors: PackedStringArray, fragment: String) -> bool:
	for e: String in errors:
		if e.contains(fragment):
			return true
	return false


func test_the_default_is_a_pastoral_day_and_validates() -> void:
	var a: Atmosphere = Atmosphere.new()
	assert_eq(_errors(a), PackedStringArray())
	assert_gt(a.sun_energy, 0.0, "daylight")
	assert_gt(a.ambient_energy, 0.0)
	assert_lt(a.sun_pitch_degrees, 0.0, "the sun is above the horizon, shining down")
	assert_false(a.fog_enabled)
	assert_eq(a.terrain_tint, Color.WHITE, "multiplying by white changes nothing")
	assert_eq(a.terrain_desaturation, 0.0)
	assert_true(a.ground_recolor.is_empty(), "no recolor")
	assert_eq(a.water_tint.a, 0.0, "no blend")
	assert_eq(a.ash_fall, 0.0)


func test_the_default_matches_the_look_the_main_scene_has_today() -> void:
	# main.tscn's sky, ambient light, and sun, so a mission without an atmosphere
	# looks as it always has.
	var a: Atmosphere = Atmosphere.new()
	assert_eq(a.background_color, Color(0.52, 0.6, 0.68, 1))
	assert_eq(a.ambient_color, Color(0.75, 0.75, 0.8, 1))
	assert_eq(a.ambient_energy, 0.5)
	assert_eq(a.sun_pitch_degrees, -30.0)
	assert_eq(a.sun_yaw_degrees, -30.0)
	assert_eq(a.sun_energy, 1.0)


func test_energies_cannot_be_negative() -> void:
	for field: String in ["ambient_energy", "sun_energy", "fog_density"]:
		var a: Atmosphere = Atmosphere.new()
		a.set(field, -0.1)
		assert_true(_mentions(_errors(a), field), field)
		a.set(field, 0.0)
		assert_eq(_errors(a), PackedStringArray(), "%s of 0 is fine" % field)


func test_fractions_stay_between_0_and_1() -> void:
	for field: String in ["terrain_desaturation", "ash_fall"]:
		for bad: float in [-0.01, 1.01]:
			var a: Atmosphere = Atmosphere.new()
			a.set(field, bad)
			assert_true(_mentions(_errors(a), field), "%s = %s" % [field, bad])
		for ok: float in [0.0, 0.5, 1.0]:
			var a: Atmosphere = Atmosphere.new()
			a.set(field, ok)
			assert_eq(_errors(a), PackedStringArray(), "%s = %s" % [field, ok])


func test_the_sun_must_not_be_below_the_horizon_or_past_straight_down() -> void:
	for bad: float in [-90.5, 0.5, 45.0]:
		var a: Atmosphere = Atmosphere.new()
		a.sun_pitch_degrees = bad
		assert_true(_mentions(_errors(a), "sun_pitch_degrees"), "%s" % bad)
	for ok: float in [-90.0, -50.0, -1.0, 0.0]:
		var a: Atmosphere = Atmosphere.new()
		a.sun_pitch_degrees = ok
		assert_eq(_errors(a), PackedStringArray(), "%s" % ok)


func test_ground_recolor_is_empty_or_one_color_per_ground() -> void:
	assert_eq(Terrain.GROUND_COUNT, 5)
	var a: Atmosphere = Atmosphere.new()
	a.ground_recolor = [Color.RED, Color.GREEN]
	assert_true(_mentions(_errors(a), "ground_recolor"))
	var full: Array[Color] = []
	for i: int in Terrain.GROUND_COUNT:
		full.append(Color(0.4, 0.3, 0.2, 0.5))
	a.ground_recolor = full
	assert_eq(_errors(a), PackedStringArray())


func test_blend_amounts_are_alphas_between_0_and_1() -> void:
	var a: Atmosphere = Atmosphere.new()
	a.water_tint = Color(0.2, 0.2, 0.2, 1.5)
	assert_true(_mentions(_errors(a), "water_tint"))
	a = Atmosphere.new()
	var recolor: Array[Color] = []
	for i: int in Terrain.GROUND_COUNT:
		recolor.append(Color(0.4, 0.3, 0.2, 0.5))
	recolor[2].a = -0.2
	a.ground_recolor = recolor
	assert_true(_mentions(_errors(a), "ground_recolor"))


func test_every_problem_is_listed() -> void:
	var a: Atmosphere = Atmosphere.new()
	a.ambient_energy = -1.0
	a.sun_energy = -1.0
	a.ash_fall = 2.0
	a.terrain_desaturation = -1.0
	assert_gte(_errors(a).size(), 4)


func test_atmospheres_do_not_share_their_recolor_list() -> void:
	var a: Atmosphere = Atmosphere.new()
	var b: Atmosphere = Atmosphere.new()
	a.ground_recolor.append(Color.RED)
	assert_true(b.ground_recolor.is_empty())
