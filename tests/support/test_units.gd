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
	assert(errors.is_empty(), "invalid test type: %s" % [errors])
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


static func catalog(types: Array[UnitType]) -> UnitCatalog:
	var c: UnitCatalog = UnitCatalog.new()
	c.types = types
	return c
