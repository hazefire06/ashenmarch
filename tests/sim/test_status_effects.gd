extends GutTest
## Status effects: Paralysis stops a unit doing anything (and its shield),
## Confusion makes it fight the nearest unit of either side until it wears
## off and the unit resumes its order, Burning hurts on an interval until
## water puts it out. Effects refresh rather than stack, are hashed, and go
## with the unit when it dies. Also the paralyzing touch, a fire arrow setting
## its target alight, and a melee blow spoiling a draw.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const PARALYSIS: StatusEffects.Kind = StatusEffects.Kind.PARALYSIS
const CONFUSION: StatusEffects.Kind = StatusEffects.Kind.CONFUSION
const BURNING: StatusEffects.Kind = StatusEffects.Kind.BURNING

## Catalog indices of the synthetic types.
const BRAWLER: int = 0
const DUMMY: int = 1
const SHIELDED: int = 2
const FRAGILE: int = 3
const ARCHER: int = 4
const TOUCHER: int = 5
const CASTER: int = 6

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"brawler"),
		TestUnits.dummy(&"dummy"),
		TestUnits.dummy(&"shielded", {"shield_block_permille": 1000}),
		TestUnits.dummy(&"fragile", {"max_hp": 15}),
		TestUnits.ranged(&"archer", {
			"special_ability": UnitType.Special.FIRE_ARROW, "special_charges": 1,
			"special_projectile": &"fire_arrow",
		}),
		TestUnits.melee(&"toucher", {
			"melee_status": StatusEffects.Kind.PARALYSIS, "melee_status_ticks": 45,
		}),
		# Shoots, with a long draw, and has no melee at all.
		TestUnits.ranged(&"caster", {
			"melee_damage": 0, "melee_accuracy_permille": 0, "melee_reach": 0,
			"melee_windup_ticks": 0, "melee_cooldown_ticks": 0, "acquire_radius": 0,
			"ranged_windup_ticks": 30,
		}),
	]
	_catalog = TestUnits.catalog(types)


# --- Paralysis

func test_paralysis_freezes_a_walker_until_it_wears_off() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 10 * M, 20 * M, 1, 0)
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([unit.id]), 30 * M, 20 * M, 0))
	world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([unit.id]), PARALYSIS, 30))
	_run(world, 30)
	assert_eq(unit.x, 10 * M, "not a step while paralyzed")
	assert_eq(unit.state, Unit.State.MOVING, "the order waits")
	assert_eq(StatusEffects.ticks_left(world, unit, PARALYSIS), 0, "worn off after 30 ticks")
	_run(world, 15 * World.TICK_RATE)
	assert_almost_eq(unit.x, 30 * M, 300, "and it got there afterwards")


func test_paralysis_loses_the_swing_and_stops_the_blows() -> void:
	var world: World = _world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	world.spawn_unit(DUMMY, DARK, 20 * M, 20_900, 0, -1)
	_run(world, 2)
	assert_gt(a.windup_left, 0, "mid-swing")
	world.enqueue(ApplyStatusCommand.new(world.tick, PackedInt32Array([a.id]), PARALYSIS, 60))
	world.step()
	assert_eq(a.windup_left, 0, "the swing is lost")
	var hits: Array[int] = _hit_ticks(world, a, 100)
	assert_false(hits.is_empty(), "it fights again once it can")
	assert_gte(hits[0], 2 + 60, "no blow lands while paralyzed, not even the one it was winding up")


func test_a_paralyzed_unit_cannot_block() -> void:
	var world: World = _world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 0, 1)
	var shield: Unit = world.spawn_unit(SHIELDED, DARK, 20 * M, 20_900, 0, -1)
	var kinds: Array[CombatEvent.Kind] = _event_kinds(world, a, 60)
	assert_false(kinds.has(CombatEvent.Kind.HIT), "every frontal blow blocked")
	world.enqueue(ApplyStatusCommand.new(world.tick, PackedInt32Array([shield.id]), PARALYSIS, 300))
	kinds = _event_kinds(world, a, 60)
	assert_true(kinds.has(CombatEvent.Kind.HIT), "the shield is down")
	assert_false(kinds.has(CombatEvent.Kind.BLOCK))


func test_a_paralyzed_archer_does_not_shoot() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(DUMMY, DARK, 30 * M, 20 * M, -1, 0)
	world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([archer.id]), PARALYSIS, 90))
	assert_eq(_count_launches(world, 90), 0)
	assert_gt(_count_launches(world, 90), 0, "and shoots once it can")


func test_a_paralyzing_touch() -> void:
	var world: World = _world()
	world.spawn_unit(TOUCHER, LIGHT, 20 * M, 20 * M, 0, 1)
	var victim: Unit = world.spawn_unit(BRAWLER, DARK, 20 * M, 20_900, 0, -1)
	_run(world, 6)
	assert_lt(victim.hp, victim.type.max_hp, "struck once")
	assert_true(StatusEffects.paralyzed(world, victim))
	assert_eq(StatusEffects.ticks_left(world, victim, PARALYSIS), 45 - 1)


# --- Confusion

func test_a_confused_unit_attacks_the_nearest_unit_even_a_friend() -> void:
	var world: World = _world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(FRAGILE, LIGHT, 21 * M, 20 * M, -1, 0)
	var enemy: Unit = world.spawn_unit(DUMMY, DARK, 25 * M, 20 * M, -1, 0)
	world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([a.id]), CONFUSION, 150))
	_run(world, 60)
	assert_false(friend.is_alive(), "cut down by its own side")
	assert_eq(a.kills, 0, "no credit for killing a friend")
	assert_eq(a.target_id, enemy.id, "then the next nearest")


func test_a_unit_in_its_right_mind_leaves_friends_alone() -> void:
	var world: World = _world()
	world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(FRAGILE, LIGHT, 21 * M, 20 * M, -1, 0)
	_run(world, 60)
	assert_eq(friend.hp, friend.type.max_hp)


func test_confusion_wears_off_and_the_unit_resumes_its_move() -> void:
	var world: World = _world()
	var a: Unit = world.spawn_unit(BRAWLER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 9 * M, 20 * M, 1, 0)
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([a.id]), 30 * M, 20 * M, 0))
	world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([a.id]), CONFUSION, 60))
	_run(world, 60)
	assert_eq(a.target_id, friend.id, "turned on the friend behind it")
	assert_lt(friend.hp, friend.type.max_hp)
	world.step()
	assert_eq(a.target_id, 0, "dropped the fight when it wore off")
	assert_eq(a.order, Unit.Order.MOVE, "the move order was kept")
	_run(world, 15 * World.TICK_RATE)
	assert_almost_eq(a.x, 30 * M, 500, "and carried out")
	var hp: int = friend.hp
	_run(world, 60)
	assert_eq(friend.hp, hp, "and the friend is left alone")


func test_a_confused_archer_shoots_a_friend() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 20 * M, 20 * M, -1, 0)
	assert_eq(_count_launches(world, 60), 0, "nothing to shoot")
	world.enqueue(ApplyStatusCommand.new(world.tick, PackedInt32Array([archer.id]), CONFUSION, 300))
	assert_gt(_count_launches(world, 90), 0)
	assert_lt(friend.hp, friend.type.max_hp)


func test_a_confused_ground_attacker_shoots_the_unit_not_the_spot() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 20 * M, 20 * M, -1, 0)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([archer.id]), 10 * M, 35 * M))
	world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([archer.id]), CONFUSION, 300))
	var sticks: int = 0
	for _t: int in 150:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			sticks += 1 if e.kind == ProjectileEvent.Kind.STICK else 0
	assert_lt(friend.hp, friend.type.max_hp, "it shot the friend it faced")
	assert_eq(sticks, 0, "and nothing into the ground spot")


# --- Burning

func test_burning_hurts_every_interval_and_water_puts_it_out() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(20) + "1".repeat(20))
	var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	var dry: Unit = world.spawn_unit(DUMMY, LIGHT, 10 * M, 20 * M, 1, 0)
	var wet: Unit = world.spawn_unit(DUMMY, LIGHT, 30 * M, 20 * M, 1, 0)
	world.enqueue(ApplyStatusCommand.new(0, PackedInt32Array([dry.id, wet.id]), BURNING, 100))
	var hits: Array[int] = []
	for t: int in 120:
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.target_id == dry.id and e.kind == CombatEvent.Kind.HIT:
				hits.append(t)
				assert_eq(e.damage, StatusEffects.BURN_DAMAGE)
	assert_eq(hits, [0, 10, 20, 30, 40, 50, 60, 70, 80, 90], "every tenth tick through its last, 99")
	assert_eq(wet.hp, wet.type.max_hp, "standing in water, it never burned")
	assert_false(StatusEffects.has(world, wet, BURNING))


func test_a_fire_arrow_sets_its_target_alight() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 10 * M, 20 * M, 1, 0)
	var target: Unit = world.spawn_unit(DUMMY, DARK, 30 * M, 20 * M, -1, 0)
	world.enqueue(UseSpecialCommand.new(0, PackedInt32Array([archer.id])))
	for _t: int in 90:
		world.step()
		if StatusEffects.has(world, target, BURNING):
			break
	assert_true(StatusEffects.has(world, target, BURNING))
	assert_eq(target.burn_credit_id, archer.id, "credited to the archer")
	assert_eq(StatusEffects.ticks_left(world, target, BURNING), StatusEffects.FIRE_ARROW_BURN_TICKS - 1)


# --- Common rules

func test_effects_refresh_rather_than_stack() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(DUMMY, LIGHT, 10 * M, 20 * M, 1, 0)
	StatusEffects.apply(world, unit, PARALYSIS, 30, 0)
	StatusEffects.apply(world, unit, PARALYSIS, 10, 0)
	assert_eq(StatusEffects.ticks_left(world, unit, PARALYSIS), 30, "a shorter one doesn't cut it")
	StatusEffects.apply(world, unit, PARALYSIS, 50, 0)
	assert_eq(StatusEffects.ticks_left(world, unit, PARALYSIS), 50, "a longer one extends it")
	StatusEffects.apply(world, unit, BURNING, 50, 7)
	StatusEffects.apply(world, unit, BURNING, 10, 9)
	assert_eq(unit.burn_credit_id, 9, "the latest fire gets the credit")


func test_a_body_sheds_its_effects() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(DUMMY, LIGHT, 10 * M, 20 * M, 1, 0)
	StatusEffects.apply(world, unit, BURNING, 300, 0)
	StatusEffects.apply(world, unit, CONFUSION, 300, 0)
	Damage.apply(world, unit, 1_000_000, 0, 0, 0)
	assert_false(StatusEffects.has(world, unit, BURNING))
	assert_false(StatusEffects.has(world, unit, CONFUSION))
	StatusEffects.apply(world, unit, PARALYSIS, 30, 0)
	assert_false(StatusEffects.paralyzed(world, unit), "nothing takes on a body")


func test_damage_to_a_body_does_nothing() -> void:
	var world: World = _world()
	var killer: Unit = world.spawn_unit(BRAWLER, LIGHT, 5 * M, 20 * M, 1, 0)
	var unit: Unit = world.spawn_unit(DUMMY, DARK, 10 * M, 20 * M, 1, 0)
	assert_true(Damage.apply(world, unit, 1_000_000, 0, 0, killer.id))
	assert_false(Damage.apply(world, unit, 10, 0, 0, killer.id), "it's already dead")
	assert_eq(killer.kills, 1, "one kill, not two")


func test_status_effects_are_hashed() -> void:
	var a: World = _world()
	var b: World = _world()
	for w: World in [a, b]:
		w.spawn_unit(DUMMY, LIGHT, 10 * M, 20 * M, 1, 0)
	assert_eq(a.state_hash(), b.state_hash())
	StatusEffects.apply(a, a.units[0], CONFUSION, 30, 0)
	assert_ne(a.state_hash(), b.state_hash())


# --- Melee spoils a draw

func test_a_melee_blow_spoils_a_draw() -> void:
	# The caster has no melee of its own, so only the blows can stop it.
	var quiet: World = _world()
	quiet.spawn_unit(CASTER, LIGHT, 10 * M, 20 * M, 1, 0)
	quiet.spawn_unit(DUMMY, DARK, 30 * M, 20 * M, -1, 0)
	assert_gt(_count_launches(quiet, 120), 0, "left alone, it casts")
	var world: World = _world()
	world.spawn_unit(CASTER, LIGHT, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(DUMMY, DARK, 30 * M, 20 * M, -1, 0)
	world.spawn_unit(BRAWLER, DARK, 10 * M, 20_900, 0, -1)
	assert_eq(_count_launches(world, 120), 0, "a blow every 15 ticks never lets a 30-tick draw finish")


# --- helpers

func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


# Ticks (relative to now) on which attacker's blows land in the next ticks.
func _hit_ticks(world: World, attacker: Unit, ticks: int) -> Array[int]:
	var out: Array[int] = []
	for _t: int in ticks:
		var at: int = world.tick
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.attacker_id == attacker.id and e.kind == CombatEvent.Kind.HIT:
				out.append(at)
	return out


func _event_kinds(world: World, attacker: Unit, ticks: int) -> Array[CombatEvent.Kind]:
	var out: Array[CombatEvent.Kind] = []
	for _t: int in ticks:
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.attacker_id == attacker.id and e.kind != CombatEvent.Kind.SWING:
				out.append(e.kind)
	return out


func _count_launches(world: World, ticks: int) -> int:
	var n: int = 0
	for _t: int in ticks:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			n += 1 if e.kind == ProjectileEvent.Kind.LAUNCH else 0
	return n
