extends GutTest
## MenuKit's formatting rules, which every front-end screen leans on: tier
## names, mm:ss, and a veterancy bonus as a percentage. (Its widget builders
## are exercised by every screen's tests.)


func test_there_is_a_name_for_every_tier_and_normal_is_the_default() -> void:
	assert_eq(MenuKit.TIER_NAMES.size(), Difficulty.TIERS, "one name per tier")
	assert_eq(MenuKit.TIER_NAMES, PackedStringArray(["Easy", "Moderate", "Normal", "Hard", "Brutal"]))
	assert_eq(MenuKit.DEFAULT_TIER, 2)
	assert_eq(MenuKit.tier_name(MenuKit.DEFAULT_TIER), "Normal")


func test_a_tier_outside_the_five_is_named_by_number() -> void:
	assert_eq(MenuKit.tier_name(7), "Tier 7")
	assert_eq(MenuKit.tier_name(-1), "Tier -1")


func test_the_clock_is_minutes_and_two_digit_seconds() -> void:
	assert_eq(MenuKit.clock(0), "0:00")
	assert_eq(MenuKit.clock(9), "0:09")
	assert_eq(MenuKit.clock(59), "0:59")
	assert_eq(MenuKit.clock(60), "1:00")
	assert_eq(MenuKit.clock(3599), "59:59")
	assert_eq(MenuKit.clock(3600), "60:00", "minutes are not wrapped into hours")


func test_a_bonus_is_a_percentage_from_the_veterancy_curve() -> void:
	# bonus = cap * kills / (kills + 4), in permille; the text is percent.
	assert_eq(MenuKit.bonus_text(120, 4), "+6%")
	assert_eq(MenuKit.bonus_text(250, 4), "+12.5%")
	assert_eq(MenuKit.bonus_text(300, 1), "+6%")
	assert_eq(MenuKit.bonus_text(250, 8), "+16.6%", "166 permille: rounded down by the curve, shown as is")
	assert_eq(MenuKit.bonus_text(120, 0), "+0%", "a type that improves, with no kills yet")


func test_a_type_that_never_improves_shows_a_dash_not_zero() -> void:
	assert_eq(MenuKit.bonus_text(0, 12), "-")
	assert_eq(MenuKit.bonus_text(0, 0), "-")


func test_a_scroll_area_follows_the_keyboard_focus() -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	assert_true(scroll.follow_focus, "tabbing into a row that is off screen brings it into view")
	assert_eq(scroll.horizontal_scroll_mode, ScrollContainer.SCROLL_MODE_DISABLED)
	scroll.free()


func test_the_bonus_text_never_disagrees_with_the_sim() -> void:
	for kills: int in [0, 1, 3, 4, 9, 40]:
		var permille: int = Veterancy.bonus_permille(250, kills)
		var shown: String = MenuKit.bonus_text(250, kills)
		assert_almost_eq(float(shown.trim_prefix("+").trim_suffix("%")), permille / 10.0, 0.001, "%d kills" % kills)
