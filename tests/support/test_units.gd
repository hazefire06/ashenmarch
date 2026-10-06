class_name TestUnits
extends RefCounted
## Synthetic unit types for combat tests, so a test pins exactly the stats it
## depends on instead of breaking whenever the shipped data is retuned.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK


## A valid living melee type: 100 hp, 10 damage at 100% accuracy, 0.5 m
## reach, 5-tick wind-up, 10-tick cooldown, 8 m acquire radius, 2 m/s.
## overrides sets any UnitType property by name.
static func melee(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var t: UnitType = UnitType.new()
	t.id = type_id
	t.display_name = String(type_id).capitalize()
	t.max_hp = 100
	t.body_radius = 400
	t.body_height = 1800
	t.move_speed = 2000
	t.water_speed_permille = PackedInt32Array([1000, 800, 600, 0, 0])
	t.melee_damage = 10
	t.melee_accuracy_permille = 1000
	t.melee_reach = 500
	t.melee_windup_ticks = 5
	t.melee_cooldown_ticks = 10
	t.acquire_radius = 8000
	for key: String in overrides:
		t.set(key, overrides[key])
	var errors: PackedStringArray = t.validate()
	if not errors.is_empty():
		# Not assert(): under the debugger that hangs instead of failing the
		# test. The error fails the running test; the type comes back as built.
		push_error("TestUnits.melee: invalid test type: %s" % [errors])
	return t


## A type that never fights back and takes a long time to kill: a target
## dummy. It has no melee attack, so it never turns to face anyone.
static func dummy(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"max_hp": 100_000, "melee_damage": 0, "melee_accuracy_permille": 0,
		"melee_reach": 0, "melee_windup_ticks": 0, "melee_cooldown_ticks": 0,
		"acquire_radius": 0,
	}
	base.merge(overrides, true)
	return melee(type_id, base)


## A valid living archer built on melee(): arrows at 34 m/s, 2-50 m, a
## 10-tick draw and 30-tick cooldown, no spread (so a test is about physics,
## not dice), unlimited ammo. overrides sets any property by name.
static func ranged(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"role": UnitType.Role.RANGED,
		"ranged_projectile": &"arrow",
		"ranged_launch_speed": 34_000,
		"ranged_lob_grade_permille": 600,
		"ranged_launch_height": 1500,
		"ranged_min_range": 2000,
		"ranged_max_range": 50_000,
		"ranged_windup_ticks": 10,
		"ranged_cooldown_ticks": 30,
		"ranged_ammo": -1,
	}
	base.merge(overrides, true)
	return melee(type_id, base)


## A thrower built on ranged(): grenades lobbed at 45 degrees, up to 17.5
## m/s, 5-28 m, no spread, four satchels.
static func thrower(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"ranged_projectile": &"grenade",
		"ranged_aim": UnitType.AimStyle.LOB,
		"ranged_launch_speed": 17_500,
		"ranged_lob_grade_permille": 1000,
		"ranged_launch_height": 1700,
		"ranged_min_range": 5000,
		"ranged_max_range": 28_000,
		"special_ability": UnitType.Special.SATCHEL,
		"special_charges": 4,
		"special_projectile": &"satchel",
	}
	base.merge(overrides, true)
	return ranged(type_id, base)


## A lightning caster built on ranged(): no melee, bolts out to 40 m with an
## 8 m dead zone, a 30-tick cast, a 120-tick cooldown, and no spread.
static func caster(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"melee_damage": 0, "melee_accuracy_permille": 0, "melee_reach": 0,
		"melee_windup_ticks": 0, "melee_cooldown_ticks": 0, "acquire_radius": 0,
		"ranged_projectile": &"lightning", "ranged_launch_height": 1600,
		"ranged_min_range": 8000, "ranged_max_range": 40_000,
		"ranged_windup_ticks": 30, "ranged_cooldown_ticks": 120,
	}
	base.merge(overrides, true)
	return ranged(type_id, base)


## A scavenger built on melee(): it picks up loose objects and tears parts
## off bodies within 8 m, and throws them like a thrower (a lob at 0.8 grade,
## up to 15 m/s, 3-20 m, a 12-tick wind-up, no spread), hunting ranged and
## support units first.
static func scavenger(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"preferred_target_roles": (1 << UnitType.Role.RANGED) | (1 << UnitType.Role.SUPPORT),
		"throws_carried": true, "scavenge_radius": 8000, "scavenged_projectile": &"body_part",
		"ranged_aim": UnitType.AimStyle.LOB, "ranged_launch_speed": 15_000,
		"ranged_lob_grade_permille": 800, "ranged_launch_height": 1500,
		"ranged_min_range": 3000, "ranged_max_range": 20_000,
		"ranged_windup_ticks": 12, "ranged_cooldown_ticks": 30, "ranged_ammo": -1,
	}
	base.merge(overrides, true)
	return melee(type_id, base)


## A healer built on melee(): a support unit carrying six herbs that heal
## 60 hp after a 15-tick wind-up.
static func healer(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"role": UnitType.Role.SUPPORT,
		"special_ability": UnitType.Special.HEAL,
		"special_charges": 6,
		"special_projectile": &"herb",
		"heal_hp": 60,
		"heal_windup_ticks": 15,
	}
	base.merge(overrides, true)
	return melee(type_id, base)


## An undead dummy that walks anywhere wet: what a herb kills.
static func undead(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"nature": UnitType.Nature.UNDEAD, "mobility": Terrain.Mobility.UNDEAD,
		"water_speed_permille": PackedInt32Array([1000, 1000, 1000, 1000, 1000]),
	}
	base.merge(overrides, true)
	return dummy(type_id, base)


## A walking bomb: undead, no blows of its own; its blow is bursting into the
## shipped blight burst after a 20-tick wind-up, and any death bursts it.
static func bomb(type_id: StringName, overrides: Dictionary = {}) -> UnitType:
	var base: Dictionary = {
		"nature": UnitType.Nature.UNDEAD, "mobility": Terrain.Mobility.UNDEAD,
		"water_speed_permille": PackedInt32Array([1000, 1000, 1000, 1000, 1000]),
		"max_hp": 40, "move_speed": 1100,
		"melee_damage": 0, "melee_accuracy_permille": 0, "melee_windup_ticks": 20,
		"melee_cooldown_ticks": 30, "acquire_radius": 10_000, "melee_detonates": true,
		"special_ability": UnitType.Special.DETONATE, "special_charges": 1,
		"special_projectile": &"blight_burst",
	}
	base.merge(overrides, true)
	return melee(type_id, base)


## Private copies of the shipped projectile types, in catalog order. Copies,
## because load() hands every caller the same cached resources: a test that
## tweaks one must not change it for the rest of the run.
static func shipped_projectiles() -> Array[ProjectileType]:
	var c: UnitCatalog = load("res://data/units/catalog.tres") as UnitCatalog
	var copies: Array[ProjectileType] = []
	for t: ProjectileType in c.projectile_types:
		copies.append(t.duplicate())
	return copies


## A private copy of a shipped projectile type, safe to tweak in a test.
static func projectile(projectile_id: StringName, overrides: Dictionary = {}) -> ProjectileType:
	var c: UnitCatalog = load("res://data/units/catalog.tres") as UnitCatalog
	var p: ProjectileType = c.find_projectile(projectile_id).duplicate()
	for key: String in overrides:
		p.set(key, overrides[key])
	var errors: PackedStringArray = p.validate()
	if not errors.is_empty():
		# Not assert() (see melee()).
		push_error("TestUnits.projectile: invalid test projectile: %s" % [errors])
	return p


## A catalog of these unit types and projectile types (the shipped ones
## unless given).
static func catalog(types: Array[UnitType], projectiles: Array[ProjectileType] = []) -> UnitCatalog:
	var c: UnitCatalog = UnitCatalog.new()
	c.types = types
	c.projectile_types = projectiles if not projectiles.is_empty() else shipped_projectiles()
	return c
