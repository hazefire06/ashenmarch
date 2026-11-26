extends GutTest
## SpottingMemory: ids spotted now, and fading marks where enemies left sight.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const M: int = 1000

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"scout", {"sight_radius": 30000}),
		TestUnits.dummy(&"foe"),
	]
	_catalog = TestUnits.catalog(types)


func _put(world: World, type_index: int, side: UnitType.Faction, x_m: int) -> Unit:
	var u: Unit = world.spawn_unit(type_index, side, x_m * M, 10 * M, 0, -1)
	u.x = x_m * M
	u.z = 10 * M
	return u


## A scout at 5 m and a foe at 25 m; moving the foe to 60 m takes it out of sight.
func _scene() -> Dictionary:
	var w: World = World.new(1, TestTerrains.flat(80, 20), _catalog)
	_put(w, 0, LIGHT, 5)
	return {"world": w, "foe": _put(w, 1, DARK, 25)}


## A full refresh: every enemy is re-evaluated once.
func _refresh(mem: SpottingMemory, world: World) -> void:
	for i: int in SpottingMemory.REFRESH_UPDATES:
		mem.update(world, LIGHT)


## Spotted, then moved out of sight at the given tick and refreshed.
func _lose_sight(mem: SpottingMemory, scene: Dictionary, at_tick: int = 100) -> void:
	var w: World = scene["world"]
	var foe: Unit = scene["foe"]
	_refresh(mem, w)
	foe.x = 60 * M
	w.tick = at_tick
	_refresh(mem, w)


func test_an_enemy_that_dives_between_refreshes_leaves_its_dot_at_once() -> void:
	var diver_types: Array[UnitType] = [
		TestUnits.melee(&"scout", {"sight_radius": 30000}),
		TestUnits.dummy(&"diver", {"hidden_in_deep_water": true}),
	]
	var rows: Array[String] = []
	for j: int in 20:
		rows.append(".".repeat(22) + "333" + ".".repeat(55))
	var w: World = World.new(1, TestTerrains.from_ascii(rows), TestUnits.catalog(diver_types))
	_put(w, 0, LIGHT, 5)
	var diver: Unit = _put(w, 1, DARK, 18)
	var mem: SpottingMemory = SpottingMemory.new()
	_refresh(mem, w)
	assert_eq(mem.spotted().size(), 1, "spotted on dry ground")
	# The next update is not the diver's turn to be re-evaluated.
	mem.update(w, LIGHT)
	diver.x = 23 * M
	assert_false(Visibility.seen_by(w, diver, LIGHT), "submerged now")
	mem.update(w, LIGHT)
	assert_eq(mem.spotted().size(), 0, "its dot goes on the next update, its turn or not")
	assert_eq(mem.marks().size(), 1, "leaving a mark where it was seen")


func test_spotted_lists_visible_enemies() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_refresh(mem, s["world"])
	assert_eq(mem.spotted(), PackedInt32Array([(s["foe"] as Unit).id]))
	assert_eq(mem.marks().size(), 0)


func test_mark_fades_over_300_ticks_from_the_last_sighting() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_lose_sight(mem, s, 0)
	var marks: Array[Dictionary] = mem.marks()
	assert_eq(marks.size(), 1)
	assert_eq(marks[0]["position"], Vector2(25, 10))
	assert_almost_eq(marks[0]["alpha"] as float, 1.0, 0.001)
	var w: World = s["world"]
	w.tick = 150
	_refresh(mem, w)
	assert_almost_eq(mem.marks()[0]["alpha"] as float, 0.5, 0.001)
	w.tick = 300
	_refresh(mem, w)
	assert_eq(mem.marks().size(), 0)


func test_alpha_never_exceeds_one_when_the_tick_goes_back() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_lose_sight(mem, s, 100)
	(s["world"] as World).tick = 0
	_refresh(mem, s["world"])
	for m: Dictionary in mem.marks():
		assert_true((m["alpha"] as float) <= 1.0)


func test_respotting_drops_the_mark() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_lose_sight(mem, s)
	(s["foe"] as Unit).x = 25 * M
	_refresh(mem, s["world"])
	assert_eq(mem.marks().size(), 0)
	assert_eq(mem.spotted().size(), 1)


func test_death_drops_the_mark() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_lose_sight(mem, s)
	(s["foe"] as Unit).kill()
	mem.update(s["world"], LIGHT)
	assert_eq(mem.marks().size(), 0)


func test_death_drops_a_spotted_enemy_at_once() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_refresh(mem, s["world"])
	(s["foe"] as Unit).kill()
	mem.update(s["world"], LIGHT)
	assert_eq(mem.spotted().size(), 0)
	assert_eq(mem.marks().size(), 0)


func test_clear_forgets_everything() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_lose_sight(mem, s)
	mem.clear()
	assert_eq(mem.marks().size(), 0)
	assert_eq(mem.spotted().size(), 0)


func test_round_robin_covers_every_enemy_within_four_updates() -> void:
	var w: World = World.new(1, TestTerrains.flat(80, 20), _catalog)
	_put(w, 0, LIGHT, 5)
	for i: int in 9:
		_put(w, 1, DARK, 15 + i)
	var mem: SpottingMemory = SpottingMemory.new()
	mem.update(w, LIGHT)
	assert_lt(mem.spotted().size(), 9, "one update is only a share of them")
	for i: int in SpottingMemory.REFRESH_UPDATES - 1:
		mem.update(w, LIGHT)
	assert_eq(mem.spotted().size(), 9)


func test_a_spotted_dot_follows_the_unit_between_refreshes() -> void:
	var s: Dictionary = _scene()
	var mem: SpottingMemory = SpottingMemory.new()
	_refresh(mem, s["world"])
	(s["foe"] as Unit).x = 26 * M
	mem.update(s["world"], LIGHT)
	assert_eq(mem.spotted().size(), 1)
