extends GutTest
## The bark rules: the shuffle bag, the cooldowns, the squad repeat rule, the
## side-wide gap, one bark at a time, the annoyed counter and the clan line.


func _rules(seed_value: int = 1) -> BarkRules:
	var rules: BarkRules = BarkRules.new()
	rules.rng = RandomNumberGenerator.new()
	rules.rng.seed = seed_value
	return rules


func test_the_bag_plays_every_line_before_any_repeats() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 3
	var bag: ShuffleBag = ShuffleBag.new(6)
	var seen: Dictionary = {}
	for i: int in 6:
		seen[bag.next(rng)] = true
	assert_eq(seen.size(), 6, "all six indices came out in the first round")


func test_the_bag_never_repeats_across_rounds() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 5
	var bag: ShuffleBag = ShuffleBag.new(4)
	var last: int = -1
	for i: int in 400:
		var got: int = bag.next(rng)
		assert_ne(got, last, "no repeat at draw %d" % i)
		last = got


func test_each_trigger_waits_for_its_cooldown() -> void:
	var rules: BarkRules = _rules()
	assert_true(rules.allow(&"select", 0.0))
	rules.started(&"select", 0.0, 0.5)
	assert_false(rules.allow(&"select", 9.9))
	assert_true(rules.allow(&"select", 10.1))


func test_a_repeat_order_to_the_same_squad_within_five_seconds_is_tone_only() -> void:
	var rules: BarkRules = _rules()
	assert_true(rules.allow(&"move", 0.0, PackedInt32Array([3, 1, 2])))
	rules.started(&"move", 0.0, 0.5, PackedInt32Array([3, 1, 2]))
	assert_false(rules.allow(&"move", 4.9, PackedInt32Array([1, 2, 3])), "same ids, any order")
	assert_true(rules.allow(&"move", 1.0, PackedInt32Array([4, 5])), "other ids")
	assert_true(rules.allow(&"move", 5.1, PackedInt32Array([1, 2, 3])), "after five seconds")


func test_kill_hurt_and_death_share_a_four_second_gap() -> void:
	var rules: BarkRules = _rules()
	rules.started(&"kill", 0.0, 0.5)
	assert_false(rules.allow(&"hurt", 3.9))
	assert_false(rules.allow(&"death", 3.9))
	assert_true(rules.allow(&"hurt", 4.1))
	assert_true(rules.allow(&"attack", 1.0), "an ungapped trigger ignores the gap")


func test_one_bark_at_a_time_except_a_death() -> void:
	var rules: BarkRules = _rules()
	rules.started(&"select", 0.0, 2.0)
	assert_true(rules.speaking(1.0))
	assert_false(rules.speaking(2.1))
	assert_false(rules.allow(&"attack", 1.0))
	assert_true(rules.allow(&"death", 1.0))
	assert_true(rules.allow(&"attack", 2.1))


func test_the_fourth_click_in_three_seconds_is_annoyed() -> void:
	var rules: BarkRules = _rules()
	assert_false(rules.click(7, 0.0))
	assert_false(rules.click(7, 1.0))
	assert_false(rules.click(7, 2.0))
	assert_true(rules.click(7, 2.9))
	assert_false(rules.click(7, 3.0), "the count starts again")
	var slow: BarkRules = _rules()
	slow.click(7, 0.0)
	slow.click(7, 1.0)
	slow.click(7, 2.0)
	assert_false(slow.click(7, 3.1))
	assert_false(slow.click(8, 3.2), "another unit has its own count")


func test_about_one_in_ten_is_a_clan_line_and_never_two_in_a_row() -> void:
	var rules: BarkRules = _rules(11)
	var clans: int = 0
	var last: bool = false
	var total: int = 10000
	for i: int in total:
		var was: bool = rules.clan_turn()
		if was:
			clans += 1
			assert_false(last, "two clan lines in a row at %d" % i)
		rules.note_clan(was)
		last = was
	var ratio: float = float(clans) / float(total)
	gut.p("clan ratio %.4f" % ratio)
	assert_between(ratio, 0.07, 0.11)


func test_a_refused_bark_records_nothing() -> void:
	var rules: BarkRules = _rules()
	rules.started(&"select", 0.0, 1.0)
	assert_false(rules.allow(&"kill_x", 0.5), "one at a time")
	assert_false(rules.allow(&"select", 0.5))
	# Nothing the refused calls could have recorded changes a later answer.
	assert_true(rules.allow(&"kill", 1.1), "no gap was started by a refusal")
	assert_true(rules.allow(&"move", 1.1, PackedInt32Array([1])))
	assert_false(rules.speaking(1.1))


func test_family_folds_formations_and_statuses() -> void:
	var rules: BarkRules = _rules()
	assert_eq(rules.family(&"formation_wedge"), &"formation")
	assert_eq(rules.family(&"status_burning"), &"status")
	assert_eq(rules.family(&"select"), &"select")
	rules.started(&"formation_wedge", 0.0, 0.5)
	assert_false(rules.allow(&"formation_box", 7.0))
	assert_true(rules.allow(&"formation_box", 8.1))


func test_pick_keeps_a_bag_per_key() -> void:
	var rules: BarkRules = _rules(2)
	var seen: Dictionary = {}
	for i: int in 3:
		seen[rules.pick(&"shieldman_old/select", 3)] = true
	assert_eq(seen.size(), 3)


func test_a_death_does_not_shorten_a_longer_bark() -> void:
	var rules: BarkRules = _rules()
	rules.started(&"select", 0.0, 5.0)
	rules.started(&"death", 1.0, 0.5)
	assert_true(rules.speaking(3.0), "the long bark is still speaking")
	assert_false(rules.speaking(5.1))


func test_pick_with_a_different_count_for_a_key_is_an_error() -> void:
	var rules: BarkRules = _rules(2)
	rules.pick(&"warden/move", 3)
	rules.pick(&"warden/move", 3)
	assert_push_error_count(0)
	rules.pick(&"warden/move", 4)
	assert_push_error("warden/move")


func test_the_victory_cuts_in_and_is_not_side_gapped() -> void:
	var rules: BarkRules = _rules()
	rules.started(&"kill", 0.0, 3.0)
	assert_true(rules.allow(&"victory", 1.0), "over a bark and the side gap")
