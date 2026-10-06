extends GutTest
## MissionStats: the observer behind the results screen. It never touches the
## sim; it reads a world after each step. These tests script small fights on
## flat ground with target-dummy enemies, so only the numbers under test move.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const SHIELD: int = 0
const SAPPER: int = 1
const HUSK: int = 2
const RIPPER: int = 3
const BRUTE: int = 4

var _catalog: UnitCatalog


func before_all() -> void:
	# A grenade that bursts where it lands and never fizzles, thrown with no
	# spread: the blast is exactly where the Sapper was told to throw it.
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"fizzle_permille": 0, "bursts_on_impact": true})
	var satchel: ProjectileType = TestUnits.projectile(&"satchel")
	var types: Array[UnitType] = [
		TestUnits.melee(&"shieldman"),
		TestUnits.thrower(&"sapper", {"ranged_ammo": 1}),
		TestUnits.dummy(&"husk", {"max_hp": 20}),
		TestUnits.dummy(&"ripper", {"max_hp": 20}),
		TestUnits.melee(&"brute"),
	]
	_catalog = TestUnits.catalog(types, [grenade, satchel])


# --- fixtures ---------------------------------------------------------------


func _world() -> World:
	return World.new(1, TestTerrains.flat(60, 40), _catalog)


## A unit standing at (x, z) metres, as campaign soldier `soldier_id` (0: not
## one) with these kills.
func _unit(w: World, type_index: int, side: UnitType.Faction, x: int, z: int, soldier_id: int = 0, kills: int = 0) -> Unit:
	var u: Unit = w.spawn_unit(type_index, side, x * M, z * M, 1, 0)
	u.soldier_id = soldier_id
	u.kills = kills
	return u


## One step, so a world's spawns have settled, then `begin`.
func _begun(w: World) -> MissionStats:
	w.step()
	var stats: MissionStats = MissionStats.new()
	stats.begin(w)
	return stats


## Steps up to `limit` ticks, observing each, until `done` is true.
func _run(w: World, stats: MissionStats, done: Callable, limit: int = 600) -> void:
	for _t: int in limit:
		if done.call():
			return
		w.step()
		stats.observe(w)


func _ids(values: PackedInt32Array) -> Array[int]:
	var out: Array[int] = []
	out.assign(values)
	return out


# --- a scripted fight -------------------------------------------------------


func test_kills_this_mission_are_what_a_soldier_ended_with_minus_what_he_deployed_with() -> void:
	var w: World = _world()
	var veteran: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 11, 5)
	var recruit: Unit = _unit(w, SHIELD, LIGHT, 30, 20, 12, 0)
	var idle: Unit = _unit(w, SHIELD, LIGHT, 45, 30, 13, 2)
	var husk: Unit = _unit(w, HUSK, DARK, 21, 20)
	var ripper: Unit = _unit(w, RIPPER, DARK, 31, 20)
	var stats: MissionStats = _begun(w)
	_run(w, stats, func() -> bool: return not husk.is_alive() and not ripper.is_alive())
	stats.finish(w)
	assert_false(husk.is_alive())
	assert_false(ripper.is_alive())
	assert_eq(veteran.kills, 6, "the world's count includes the five he came with")
	assert_eq(stats.kills_of(11), 1, "this mission's: 6 - 5")
	assert_eq(stats.kills_of(12), 1)
	assert_eq(stats.kills_of(13), 0, "he fought no one")
	assert_eq(idle.kills, 2)
	assert_eq(stats.kills_of(99), 0, "a soldier who wasn't there made none")
	assert_eq(recruit.kills, 1)


func test_enemy_dead_are_counted_by_type_from_the_bodies_in_the_world() -> void:
	var w: World = _world()
	_unit(w, SHIELD, LIGHT, 20, 20, 11)
	_unit(w, SHIELD, LIGHT, 30, 20, 12)
	var husk_a: Unit = _unit(w, HUSK, DARK, 21, 20)
	var ripper: Unit = _unit(w, RIPPER, DARK, 31, 20)
	var husk_alive: Unit = _unit(w, HUSK, DARK, 50, 35)
	var husk_b: Unit = _unit(w, HUSK, DARK, 52, 35)
	husk_b.kill()
	var stats: MissionStats = _begun(w)
	_run(w, stats, func() -> bool: return not husk_a.is_alive() and not ripper.is_alive())
	stats.finish(w)
	assert_true(husk_alive.is_alive())
	assert_eq(stats.enemy_dead.size(), 2)
	assert_eq(stats.enemy_dead[&"husk"], 2, "killed in the fight, and the one that was dead already")
	assert_eq(stats.enemy_dead[&"ripper"], 1)
	assert_eq(stats.enemies_killed(), 3)


func test_an_enemy_that_died_to_no_ones_credit_still_counts() -> void:
	var w: World = _world()
	_unit(w, SHIELD, LIGHT, 5, 5, 11)
	var victim: Unit = _unit(w, HUSK, DARK, 30, 30)
	var stats: MissionStats = _begun(w)
	Damage.apply(w, victim, 999, 0, 0, 0)
	stats.observe(w)
	stats.finish(w)
	assert_eq(stats.enemies_killed(), 1)


func test_the_end_tick_is_when_finish_was_called() -> void:
	var w: World = _world()
	_unit(w, SHIELD, LIGHT, 20, 20, 11)
	var stats: MissionStats = _begun(w)
	for _t: int in 89:
		w.step()
		stats.observe(w)
	stats.finish(w)
	assert_eq(stats.end_tick, 90)
	assert_eq(stats.end_tick, w.tick)
	assert_eq(stats.seconds(), 3, "at 30 ticks a second")


func test_an_enemy_that_kills_a_soldier_is_a_loss_but_not_friendly_fire() -> void:
	var w: World = _world()
	var doomed: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 21)
	doomed.hp = 5
	_unit(w, SHIELD, LIGHT, 50, 30, 22)
	_unit(w, BRUTE, DARK, 21, 20)
	var stats: MissionStats = _begun(w)
	_run(w, stats, func() -> bool: return not doomed.is_alive())
	stats.finish(w)
	assert_false(doomed.is_alive())
	assert_eq(_ids(stats.lost), [21])
	assert_true(stats.was_lost(21))
	assert_false(stats.was_lost(22))
	assert_true(stats.friendly_fire.is_empty())
	assert_false(stats.was_friendly_fire(21))


func test_a_grenade_that_kills_a_comrade_is_friendly_fire() -> void:
	var w: World = _world()
	var sapper: Unit = _unit(w, SAPPER, LIGHT, 10, 20, 31)
	var friend: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 32)
	friend.hp = 1
	# Standing near the blast, but at full health: he survives.
	var bystander: Unit = _unit(w, SHIELD, LIGHT, 22, 21, 33)
	var stats: MissionStats = _begun(w)
	w.enqueue(GroundAttackCommand.new(w.tick, PackedInt32Array([sapper.id]), 20 * M, 20 * M))
	_run(w, stats, func() -> bool: return not friend.is_alive())
	stats.finish(w)
	assert_false(friend.is_alive(), "the blast reached him")
	assert_true(bystander.is_alive())
	assert_eq(_ids(stats.friendly_fire), [32])
	assert_true(stats.was_friendly_fire(32))
	assert_false(stats.was_friendly_fire(33))
	assert_eq(_ids(stats.lost), [32], "a friendly-fire death is still a loss")
	assert_eq(stats.kills_of(31), 0, "and earns the Sapper nothing")
	assert_eq(stats.enemies_killed(), 0)


func test_every_way_a_soldier_can_die_is_sorted_into_friendly_fire_or_not() -> void:
	var w: World = _world()
	var by_friend: Unit = _unit(w, SHIELD, LIGHT, 5, 5, 41)
	var by_nobody: Unit = _unit(w, SHIELD, LIGHT, 10, 5, 42)
	var by_enemy: Unit = _unit(w, SHIELD, LIGHT, 15, 5, 43)
	var by_himself: Unit = _unit(w, SHIELD, LIGHT, 20, 5, 44)
	var by_a_soldier: Unit = _unit(w, SHIELD, LIGHT, 25, 5, 45)
	var friend: Unit = _unit(w, SHIELD, LIGHT, 40, 30)
	var killer_soldier: Unit = _unit(w, SHIELD, LIGHT, 45, 30, 46)
	var enemy: Unit = _unit(w, HUSK, DARK, 50, 30)
	var stats: MissionStats = _begun(w)
	Damage.apply(w, by_friend, 999, 0, 0, friend.id)
	Damage.apply(w, by_nobody, 999, 0, 0, 0)
	Damage.apply(w, by_enemy, 999, 0, 0, enemy.id)
	Damage.self_destruct(w, by_himself)
	Damage.apply(w, by_a_soldier, 999, 0, 0, killer_soldier.id)
	stats.observe(w)
	stats.finish(w)
	assert_eq(_ids(stats.lost), [41, 42, 43, 44, 45])
	assert_eq(_ids(stats.friendly_fire), [41, 42, 44, 45], "a friend, no one (fire, a stray charge), himself, a soldier")
	assert_false(stats.was_friendly_fire(43), "an enemy's blow is just a loss")


func test_only_campaign_soldiers_and_light_victims_are_tracked() -> void:
	var w: World = _world()
	var villager: Unit = _unit(w, SHIELD, LIGHT, 5, 5)
	var husk: Unit = _unit(w, HUSK, DARK, 10, 5)
	var friend: Unit = _unit(w, SHIELD, LIGHT, 40, 30, 51)
	var stats: MissionStats = _begun(w)
	Damage.apply(w, villager, 999, 0, 0, friend.id)
	Damage.apply(w, husk, 999, 0, 0, 0)
	stats.observe(w)
	stats.finish(w)
	assert_true(stats.lost.is_empty(), "a Light unit with no soldier id isn't a soldier")
	assert_true(stats.friendly_fire.is_empty(), "nor is a dead Husk a friendly-fire victim")
	assert_eq(stats.enemies_killed(), 1)


func test_a_soldier_converted_to_the_dark_is_lost_and_not_an_enemy_dead() -> void:
	var w: World = _world()
	var turned: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 61)
	_unit(w, SHIELD, LIGHT, 30, 20, 62)
	var stats: MissionStats = _begun(w)
	turned.faction = DARK
	stats.finish(w)
	assert_eq(_ids(stats.lost), [61])
	assert_eq(stats.enemies_killed(), 0, "alive")
	turned.kill()
	var again: MissionStats = MissionStats.new()
	again.begin(w)
	again.finish(w)
	assert_eq(_ids(again.lost), [61])
	assert_eq(again.enemies_killed(), 0, "a soldier who died on the Dark side is still ours to mourn, not a kill")


func test_a_dead_soldiers_kills_still_count_and_the_living_are_not_losses() -> void:
	var w: World = _world()
	var fallen: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 71, 3)
	var standing: Unit = _unit(w, SHIELD, LIGHT, 30, 20, 72)
	var stats: MissionStats = _begun(w)
	fallen.kills += 2
	fallen.kill()
	stats.finish(w)
	assert_eq(stats.kills_of(71), 2)
	assert_eq(_ids(stats.lost), [71])
	assert_true(standing.is_alive())
	assert_false(stats.was_lost(72))


func test_a_soldier_who_dies_is_only_counted_once_when_observed_twice() -> void:
	var w: World = _world()
	var victim: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 81)
	var friend: Unit = _unit(w, SHIELD, LIGHT, 30, 20, 82)
	var stats: MissionStats = _begun(w)
	Damage.apply(w, victim, 999, 0, 0, friend.id)
	stats.observe(w)
	stats.observe(w)
	stats.finish(w)
	assert_eq(_ids(stats.friendly_fire), [81])
	assert_eq(_ids(stats.lost), [81])


func test_begin_starts_over() -> void:
	var w: World = _world()
	var victim: Unit = _unit(w, SHIELD, LIGHT, 20, 20, 91)
	var friend: Unit = _unit(w, SHIELD, LIGHT, 30, 20, 92, 4)
	var stats: MissionStats = _begun(w)
	Damage.apply(w, victim, 999, 0, 0, friend.id)
	stats.observe(w)
	stats.finish(w)
	assert_false(stats.lost.is_empty())
	var w2: World = _world()
	_unit(w2, SHIELD, LIGHT, 20, 20, 93)
	w2.step()
	stats.begin(w2)
	stats.finish(w2)
	assert_true(stats.lost.is_empty())
	assert_true(stats.friendly_fire.is_empty())
	assert_true(stats.enemy_dead.is_empty())
	assert_eq(stats.kills_of(92), 0)
	assert_eq(stats.end_tick, w2.tick)


func test_soldiers_deployed_by_command_are_read_the_same_way() -> void:
	var w: World = _world()
	var ids: Array[StringName] = [&"shieldman", &"shieldman"]
	w.enqueue(DeployCommand.new(
		0, ids, PackedInt32Array([5, 6]), PackedInt32Array([4, 0]), PackedInt32Array([0, 0]),
		30 * M, 20 * M, 1, 0
	))
	var husk: Unit = _unit(w, HUSK, DARK, 0, 0)
	w.step()
	var stats: MissionStats = MissionStats.new()
	stats.begin(w)
	var first: Unit = CampaignFixtures.unit_of(w, 5)
	var second: Unit = CampaignFixtures.unit_of(w, 6)
	husk.x = first.x + 1000
	husk.z = first.z
	_run(w, stats, func() -> bool: return not husk.is_alive())
	stats.finish(w)
	assert_false(husk.is_alive())
	assert_eq(stats.kills_of(5), first.kills - 4, "the four he deployed with don't count")
	assert_eq(stats.kills_of(6), second.kills)
	assert_eq(stats.kills_of(5) + stats.kills_of(6), 1, "one Husk, one kill, whoever landed it")
