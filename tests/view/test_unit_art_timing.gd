extends GutTest
## The committed art against the sim's own numbers. A1's animator was proven
## on the Shieldman alone, and A3's clips were picked by look, so nothing
## checked that a walk or a strike can be played at the speed the sim asks for
## within UnitAnimator's clamp. These run every unit in data/art/catalog.tres
## against its data/units type, so a new unit is covered without a new test.

const M: int = 1000

var _arts: UnitArtCatalog
var _units: UnitCatalog


func before_each() -> void:
	_units = TestTerrains.catalog()
	_arts = UnitArtCatalog.load_or_new()


# False, with the test marked pending, when no art is built (a fresh clone
# without it, as the other art tests do).
func _have_art() -> bool:
	if _arts.arts.is_empty():
		pending("data/art/catalog.tres lists no art; run make art-build UNIT=<id>")
		return false
	return true


func _type_of(art: UnitArt) -> UnitType:
	var type: UnitType = _units.find(art.unit_id)
	assert_not_null(type, "%s has art but no type in data/units" % art.unit_id)
	return type


# Seconds one play of the animation takes at speed 1.
func _seconds(art: UnitArt, anim: StringName) -> float:
	var name: StringName = UnitArt.anim_name(anim, 0)
	return art.frames.get_frame_count(name) / art.frames.get_animation_speed(name)


# The wind-ups of a type that start a clip, each {path, ticks, counter}: the sim counter it runs on
# (UnitAnimator.AnimInput's windup_left for melee, aim_left for a shot, throw or cast, act_left for a
# heal or a pick-up) and the ticks it counts down from.
func _windups(type: UnitType) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if type.melee_windup_ticks > 0:
		out.append({"path": "melee", "ticks": type.melee_windup_ticks, "counter": "windup_left"})
	if type.ranged_windup_ticks > 0:
		out.append({"path": "ranged", "ticks": type.ranged_windup_ticks, "counter": "aim_left"})
	var heals: bool = type.special_ability == UnitType.Special.HEAL
	if heals and type.heal_windup_ticks > 0:
		out.append({"path": "heal", "ticks": type.heal_windup_ticks, "counter": "act_left"})
	# What Interactions.action_for lets a unit take: an object or a body part (a unit that throws what it
	# carries) or a herb (a healer).
	if type.throws_carried or heals:
		out.append({"path": "pick-up", "ticks": Interactions.PICKUP_TICKS, "counter": "act_left"})
	return out


# What the sim says on the tick a wind-up starts: counter holds `ticks`.
func _anim_input(counter: String, ticks: int) -> UnitAnimator.AnimInput:
	var input: UnitAnimator.AnimInput = UnitAnimator.AnimInput.new()
	match counter:
		"windup_left":
			input.windup_left = ticks
		"aim_left":
			input.aim_left = ticks
		"act_left":
			input.act_left = ticks
		_:
			fail_test("no wind-up counter called %s" % counter)
	return input


func test_every_walk_plays_inside_the_animators_clamp_at_full_speed() -> void:
	if not _have_art():
		return
	for art: UnitArt in _arts.arts:
		var type: UnitType = _type_of(art)
		if type == null:
			continue
		# As UnitAnimator.after_tick plays it: ground speed (m/s) x the walk's length (s) / its stride (m).
		var rate: float = type.move_speed / float(M) * _seconds(art, &"walk") / art.stride_m
		var who: String = "%s walks at %.2fx" % [art.unit_id, rate]
		assert_gt(rate, UnitAnimator.MIN_SPEED, who + ", under the clamp's floor")
		assert_lt(rate, UnitAnimator.MAX_SPEED, who + ", at or over the clamp's ceiling")


func test_every_strike_can_land_its_impact_on_the_tick_the_sim_does() -> void:
	if not _have_art():
		return
	var checked: int = 0
	for art: UnitArt in _arts.arts:
		var type: UnitType = _type_of(art)
		if type == null:
			continue
		for windup: Dictionary in _windups(type):
			# The animator itself says which clip the wind-up plays, so this follows its choice.
			var anim: StringName = UnitAnimator.new(art).after_tick(_anim_input(windup["counter"], windup["ticks"])).anim
			var impact: int = art.impact_frames.get(anim, 0)
			var fps: float = art.frames.get_animation_speed(UnitArt.anim_name(anim, 0))
			if impact <= 0 or fps <= 0.0:
				continue  # no impact frame to land: it plays at 1x
			checked += 1
			var natural: float = impact / fps
			var wanted: float = float(windup["ticks"]) / World.TICK_RATE
			var who: String = "%s %s (%s, %d ticks)" % [art.unit_id, windup["path"], anim, windup["ticks"]]
			assert_lte(natural / wanted, UnitAnimator.MAX_SPEED, "%s needs %.2fx to land its impact on time" % [who, natural / wanted])
			assert_gte(natural / wanted, UnitAnimator.MIN_SPEED, "%s needs %.2fx, under the clamp's floor" % [who, natural / wanted])
	assert_gt(checked, 0, "the art has timed strikes to check")
