extends GutTest
## UnitInfo: the HUD's words for the Phase 6 units and things. A Warden counts
## its herbs, a Blightbag says it bursts, a Stormcaller names its dead zone,
## a Ripper says what it carries; status effects show with the seconds left;
## errands name themselves; herb plants and loose objects say what they are.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _world: World


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(40, 40), _catalog)


func test_a_warden_counts_its_herbs() -> void:
	var warden: Unit = _spawn(&"warden", LIGHT, 10, 10)
	var lines: PackedStringArray = UnitInfo.lines(warden, _catalog, _world)
	assert_eq(lines.size(), 6, str(lines))
	assert_eq(lines[5], "Herbs: 6/6")
	warden.special_left = 2
	assert_eq(UnitInfo.lines(warden, _catalog, _world)[5], "Herbs: 2/6")


func test_a_blightbag_says_it_bursts() -> void:
	var lines: PackedStringArray = UnitInfo.lines(_spawn(&"blightbag", DARK, 10, 10), _catalog, _world)
	assert_eq(lines[lines.size() - 1], "Bursts when it dies")


func test_a_stormcaller_names_its_dead_zone() -> void:
	var lines: PackedStringArray = UnitInfo.lines(_spawn(&"stormcaller", DARK, 10, 10), _catalog, _world)
	assert_eq(lines[lines.size() - 1], "Lightning: unlimited · dead zone 8 m")


func test_a_ripper_says_what_it_carries() -> void:
	var ripper: Unit = _spawn(&"ripper", DARK, 10, 10)
	assert_eq(UnitInfo.lines(ripper, _catalog, _world).size(), 5, "empty-handed: nothing extra")
	var satchel: Projectile = _world.drop_object(_catalog.projectile_index_of(&"satchel"), 10 * M, 10 * M, 0)
	Interactions.take(_world, ripper, satchel)
	var lines: PackedStringArray = UnitInfo.lines(ripper, _catalog, _world)
	assert_eq(lines[lines.size() - 1], "Carrying: Satchel charge")


func test_status_effects_show_with_the_time_left() -> void:
	var unit: Unit = _spawn(&"shieldman", LIGHT, 10, 10)
	StatusEffects.apply(_world, unit, StatusEffects.Kind.PARALYSIS, 69, 0)
	StatusEffects.apply(_world, unit, StatusEffects.Kind.BURNING, 30, 0)
	assert_eq(UnitInfo.status_line(unit, _world), "Paralyzed 2.3 s · Burning 1.0 s")
	var lines: PackedStringArray = UnitInfo.lines(unit, _catalog, _world)
	assert_eq(lines[5], "Paralyzed 2.3 s · Burning 1.0 s", "after the five standing lines")
	assert_eq(UnitInfo.lines(unit, _catalog).size(), 5, "no world, no statuses")


func test_errands_name_themselves() -> void:
	var warden: Unit = _spawn(&"warden", LIGHT, 10, 10)
	var friend: Unit = _spawn(&"shieldman", LIGHT, 20, 10)
	friend.hp = 10
	_world.enqueue(HealCommand.new(0, PackedInt32Array([warden.id]), friend.id))
	_world.step()
	assert_eq(UnitInfo.activity(warden, _world), "Healing")
	var plant: HerbPlant = _world.spawn_herb_plant(10 * M, 30 * M)
	var shieldman: Unit = _spawn(&"shieldman", LIGHT, 5, 25)
	_world.enqueue(InteractCommand.new(_world.tick, PackedInt32Array([shieldman.id]), plant.id))
	_world.step()
	assert_eq(UnitInfo.activity(shieldman, _world), "Gathering herbs")


func test_things_say_what_they_are() -> void:
	var plant: HerbPlant = _world.spawn_herb_plant(10 * M, 10 * M)
	assert_eq(UnitInfo.describe_thing(plant), "Herb plant\nStrike it for herbs")
	plant.spent = true
	assert_eq(UnitInfo.describe_thing(plant), "Herb plant (spent)")
	var herb: Projectile = _world.drop_object(_catalog.projectile_index_of(&"herb"), 10 * M, 10 * M, 0)
	assert_eq(UnitInfo.describe_thing(herb), "Healing herb\nA Warden picks it up")
	var packet: Projectile = _world.drop_object(_catalog.projectile_index_of(&"gas_packet"), 10 * M, 10 * M, 0)
	assert_eq(UnitInfo.describe_thing(packet), "Gas packet\nA Ripper can throw it")
	var satchel: Projectile = _world.drop_object(_catalog.projectile_index_of(&"satchel"), 10 * M, 10 * M, 0)
	Explosions.catch(_world, satchel, 0)
	assert_true(UnitInfo.describe_thing(satchel).begins_with("Satchel charge — about to go off"))


func _spawn(type_id: StringName, side: UnitType.Faction, x: int, z: int) -> Unit:
	return _world.spawn_unit(_catalog.index_of(type_id), side, x * M, z * M, 1, 0)
