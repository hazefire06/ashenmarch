extends GutTest
## UnitArtSet: one game's unit art. The types it is given load at once and no
## others do. A type it missed loads late, with one warning. Broken art is left
## out with a warning per reason. Releasing the set releases its art.

const DIR: String = "user://test_unit_art_set"


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)


# A catalog listing TestArt for each id, each saved to DIR/<id>.tres; those in
# `broken` lack a direction of idle.
func _catalog(ids: Array[StringName], broken: Array[StringName] = []) -> UnitArtCatalog:
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	for id: StringName in ids + broken:
		var art: UnitArt = TestArt.art(id)
		if id in broken:
			art.frames.remove_animation(&"idle_5")
		var path: String = "%s/%s.tres" % [DIR, id]
		assert_eq(ResourceSaver.save(art, path), OK)
		catalog.put(id, path)
	return catalog


func test_it_loads_the_types_it_is_given_and_no_others() -> void:
	var catalog: UnitArtCatalog = _catalog([&"shieldman", &"husk", &"ripper"])
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"husk"], catalog)
	assert_eq(Array(arts.loaded_ids()), [&"husk", &"shieldman"])
	assert_true(ResourceLoader.has_cached(DIR + "/shieldman.tres"))
	assert_false(ResourceLoader.has_cached(DIR + "/ripper.tres"), "not asked for, not loaded")


func test_a_type_the_list_missed_loads_late_with_one_warning() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman"], _catalog([&"shieldman", &"ripper"]))
	assert_not_null(arts.find(&"ripper"), "a stray type still gets its art")
	assert_not_null(arts.find(&"ripper"))
	assert_push_warning("UnitArtSet: ripper's art loaded late")
	assert_push_warning_count(1)


func test_a_type_without_art_is_a_quiet_placeholder() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"villager"], _catalog([&"shieldman"]))
	assert_null(arts.find(&"villager"))
	assert_push_warning_count(0)


func test_broken_art_is_left_out_with_a_warning_per_reason() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"reaver"], _catalog([&"shieldman"], [&"reaver"]))
	assert_null(arts.find(&"reaver"), "a placeholder, and the game starts")
	assert_null(arts.find(&"reaver"), "tried once")
	assert_push_warning("UnitArtSet: unit art left out: reaver: idle has no frames for direction 5")
	assert_push_warning_count(1)
	assert_eq(Array(arts.loaded_ids()), [&"shieldman"])


func test_sheet_bytes_add_up_the_loaded_art() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman", &"husk"], _catalog([&"shieldman", &"husk"]))
	var expected: int = 0
	for art: UnitArt in arts.arts():
		expected += art.sheet_bytes()
	assert_gt(expected, 0)
	assert_eq(arts.sheet_bytes(), expected)


func test_releasing_the_set_releases_its_art() -> void:
	var arts: UnitArtSet = UnitArtSet.for_types([&"shieldman"], _catalog([&"shieldman"]))
	assert_true(ResourceLoader.has_cached(DIR + "/shieldman.tres"))
	arts = null
	assert_false(ResourceLoader.has_cached(DIR + "/shieldman.tres"))


func test_art_in_memory_needs_no_catalog() -> void:
	var arts: UnitArtSet = UnitArtSet.of([TestArt.art(&"shieldman")])
	assert_not_null(arts.find(&"shieldman"))
	assert_null(arts.find(&"husk"))
	assert_push_warning_count(0)
