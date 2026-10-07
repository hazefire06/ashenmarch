extends GutTest
## UnitAnimator: the animation and speed an art body plays, from sim state.
## TestArt's default art: attack 6 frames at 12 fps with impact frame 3 (a
## quarter second in), walk 12 frames at 12 fps covering 1.2 m.

const SHOOTER: Dictionary = {
	"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, 3],
	"shoot": [8, 12, false, 5], "cast": [6, 12, false, 2], "die": [4, 12, false, -1],
}

var _animator: UnitAnimator


func before_each() -> void:
	_animator = UnitAnimator.new(TestArt.art())


func _tick(fields: Dictionary = {}) -> UnitAnimator.Play:
	var input: UnitAnimator.AnimInput = UnitAnimator.AnimInput.new()
	for key: String in fields:
		input.set(key, fields[key])
	return _animator.after_tick(input)


func test_a_unit_standing_idles() -> void:
	var play: UnitAnimator.Play = _tick()
	assert_eq(play.anim, &"idle")
	assert_eq(play.speed_scale, 1.0)


func test_walking_plays_at_ground_speed() -> void:
	# One cycle is 1 s at speed 1 and covers 1.2 m; 2.4 m/s needs speed 2.
	var play: UnitAnimator.Play = _tick({"moving": true, "ground_speed": 2.4})
	assert_eq(play.anim, &"walk")
	assert_almost_eq(play.speed_scale, 2.0, 0.0001)


func test_a_unit_barely_moving_idles() -> void:
	assert_eq(_tick({"moving": true, "ground_speed": 0.01}).anim, &"idle")


func test_a_swing_lands_its_impact_frame_on_the_blow() -> void:
	# Impact frame 3 at 12 fps is 0.25 s; a 6-tick wind-up is 0.2 s.
	var play: UnitAnimator.Play = _tick({"windup_left": 6})
	assert_eq(play.anim, &"attack")
	assert_true(play.restart)
	assert_almost_eq(play.speed_scale, 1.25, 0.0001)


func test_a_swing_in_progress_carries_on() -> void:
	_tick({"windup_left": 6})
	var play: UnitAnimator.Play = _tick({"windup_left": 5, "moving": true, "ground_speed": 2.0})
	assert_eq(play.anim, &"attack", "a strike plays out before walking resumes")
	assert_false(play.restart)
	assert_almost_eq(play.speed_scale, 1.25, 0.0001)


func test_the_swing_plays_out_then_idles() -> void:
	# 6 frames at 12 fps and speed 1.25 last 0.4 s: 12 ticks.
	_tick({"windup_left": 6})
	for i: int in 5:
		assert_eq(_tick({"windup_left": 5 - i}).anim, &"attack")
	for i: int in 9:
		_tick()
	assert_eq(_tick().anim, &"idle")


func test_wind_ups_too_short_or_long_are_clamped() -> void:
	assert_eq(_tick({"windup_left": 1}).speed_scale, UnitAnimator.MAX_SPEED)
	var slow: UnitAnimator = UnitAnimator.new(TestArt.art())
	var input: UnitAnimator.AnimInput = UnitAnimator.AnimInput.new()
	input.windup_left = 60
	assert_eq(slow.after_tick(input).speed_scale, UnitAnimator.MIN_SPEED)


func test_a_shot_uses_the_ranged_animation() -> void:
	_animator = UnitAnimator.new(TestArt.art(&"longbow", SHOOTER))
	var play: UnitAnimator.Play = _tick({"aim_left": 10})
	assert_eq(play.anim, &"shoot")
	assert_true(play.restart)


func test_without_a_ranged_animation_a_shot_falls_back_to_attack() -> void:
	assert_eq(_tick({"aim_left": 10}).anim, &"attack")


func test_a_shot_with_no_wind_up_shows_its_release() -> void:
	_animator = UnitAnimator.new(TestArt.art(&"longbow", SHOOTER))
	var play: UnitAnimator.Play = _tick({"launched": true})
	assert_eq(play.anim, &"shoot")
	assert_true(play.restart)
	assert_eq(play.start_frame, 5)


func test_a_launch_at_the_end_of_a_draw_does_not_restart_it() -> void:
	_animator = UnitAnimator.new(TestArt.art(&"longbow", SHOOTER))
	_tick({"aim_left": 2})
	_tick({"aim_left": 1})
	assert_false(_tick({"aim_left": 0, "launched": true}).restart)


func test_an_errand_plays_cast() -> void:
	_animator = UnitAnimator.new(TestArt.art(&"warden", SHOOTER))
	assert_eq(_tick({"act_left": 9}).anim, &"cast")


func test_death_plays_once() -> void:
	var first: UnitAnimator.Play = _tick({"alive": false})
	assert_eq(first.anim, &"die")
	assert_true(first.restart)
	assert_false(_tick({"alive": false}).restart)


func test_a_corpse_seen_again_does_not_die_again() -> void:
	_animator.mark_dead()
	assert_false(_tick({"alive": false}).restart)


func test_a_body_that_bursts_has_no_death() -> void:
	_animator = UnitAnimator.new(TestArt.art(&"blightbag", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, 3],
	}, true))
	assert_eq(_tick({"alive": false}).anim, &"idle")


func test_paralysis_freezes_what_shows() -> void:
	var play: UnitAnimator.Play = _tick({"moving": true, "ground_speed": 2.4, "paralyzed": true})
	assert_eq(play.anim, &"walk")
	assert_eq(play.speed_scale, 0.0)
