extends GutTest
## Veterancy: every early kill helps, each kill helps less than the one
## before, no bonus ever reaches its cap, and the bonuses really change how
## often a unit swings, how often it hits, and how fast it walks.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const HALF: int = Veterancy.HALF_CAP_KILLS

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestTerrains.catalog()


func test_curve_starts_at_zero_reaches_half_and_never_the_cap() -> void:
	assert_eq(Veterancy.bonus_permille(120, 0), 0)
	assert_eq(Veterancy.bonus_permille(0, 50), 0, "a zero cap never improves")
	assert_eq(Veterancy.bonus_permille(120, HALF), 60, "half the cap at HALF_CAP_KILLS")
	var previous: int = 0
	for kills: int in range(1, 1001):
		var bonus: int = Veterancy.bonus_permille(120, kills)
		assert_true(bonus >= previous, "never goes down (%d kills)" % kills)
		assert_lt(bonus, 120, "below the cap (%d kills)" % kills)
		previous = bonus


func test_returns_diminish() -> void:
	# Integer rounding can make one kill's gain a point bigger than the last,
	# so compare blocks of HALF kills: each earns less than the block before.
	var gains: Array[int] = []
	for block: int in 5:
		gains.append(
			Veterancy.bonus_permille(120, (block + 1) * HALF) - Veterancy.bonus_permille(120, block * HALF)
		)
	for i: int in range(1, gains.size()):
		assert_lt(gains[i], gains[i - 1], "gains per block: %s" % [gains])


func test_every_early_kill_counts_for_the_shipped_caps() -> void:
	for t: UnitType in _catalog.types:
		for cap: int in [t.veterancy_accuracy_permille, t.veterancy_attack_rate_permille, t.veterancy_speed_permille]:
			if cap == 0:
				continue
			for kills: int in 10:
				assert_gt(
					Veterancy.bonus_permille(cap, kills + 1), Veterancy.bonus_permille(cap, kills),
					"%s cap %d, kill %d" % [t.id, cap, kills + 1]
				)


func test_effective_stats() -> void:
	var shieldman: Unit = _unit(&"shieldman", 0)
	assert_eq(Veterancy.melee_accuracy(shieldman), 800)
	assert_eq(Veterancy.melee_cooldown(shieldman), 24)
	assert_eq(Veterancy.move_speed(shieldman), 2600)
	shieldman.kills = HALF
	assert_eq(Veterancy.melee_accuracy(shieldman), 800 + 60)
	assert_eq(Veterancy.melee_cooldown(shieldman), 21, "+125 permille attack rate: 24 * 1000 / 1125, rounded")
	assert_eq(Veterancy.move_speed(shieldman), 2600, "Shieldmen don't gain speed")
	var reaver: Unit = _unit(&"reaver", HALF)
	assert_eq(Veterancy.move_speed(reaver), 3200 * 1075 / 1000, "Reavers do")


func test_effective_stats_are_bounded() -> void:
	var t: UnitType = TestUnits.melee(&"ace", {
		"melee_accuracy_permille": 990, "melee_cooldown_ticks": 1,
		"veterancy_accuracy_permille": 1000, "veterancy_attack_rate_permille": 1000,
	})
	var ace: Unit = Unit.new(1, 0, 0, 0, t, 0, LIGHT)
	ace.kills = 1000
	assert_eq(Veterancy.melee_accuracy(ace), 1000, "never above 100%")
	assert_eq(Veterancy.melee_cooldown(ace), 1, "never below one tick")


func test_husks_never_improve() -> void:
	var fresh: Unit = _unit(&"husk", 0)
	var old: Unit = _unit(&"husk", 50)
	assert_eq(Veterancy.melee_accuracy(old), Veterancy.melee_accuracy(fresh))
	assert_eq(Veterancy.melee_cooldown(old), Veterancy.melee_cooldown(fresh))
	assert_eq(Veterancy.move_speed(old), Veterancy.move_speed(fresh))


func test_veteran_swings_more_often() -> void:
	var t: UnitType = TestUnits.melee(&"vet", {"veterancy_attack_rate_permille": 1000})
	var dummy: UnitType = TestUnits.dummy(&"dummy")
	var catalog: UnitCatalog = TestUnits.catalog([t, dummy] as Array[UnitType])
	var world: World = World.new(1, TestTerrains.flat(40, 40), catalog)
	var vet: Unit = world.spawn_unit(0, LIGHT, 20 * M, 20 * M, 0, 1)
	world.spawn_unit(1, UnitType.Faction.DARK, 20 * M, 20_900, 0, -1)
	vet.kills = HALF  # +500 permille rate: cooldown 10 -> 7 ticks
	var hits: Array[int] = []
	for tick: int in 40:
		world.step()
		for event: CombatEvent in world.combat_events:
			if event.kind == CombatEvent.Kind.HIT:
				hits.append(tick)
	assert_eq(hits, [5, 17, 29], "every windup 5 + cooldown 7 ticks")


func test_veteran_walks_faster() -> void:
	var distances: Array[int] = []
	for kills: int in [0, 8]:
		var world: World = World.new(1, TestTerrains.flat(80, 20), _catalog)
		var u: Unit = world.spawn_unit(_catalog.index_of(&"reaver"), LIGHT, 5 * M, 10 * M, 1, 0)
		u.kills = kills
		world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([u.id]), 75 * M, 10 * M, 0))
		world.step()
		var start: int = u.x
		for t: int in 60:
			world.step()
		distances.append(u.x - start)
	# 8 kills: speed bonus 150 * 8 / 12 = 100 permille.
	assert_almost_eq(distances[0], 2 * 3200, 3)
	assert_almost_eq(distances[1], 2 * 3200 * 1100 / 1000, 3)


func _unit(type_id: StringName, kills: int) -> Unit:
	var index: int = _catalog.index_of(type_id)
	var u: Unit = Unit.new(1, 0, 0, 0, _catalog.types[index], index, LIGHT)
	u.kills = kills
	return u
