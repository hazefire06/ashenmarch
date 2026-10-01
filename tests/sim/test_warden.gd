extends GutTest
## Wardens and herbs: a herb heals a hurt friend and cures it, kills
## anything undead, and is refused for a living enemy or a friend with
## nothing to heal; it is spent only when it lands. Herbs fall when a healer
## dies, are picked up on contact or by order (never past a full stack), and
## a herb plant struck once drops two and is spent. Errands go to the
## nearest unit that can do them, and not across water they can't cross.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const HEALER: int = 0
const DUMMY: int = 1
const UNDEAD: int = 2
const BRAWLER: int = 3
const WALKER: int = 4

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.healer(&"healer"),
		TestUnits.dummy(&"dummy"),
		TestUnits.undead(&"undead", {"max_hp": 500}),
		TestUnits.melee(&"brawler"),
		TestUnits.dummy(&"walker", {"move_speed": 2000}),
	]
	_catalog = TestUnits.catalog(types)


func test_a_herb_heals_a_hurt_friend_and_cures_it() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 15 * M, 20 * M, -1, 0)
	friend.hp = 30
	StatusEffects.apply(world, friend, StatusEffects.Kind.PARALYSIS, 600, 0)
	StatusEffects.apply(world, friend, StatusEffects.Kind.BURNING, 600, 0)
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), friend.id))
	var heals: Array[CombatEvent] = _heals(world, 4 * World.TICK_RATE)
	assert_eq(heals.size(), 1)
	assert_eq(heals[0].damage, 60)
	assert_false(StatusEffects.paralyzed(world, friend), "cured")
	assert_false(StatusEffects.has(world, friend, StatusEffects.Kind.BURNING), "cured")
	var hp: int = friend.hp
	_run(world, 30)
	assert_eq(friend.hp, hp, "no longer burning")
	assert_eq(healer.special_left, 5, "one herb spent")
	assert_eq(healer.order, Unit.Order.NONE, "and it holds where it healed")
	assert_eq(healer.interact_id, 0)


func test_a_herb_never_heals_past_full() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 11 * M, 20 * M, -1, 0)
	friend.hp = friend.type.max_hp - 5
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), friend.id))
	var heals: Array[CombatEvent] = _heals(world, 60)
	assert_eq(heals[0].damage, 5)
	assert_eq(friend.hp, friend.type.max_hp)


func test_a_herb_kills_the_undead_and_the_kill_counts() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var husk: Unit = world.spawn_unit(UNDEAD, DARK, 16 * M, 20 * M, -1, 0)
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), husk.id))
	_heals(world, 4 * World.TICK_RATE)
	assert_false(husk.is_alive(), "all 500 hp of it")
	assert_eq(healer.kills, 1)
	assert_eq(healer.special_left, 5)


func test_a_living_enemy_or_a_friend_with_nothing_to_heal_is_refused() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(DUMMY, DARK, 15 * M, 20 * M, -1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 10 * M, 25 * M, -1, 0)
	enemy.hp = 10
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), enemy.id))
	world.enqueue(HealCommand.new(1, PackedInt32Array([healer.id]), friend.id))
	_heals(world, 60)
	assert_eq(healer.order, Unit.Order.NONE, "no errand started")
	assert_eq(healer.special_left, 6)
	assert_eq(enemy.hp, 10)


func test_only_healers_answer_a_heal_order() -> void:
	var world: World = _world()
	var brawler: Unit = world.spawn_unit(BRAWLER, LIGHT, 14 * M, 20 * M, 1, 0)
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 5 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 15 * M, 20 * M, -1, 0)
	friend.hp = 50
	world.enqueue(HealCommand.new(0, PackedInt32Array([brawler.id, healer.id]), friend.id))
	world.step()
	assert_eq(brawler.order, Unit.Order.NONE)
	assert_eq(healer.order, Unit.Order.INTERACT)
	assert_eq(healer.interact_id, friend.id)


func test_the_nearest_healer_goes_and_the_rest_stay() -> void:
	var world: World = _world()
	var far: Unit = world.spawn_unit(HEALER, LIGHT, 2 * M, 20 * M, 1, 0)
	var near: Unit = world.spawn_unit(HEALER, LIGHT, 8 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 15 * M, 20 * M, -1, 0)
	friend.hp = 50
	world.enqueue(HealCommand.new(0, PackedInt32Array([far.id, near.id]), friend.id))
	_heals(world, 4 * World.TICK_RATE)
	assert_eq(near.special_left, 5)
	assert_eq(far.special_left, 6)
	assert_eq(far.x, 2 * M, "never moved")


func test_the_herb_is_kept_when_the_patient_walks_out_of_reach() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(WALKER, LIGHT, 11 * M, 20 * M, 1, 0)
	friend.hp = 50
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), friend.id))
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([friend.id]), 25 * M, 20 * M, 0))
	var record: Array[Array] = []
	for _t: int in 12 * World.TICK_RATE:
		var at: int = world.tick
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.kind == CombatEvent.Kind.HEAL:
				record.append([at, e])
	assert_eq(record.size(), 1, "one heal, once it caught up")
	assert_gt(record[0][0], 15, "the first wind-up came to nothing")
	assert_eq(healer.special_left, 5, "only the herb that landed was spent")
	assert_eq(friend.hp, 110, "healed")


func test_paralysis_spoils_the_heal() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 11 * M, 20 * M, -1, 0)
	friend.hp = 20
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), friend.id))
	_run(world, 5)
	assert_gt(healer.act_left, 0, "winding up")
	StatusEffects.apply(world, healer, StatusEffects.Kind.PARALYSIS, 60, 0)
	world.step()
	assert_eq(healer.act_left, 0, "the wind-up is lost")
	assert_eq(friend.hp, 20)
	_heals(world, 120)
	assert_eq(friend.hp, 80, "it heals once it can")
	assert_eq(healer.special_left, 5)


func test_herbs_fall_when_a_healer_dies_and_another_picks_them_up() -> void:
	var world: World = _world()
	var dying: Unit = world.spawn_unit(HEALER, LIGHT, 20 * M, 20 * M, 1, 0)
	var other: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	dying.special_left = 3
	other.special_left = 4
	Damage.apply(world, dying, 1000, 0, 0, 0)
	assert_eq(_herbs_lying(world), 3, "three herbs in a ring at its feet")
	world.enqueue(MoveUnitsCommand.new(world.tick, PackedInt32Array([other.id]), 20 * M, 20 * M, 0))
	_run(world, 8 * World.TICK_RATE)
	assert_eq(other.special_left, 6, "picked up what it had room for")
	assert_eq(_herbs_lying(world), 1, "and left the rest")


func test_a_herb_can_be_fetched_by_order() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	healer.special_left = 2
	var herb: Projectile = _drop_herb(world, 22 * M, 25 * M)
	world.enqueue(InteractCommand.new(0, PackedInt32Array([healer.id]), herb.id))
	_run(world, 10 * World.TICK_RATE)
	assert_true(herb.removed or not world.projectiles.has(herb))
	assert_eq(healer.special_left, 3)
	assert_eq(healer.order, Unit.Order.NONE)


func test_a_full_healer_leaves_herbs_alone() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	_drop_herb(world, 15 * M, 20 * M)
	world.enqueue(MoveUnitsCommand.new(0, PackedInt32Array([healer.id]), 20 * M, 20 * M, 0))
	_run(world, 8 * World.TICK_RATE)
	assert_eq(healer.special_left, 6)
	assert_eq(_herbs_lying(world), 1, "walked right over it")


func test_a_herb_plant_drops_two_herbs_when_struck_then_is_spent() -> void:
	var world: World = _world()
	var brawler: Unit = world.spawn_unit(BRAWLER, LIGHT, 10 * M, 20 * M, 1, 0)
	var plant: HerbPlant = world.spawn_herb_plant(20 * M, 20 * M)
	world.enqueue(InteractCommand.new(0, PackedInt32Array([brawler.id]), plant.id))
	_run(world, 10 * World.TICK_RATE)
	assert_true(plant.spent)
	assert_eq(_herbs_lying(world), HerbPlant.ROOTS)
	assert_eq(brawler.order, Unit.Order.NONE)
	world.enqueue(InteractCommand.new(world.tick, PackedInt32Array([brawler.id]), plant.id))
	world.step()
	assert_eq(brawler.order, Unit.Order.NONE, "nothing left to strike")


func test_no_errand_across_water_the_unit_cant_cross() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(18) + "3".repeat(4) + ".".repeat(18))
	var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	healer.special_left = 2
	var herb: Projectile = _drop_herb(world, 30 * M, 20 * M)
	world.enqueue(InteractCommand.new(0, PackedInt32Array([healer.id]), herb.id))
	world.step()
	assert_eq(healer.order, Unit.Order.NONE, "refused")


func test_a_plant_is_hashed() -> void:
	var a: World = _world()
	var b: World = _world()
	var pa: HerbPlant = a.spawn_herb_plant(5 * M, 5 * M)
	b.spawn_herb_plant(5 * M, 5 * M)
	assert_eq(a.state_hash(), b.state_hash())
	pa.spent = true
	assert_ne(a.state_hash(), b.state_hash())


# --- helpers

func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


func _heals(world: World, ticks: int) -> Array[CombatEvent]:
	var out: Array[CombatEvent] = []
	for _t: int in ticks:
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.kind == CombatEvent.Kind.HEAL:
				out.append(e)
	return out


func _drop_herb(world: World, x: int, z: int) -> Projectile:
	return world.drop_object(world.catalog.projectile_index_of(&"herb"), x, z, 0)


func _herbs_lying(world: World) -> int:
	var n: int = 0
	for p: Projectile in world.projectiles:
		if not p.removed and p.type.pickup == ProjectileType.Pickup.HERB:
			n += 1
	return n
