extends GutTest
## SfxPlayer: every combat and projectile event plays its cue from the sound
## map, a unit the viewer can't see makes no sound, and the voice caps hold.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog = load("res://data/units/catalog.tres") as UnitCatalog


# A 30 x 30 m field of grass with a 5 m pool of depth 3 at (10..14, 10..14).
func _field() -> Array[String]:
	var rows: Array[String] = []
	for z: int in 30:
		var row: String = ""
		for x: int in 30:
			row += "3" if (x >= 10 and x < 15 and z >= 10 and z < 15) else "."
		rows.append(row)
	return rows


func _world() -> World:
	return World.new(1, TestTerrains.from_ascii(_field()), _catalog)


func _spawn(world: World, id: StringName, side: UnitType.Faction, x: float, z: float) -> Unit:
	return world.spawn_unit(_catalog.index_of(id), side, roundi(x * M), roundi(z * M), 0, 1000)


# Every cue the shared bank declares, one silent stream each (five seconds
# long unless seconds says otherwise).
func _full_bank(seconds: float = 0.2) -> SoundBank:
	var variants: Dictionary = {}
	for id: StringName in SoundBank.shared().ids():
		variants[id] = 1
	return AudioFixtures.bank(variants, 3, seconds)


func _player(world: World, bank: SoundBank = null) -> SfxPlayer:
	var camera: RtsCamera = RtsCamera.new()
	add_child_autofree(camera)
	camera.focus = Vector3(15, 0, 15)
	var sfx: SfxPlayer = SfxPlayer.new()
	add_child_autofree(sfx)
	sfx.setup(world, camera, bank if bank != null else _full_bank(), SoundMap.shared())
	# Groans are chance; only the groan tests turn them on.
	sfx.groan_chance = 0.0
	sfx.seed_rng(1)
	return sfx


func _cues(sfx: SfxPlayer) -> Array[StringName]:
	var out: Array[StringName] = []
	for played: Dictionary in sfx.played_this_tick():
		out.append(played["cue"])
	return out


# A tick of the sim with the events its own units made dropped, so a test hears
# only the ones it adds.
func _quiet_step(world: World) -> void:
	world.step()
	world.combat_events.clear()
	world.projectile_events.clear()


func _combat(world: World, sfx: SfxPlayer, kind: CombatEvent.Kind, a: Unit, b: Unit) -> void:
	_quiet_step(world)
	world.combat_events.append(CombatEvent.new(kind, a.id if a != null else 0, b.id))
	sfx.after_step()


func _shot(world: World, sfx: SfxPlayer, event: ProjectileEvent) -> void:
	_quiet_step(world)
	world.projectile_events.append(event)
	sfx.after_step()


func _projectile(kind: ProjectileEvent.Kind, x: float, z: float, id: StringName = &"") -> ProjectileEvent:
	var event: ProjectileEvent = ProjectileEvent.new(kind, roundi(x * M), 0, roundi(z * M))
	if id != &"":
		event.type_index = _catalog.projectile_index_of(id)
	return event


func test_a_swing_plays_the_attackers_weapon_class() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var target: Unit = _spawn(world, &"shieldman", LIGHT, 20, 20)
	for pair: Array in [[&"shieldman", &"swing_blade"], [&"husk", &"swing_claw"], [&"blightbag", &"swing_stomp"]]:
		var attacker: Unit = _spawn(world, pair[0], DARK, 21, 20)
		_combat(world, sfx, CombatEvent.Kind.SWING, attacker, target)
		assert_eq(_cues(sfx), [pair[1]] as Array[StringName], str(pair[0]))


func test_a_hit_plays_the_targets_body() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var attacker: Unit = _spawn(world, &"shieldman", LIGHT, 20, 20)
	var caller: Unit = _spawn(world, &"stormcaller", DARK, 21, 20)
	_combat(world, sfx, CombatEvent.Kind.HIT, attacker, caller)
	assert_eq(_cues(sfx), [&"hit_dry"] as Array[StringName])
	var husk: Unit = _spawn(world, &"husk", DARK, 20, 21)
	_combat(world, sfx, CombatEvent.Kind.HIT, attacker, husk)
	assert_eq(_cues(sfx), [&"hit_flesh"] as Array[StringName])


func test_a_blow_from_afar_plays_no_melee_sound() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var archer: Unit = _spawn(world, &"longbow", LIGHT, 5, 20)
	var husk: Unit = _spawn(world, &"husk", DARK, 25, 20)
	_combat(world, sfx, CombatEvent.Kind.HIT, archer, husk)
	assert_eq(_cues(sfx), [] as Array[StringName], "an arrow's own events play")
	_combat(world, sfx, CombatEvent.Kind.BLOCK, archer, husk)
	assert_eq(_cues(sfx), [] as Array[StringName])


func test_a_block_plays_the_shield() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var shield: Unit = _spawn(world, &"shieldman", LIGHT, 20, 20)
	var husk: Unit = _spawn(world, &"husk", DARK, 21, 20)
	_combat(world, sfx, CombatEvent.Kind.BLOCK, husk, shield)
	assert_eq(_cues(sfx), [&"block_shield"] as Array[StringName])


func test_a_kill_plays_the_hit_and_the_types_death() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var attacker: Unit = _spawn(world, &"shieldman", LIGHT, 20, 20)
	var husk: Unit = _spawn(world, &"husk", DARK, 21, 20)
	_combat(world, sfx, CombatEvent.Kind.KILL, attacker, husk)
	assert_eq(_cues(sfx), [&"hit_flesh", &"death_husk"] as Array[StringName])


func test_a_heal_on_the_undead_sears() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var warden: Unit = _spawn(world, &"warden", LIGHT, 20, 20)
	var friend: Unit = _spawn(world, &"shieldman", LIGHT, 21, 20)
	var husk: Unit = _spawn(world, &"husk", DARK, 22, 20)
	_combat(world, sfx, CombatEvent.Kind.HEAL, warden, friend)
	assert_eq(_cues(sfx), [&"heal"] as Array[StringName])
	_combat(world, sfx, CombatEvent.Kind.HEAL, warden, husk)
	assert_eq(_cues(sfx), [&"heal_sear"] as Array[StringName])


func test_a_launch_plays_by_projectile() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var shooter: Unit = _spawn(world, &"longbow", LIGHT, 20, 20)
	var want: Dictionary = {
		&"arrow": &"bow_release", &"fire_arrow": &"bow_release_fire",
		&"grenade": &"throw_bottle", &"herb": &"throw_herb",
	}
	for id: StringName in want:
		var launch: ProjectileEvent = _projectile(ProjectileEvent.Kind.LAUNCH, 20, 20, id)
		launch.unit_id = shooter.id
		_shot(world, sfx, launch)
		assert_eq(_cues(sfx), [want[id]] as Array[StringName], str(id))


func test_stick_fizzle_and_explode_follow_depth_radius_and_projectile() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var stick: ProjectileEvent = _projectile(ProjectileEvent.Kind.STICK, 20, 20, &"arrow")
	_shot(world, sfx, stick)
	assert_eq(_cues(sfx), [&"arrow_thunk"] as Array[StringName])
	stick.depth = 2
	_shot(world, sfx, stick)
	assert_eq(_cues(sfx), [&"arrow_splash"] as Array[StringName])
	var fizzle: ProjectileEvent = _projectile(ProjectileEvent.Kind.FIZZLE, 20, 20, &"grenade")
	fizzle.depth = 1
	_shot(world, sfx, fizzle)
	assert_eq(_cues(sfx), [&"fizzle_water"] as Array[StringName])
	fizzle.depth = 0
	_shot(world, sfx, fizzle)
	assert_eq(_cues(sfx), [&"fizzle_hiss"] as Array[StringName])
	var blast: ProjectileEvent = _projectile(ProjectileEvent.Kind.EXPLODE, 20, 20, &"grenade")
	blast.radius = 5000
	_shot(world, sfx, blast)
	assert_eq(_cues(sfx), [&"explosion_small"] as Array[StringName])
	blast.radius = 7000
	_shot(world, sfx, blast)
	assert_eq(_cues(sfx), [&"explosion_large"] as Array[StringName])
	var wet: ProjectileEvent = _projectile(ProjectileEvent.Kind.EXPLODE, 12, 12, &"grenade")
	wet.radius = 5000
	_shot(world, sfx, wet)
	assert_eq(_cues(sfx), [&"explosion_water"] as Array[StringName])
	var burst: ProjectileEvent = _projectile(ProjectileEvent.Kind.EXPLODE, 20, 20, &"blight_burst")
	burst.radius = 5000
	_shot(world, sfx, burst)
	assert_eq(_cues(sfx), [&"gas_burst"] as Array[StringName])


func test_a_projectile_hit_and_the_small_events_play() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	_shot(world, sfx, _projectile(ProjectileEvent.Kind.HIT, 20, 20, &"arrow"))
	assert_eq(_cues(sfx), [&"arrow_flesh"] as Array[StringName])
	_shot(world, sfx, _projectile(ProjectileEvent.Kind.DROP, 20, 20, &"satchel"))
	assert_eq(_cues(sfx), [&"satchel_thud"] as Array[StringName])
	var grabber: Unit = _spawn(world, &"ripper", DARK, 20, 20)
	var pick: ProjectileEvent = _projectile(ProjectileEvent.Kind.PICK_UP, 20, 20, &"satchel")
	pick.unit_id = grabber.id
	_shot(world, sfx, pick)
	assert_eq(_cues(sfx), [&"grab"] as Array[StringName])


func test_a_harder_bounce_is_louder() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var soft: ProjectileEvent = _projectile(ProjectileEvent.Kind.BOUNCE, 20, 20, &"grenade")
	soft.speed = 30
	_shot(world, sfx, soft)
	var soft_db: float = sfx.played_this_tick()[0]["db"]
	var hard: ProjectileEvent = _projectile(ProjectileEvent.Kind.BOUNCE, 20, 20, &"grenade")
	hard.speed = 400
	_shot(world, sfx, hard)
	assert_eq(_cues(sfx), [&"bottle_clink"] as Array[StringName])
	assert_gt(sfx.played_this_tick()[0]["db"], soft_db)


func _submerged_husk(world: World) -> Unit:
	var husk: Unit = _spawn(world, &"husk", DARK, 12.5, 12.5)
	assert_true(Visibility.is_submerged(world.terrain, husk), "lying in wait")
	return husk


func test_a_submerged_husk_is_silent_until_seen() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var husk: Unit = _submerged_husk(world)
	# The reveal radius equals the melee reach, so the target is a Dark unit.
	var swordsman: Unit = _spawn(world, &"ripper", DARK, 12.5, 9.5)
	assert_false(Visibility.seen_by(world, husk, LIGHT), "no light unit close enough")
	_combat(world, sfx, CombatEvent.Kind.SWING, husk, swordsman)
	assert_eq(_cues(sfx), [] as Array[StringName])
	_combat(world, sfx, CombatEvent.Kind.MISS, husk, swordsman)
	assert_eq(_cues(sfx), [] as Array[StringName])
	sfx.set_viewer(DARK)
	_combat(world, sfx, CombatEvent.Kind.SWING, husk, swordsman)
	assert_eq(_cues(sfx), [&"swing_claw"] as Array[StringName], "its own side hears it")
	_combat(world, sfx, CombatEvent.Kind.MISS, husk, swordsman)
	assert_eq(_cues(sfx), [&"swing_claw"] as Array[StringName])


func test_what_a_hidden_unit_does_and_suffers_is_silent_until_seen() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var husk: Unit = _submerged_husk(world)
	# Dark units beside it: the Husk is out of any Light unit's sight.
	var other: Unit = _spawn(world, &"ripper", DARK, 12.5, 9.5)
	_combat(world, sfx, CombatEvent.Kind.HIT, other, husk)
	assert_eq(_cues(sfx), [] as Array[StringName], "a hit on it")
	_combat(world, sfx, CombatEvent.Kind.KILL, other, husk)
	assert_eq(_cues(sfx), [] as Array[StringName], "neither the hit nor the death")
	var launch: ProjectileEvent = _projectile(ProjectileEvent.Kind.LAUNCH, 12.5, 12.5, &"arrow")
	launch.unit_id = husk.id
	_shot(world, sfx, launch)
	assert_eq(_cues(sfx), [] as Array[StringName], "a launch by it")
	sfx.set_viewer(DARK)
	_combat(world, sfx, CombatEvent.Kind.HIT, other, husk)
	assert_eq(_cues(sfx), [&"hit_flesh"] as Array[StringName], "the hit, once seen")
	_combat(world, sfx, CombatEvent.Kind.KILL, other, husk)
	assert_eq(_cues(sfx), [&"hit_flesh", &"death_husk"] as Array[StringName], "the hit and the death")
	_shot(world, sfx, launch)
	assert_eq(_cues(sfx), [&"bow_release"] as Array[StringName], "the launch")


func test_blasts_bolts_fire_and_gas_are_always_heard() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	_submerged_husk(world)
	var blast: ProjectileEvent = _projectile(ProjectileEvent.Kind.EXPLODE, 12.5, 12.5, &"grenade")
	blast.radius = 5000
	_shot(world, sfx, blast)
	assert_eq(_cues(sfx).size(), 1, "the blast over the Husk")
	_shot(world, sfx, _projectile(ProjectileEvent.Kind.BOLT, 20, 20, &"lightning"))
	assert_eq(_cues(sfx), [&"thunder"] as Array[StringName])
	_shot(world, sfx, _projectile(ProjectileEvent.Kind.IGNITE, 20, 20, &"fire_arrow"))
	assert_eq(_cues(sfx), [&"fire_whoomp"] as Array[StringName])
	_quiet_step(world)
	world.clouds.append(GasCloud.new(77, 20 * M, 0, 20 * M, 3000, 100, 30, 0))
	sfx.after_step()
	assert_eq(_cues(sfx), [&"gas_release"] as Array[StringName])


func test_events_about_missing_units_are_skipped() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var target: Unit = _spawn(world, &"shieldman", LIGHT, 20, 20)
	_combat(world, sfx, CombatEvent.Kind.SWING, null, target)
	assert_eq(_cues(sfx), [] as Array[StringName], "attacker 0")
	_quiet_step(world)
	world.combat_events.append(CombatEvent.new(CombatEvent.Kind.HIT, target.id, 9999))
	sfx.after_step()
	assert_eq(_cues(sfx), [] as Array[StringName], "no such target")
	var shooter: Unit = _spawn(world, &"longbow", LIGHT, 22, 20)
	shooter.kill()
	var launch: ProjectileEvent = _projectile(ProjectileEvent.Kind.LAUNCH, 22, 20, &"arrow")
	launch.unit_id = shooter.id
	_shot(world, sfx, launch)
	assert_eq(_cues(sfx), [] as Array[StringName], "a dead shooter")
	launch.unit_id = 9999
	_shot(world, sfx, launch)
	assert_eq(_cues(sfx), [] as Array[StringName], "no such shooter")


func test_a_cue_without_a_stream_costs_nothing() -> void:
	var world: World = _world()
	var bank: SoundBank = AudioFixtures.bank({&"explosion_small": 1})
	var empty: SoundCue = SoundCue.new()
	empty.id = &"thunder"
	bank.cues.append(empty)
	var sfx: SfxPlayer = _player(world, bank)
	var near: Vector3 = Vector3(15, 0, 15)
	assert_false(sfx.play_at(&"thunder", near), "declared, no streams")
	assert_false(sfx.play_at(&"never_declared", near), "missing")
	assert_eq(sfx.started_this_tick(), 0)
	for i: int in SfxPlayer.MAX_PER_TICK:
		assert_true(sfx.play_at(&"explosion_small", near), "the tick's budget is whole")
	assert_eq(sfx.started_this_tick(), SfxPlayer.MAX_PER_TICK)
	assert_eq(sfx._counts.get(&"thunder", 0), 0, "and spent no per-cue budget")


func test_a_cues_own_cap_limits_its_voices() -> void:
	var world: World = _world()
	var bank: SoundBank = AudioFixtures.bank({&"explosion_large": 1}, 3, 5.0)
	bank.cue(&"explosion_large").max_voices = 2
	var sfx: SfxPlayer = _player(world, bank)
	var near: Vector3 = Vector3(15, 0, 15)
	assert_true(sfx.play_at(&"explosion_large", near))
	assert_true(sfx.play_at(&"explosion_large", near))
	assert_false(sfx.play_at(&"explosion_large", near), "a third in the tick")
	world.step()
	sfx.after_step()
	assert_false(sfx.play_at(&"explosion_large", near), "both still playing next tick")


func test_a_full_pool_cuts_the_oldest_voice() -> void:
	var world: World = _world()
	var variants: Dictionary = {}
	for i: int in 25:
		variants[StringName("cue_%d" % i)] = 1
	var sfx: SfxPlayer = _player(world, AudioFixtures.bank(variants, 3, 5.0))
	var near: Vector3 = Vector3(15, 0, 15)
	for i: int in 25:
		if i % 8 == 0:
			world.step()
			sfx.after_step()
		assert_true(sfx.play_at(StringName("cue_%d" % i), near), "cue %d" % i)
	assert_eq(sfx._voice_cue[0], &"cue_24", "the 25th took voice 0")


func _variant_run(sfx: SfxPlayer, seed_value: int) -> Array[int]:
	sfx.seed_rng(seed_value)
	var run: Array[int] = []
	var near: Vector3 = Vector3(15, 0, 15)
	var bank: SoundBank = sfx.bank
	for i: int in 20:
		sfx.after_step()
		assert_true(sfx.play_at(&"hit_flesh", near))
		run.append(bank.cue(&"hit_flesh").streams.find(sfx._voices[(sfx._next_voice + SfxPlayer.VOICES - 1) % SfxPlayer.VOICES].stream))
	return run


func test_the_same_seed_picks_the_same_variants() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world, AudioFixtures.bank({&"hit_flesh": 8}, 99, 5.0))
	var first: Array[int] = _variant_run(sfx, 42)
	assert_eq(_variant_run(sfx, 42), first, "same seed, same picks")
	assert_ne(_variant_run(sfx, 43), first, "another seed, other picks")
	assert_gt(first.count(first[0]), 0)
	assert_lt(first.count(first[0]), 20, "and the picks vary")


func test_seen_undead_near_the_focus_groan_now_and_then() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	sfx.groan_chance = SfxPlayer.GROAN_CHANCE
	sfx.seed_rng(3)
	_spawn(world, &"husk", DARK, 25, 15)
	_spawn(world, &"shieldman", LIGHT, 10, 15)  # 15 m off: close enough to groan at, too far to fight
	var groans: int = 0
	for i: int in 600:
		_quiet_step(world)
		sfx.after_step()
		groans += _cues(sfx).count(&"groan_husk")
	assert_gte(groans, 1)
	assert_lte(groans, 600 / SfxPlayer.GROAN_GAP_TICKS + 1)


func test_a_submerged_husk_never_groans() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	sfx.groan_chance = 1.0
	_submerged_husk(world)
	# 12.5 m from the husk: near enough for it to groan at, beyond its 4 m reveal radius.
	_spawn(world, &"shieldman", LIGHT, 12.5, 25)
	var groans: int = 0
	for i: int in 300:
		_quiet_step(world)
		sfx.after_step()
		groans += _cues(sfx).count(&"groan_husk")
	assert_eq(groans, 0, "even at a certain roll")
	sfx.set_viewer(DARK)
	_quiet_step(world)
	sfx.after_step()
	assert_eq(_cues(sfx), [&"groan_husk"] as Array[StringName], "its own side hears it")


# Riverside's camera opens on a Husk patrol across the creek, 70 m from the squads: near the focus is not
# enough, the dead groan as they close on the living.
func test_undead_groan_only_near_a_unit_of_the_other_side() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	sfx.groan_chance = 1.0
	_spawn(world, &"husk", DARK, 25, 15)
	_spawn(world, &"shieldman", LIGHT, 2, 15)  # 23 m off
	var groans: int = 0
	for i: int in 120:
		_quiet_step(world)
		sfx.after_step()
		groans += _cues(sfx).count(&"groan_husk")
	assert_eq(groans, 0, "seen and near the focus, but no enemy within %s m" % SfxPlayer.GROAN_NEAR)
	_spawn(world, &"reaver", LIGHT, 8, 15)  # 17 m off
	_quiet_step(world)
	sfx.after_step()
	assert_eq(_cues(sfx), [&"groan_husk"] as Array[StringName], "a living enemy within reach")


func test_cant_reach_denies_only_for_the_viewers_units() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var mine: Unit = _spawn(world, &"sapper", LIGHT, 20, 20)
	var theirs: Unit = _spawn(world, &"stormcaller", DARK, 22, 20)
	var denied: ProjectileEvent = _projectile(ProjectileEvent.Kind.CANT_REACH, 20, 20)
	denied.unit_id = theirs.id
	_shot(world, sfx, denied)
	assert_eq(_cues(sfx), [] as Array[StringName])
	denied.unit_id = mine.id
	_shot(world, sfx, denied)
	assert_eq(_cues(sfx), [&"ui_deny"] as Array[StringName])


func test_a_disabled_player_is_silent() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	sfx.enabled = false
	_shot(world, sfx, _projectile(ProjectileEvent.Kind.BOLT, 20, 20, &"lightning"))
	sfx.play_ui(&"ui_deny")
	assert_eq(_cues(sfx), [] as Array[StringName])


func test_the_listener_sits_at_the_focus_facing_the_camera() -> void:
	var world: World = _world()
	var sfx: SfxPlayer = _player(world)
	var camera: RtsCamera = sfx._camera
	camera.setup(world.terrain)
	camera.set_pose(Vector2(12, 8), 0.9, 40.0)
	sfx._process(0.016)
	var listener: AudioListener3D = sfx.get_node("Listener") as AudioListener3D
	assert_true(listener.is_current())
	assert_almost_eq(listener.global_position.x, camera.focus.x, 0.001)
	assert_almost_eq(listener.global_position.z, camera.focus.z, 0.001)
	var heard: Vector2 = Vector2(-listener.global_basis.z.x, -listener.global_basis.z.z).normalized()
	var seen: Basis = camera.get_camera().global_basis
	var looking: Vector2 = Vector2(-seen.z.x, -seen.z.z).normalized()
	assert_gt(heard.dot(looking), 0.99)


func test_every_cue_the_player_names_is_declared() -> void:
	var bank: SoundBank = SoundBank.shared()
	for id: StringName in SfxPlayer.NAMED_CUES:
		assert_true(bank.declares(id), "bank declares %s" % id)
	for entry: UnitSound in SoundMap.shared().units:
		assert_true(bank.declares(StringName(SfxPlayer.SWING_PREFIX + entry.weapon)), "swing_%s" % entry.weapon)
		assert_true(bank.declares(StringName(SfxPlayer.HIT_PREFIX + entry.body)), "hit_%s" % entry.body)
