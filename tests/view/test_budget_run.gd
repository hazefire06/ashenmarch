extends GutTest
## The budget check's parts: when it is asked for, the worst case it plays,
## and its line and verdict. The memory numbers themselves come from real
## runs (docs/specs/2026-10-15-art-a4-loading-design.md §6).


func _units() -> UnitCatalog:
	return load(App.CATALOG_PATH) as UnitCatalog


func _skirmishes() -> SkirmishCatalog:
	return load(App.SKIRMISH_PATH) as SkirmishCatalog


func _fields() -> Dictionary:
	return {
		"js_bytes": 400e6, "how": "measured", "video": 200e6, "textures": 190e6, "static": 50e6,
		"art": 188e6, "types": 10, "art_load_ms": 850, "pck": 196e6, "wire": 60e6, "s3tc": true,
		"ticks": 1800, "seconds": 61,
	}


func test_the_page_asks_with_budget_1() -> void:
	assert_true(BudgetRun.asked_in_query("?budget=1"))
	assert_true(BudgetRun.asked_in_query("?verify=0&budget=yes"))
	assert_false(BudgetRun.asked_in_query(""))
	assert_false(BudgetRun.asked_in_query("?budget=0"))
	assert_false(BudgetRun.asked_in_query("?budget"))
	assert_false(BudgetRun.asked_in_query("?budgets=1"))


func test_the_worst_case_fields_every_buyable_type_on_old_mill() -> void:
	var units: UnitCatalog = _units()
	var setup: SkirmishSetup = BudgetRun.worst_case_setup(units, _skirmishes())
	assert_eq(setup.validate(units), PackedStringArray())
	assert_eq(setup.map.id, &"old_mill")
	assert_true(setup.player_is_ai, "AI against AI")
	var fielded: Array[StringName] = []
	for army: Army in setup.armies:
		for type_id: StringName in army.counts:
			assert_eq(army.count_of(type_id), BudgetRun.EACH, "%s" % type_id)
			fielded.append(type_id)
	for type: UnitType in units.types:
		if type.cost > 0:
			assert_has(fielded, type.id)
	assert_eq(fielded.size(), 10, "the ten v1 types; the villager is not for sale")


func test_the_verdict() -> void:
	assert_eq(BudgetRun.verdict(999.6), "PASS")
	assert_eq(BudgetRun.verdict(1000.0), "PASS")
	assert_eq(BudgetRun.verdict(1000.4), "FAIL")
	assert_eq(BudgetRun.verdict(-1.0), "UNKNOWN")


func test_the_web_line_adds_the_page_and_the_gpu() -> void:
	assert_eq(
		BudgetRun.web_line(_fields()),
		"BUDGET tab=600 limit=1000 PASS js_wasm=400 (measured) video=200 textures=190 art=188 types=10"
		+ " art_load=850 pck=196 wire=60 s3tc=yes ticks=1800 seconds=61 on=web"
	)


func test_an_unread_page_is_unknown_not_a_pass() -> void:
	var f: Dictionary = _fields()
	f["js_bytes"] = -1.0
	f["how"] = "unknown"
	assert_string_contains(BudgetRun.web_line(f), "tab=-1 limit=1000 UNKNOWN js_wasm=-1 (unknown)")


func test_the_desktop_line_has_no_verdict() -> void:
	var line: String = BudgetRun.desktop_line(_fields())
	assert_string_starts_with(line, "BUDGET video=200 textures=190 static=50 art=188 types=10 art_load=850 ticks=1800 seconds=61 on=")
	assert_false(line.contains("PASS"))


func test_a_short_run_plays_and_prints_a_line() -> void:
	var run: BudgetRun = BudgetRun.new()
	run.catalog = _units()
	run.skirmish = _skirmishes()
	run.play_ticks = 3
	add_child_autofree(run)
	run.start()
	await wait_for_signal(run.finished, 20)
	assert_string_starts_with(run.line, "BUDGET video=")
	assert_gte(run.main.world.tick, 3)
	assert_eq(run.main.loaded_arts().size(), 10, "every v1 type's art is on the field")
