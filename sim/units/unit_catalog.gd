class_name UnitCatalog
extends Resource
## Every unit type the game knows, in a fixed order (data/units/catalog.tres),
## and every projectile they fire or drop. Commands name types by id; units
## and projectiles store the catalog index, so two worlds built from the same
## catalog hash identically. An explicit list rather than a directory scan
## because exported builds rename .tres files to .remap.
##
## Projectiles live here rather than in a catalog of their own because a unit
## type is only usable together with the projectiles it names; one resource
## keeps them validated together and World.new's signature unchanged.

@export var types: Array[UnitType] = []
@export var projectile_types: Array[ProjectileType] = []

var _index_by_id: Dictionary[StringName, int] = {}
var _projectile_index_by_id: Dictionary[StringName, int] = {}


## Index of the type with this id, or -1.
func index_of(type_id: StringName) -> int:
	if _index_by_id.size() != types.size():
		_index_by_id.clear()
		for i: int in types.size():
			_index_by_id[types[i].id] = i
	return _index_by_id.get(type_id, -1)


## The type with this id, or null.
func find(type_id: StringName) -> UnitType:
	var i: int = index_of(type_id)
	return types[i] if i >= 0 else null


## Index of the projectile type with this id, or -1.
func projectile_index_of(projectile_id: StringName) -> int:
	if _projectile_index_by_id.size() != projectile_types.size():
		_projectile_index_by_id.clear()
		for i: int in projectile_types.size():
			_projectile_index_by_id[projectile_types[i].id] = i
	return _projectile_index_by_id.get(projectile_id, -1)


## The projectile type with this id, or null.
func find_projectile(projectile_id: StringName) -> ProjectileType:
	var i: int = projectile_index_of(projectile_id)
	return projectile_types[i] if i >= 0 else null


## Problems with any type or with the lists themselves, or an empty array.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var seen_projectiles: Dictionary[StringName, bool] = {}
	for i: int in projectile_types.size():
		var p: ProjectileType = projectile_types[i]
		if p == null:
			errors.append("projectile entry %d is null" % i)
			continue
		errors.append_array(p.validate())
		if seen_projectiles.has(p.id):
			errors.append("duplicate projectile id %s" % p.id)
		seen_projectiles[p.id] = true
	var seen: Dictionary[StringName, bool] = {}
	for i: int in types.size():
		var t: UnitType = types[i]
		if t == null:
			errors.append("catalog entry %d is null" % i)
			continue
		errors.append_array(t.validate())
		if seen.has(t.id):
			errors.append("duplicate unit id %s" % t.id)
		seen[t.id] = true
		errors.append_array(_validate_references(t, seen_projectiles))
	return errors


# The projectiles a unit type names exist and suit how it uses them.
func _validate_references(t: UnitType, known: Dictionary[StringName, bool]) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	for projectile_id: StringName in [t.ranged_projectile, t.special_projectile]:
		if projectile_id != &"" and not known.has(projectile_id):
			errors.append("%s: unknown projectile %s" % [t.id, projectile_id])
	var special: ProjectileType = find_projectile(t.special_projectile) if known.has(t.special_projectile) else null
	if special == null:
		return errors
	if t.special_ability == UnitType.Special.SATCHEL and special.behavior != ProjectileType.Behavior.BOUNCES:
		errors.append("%s: a dropped charge must be a BOUNCES projectile" % t.id)
	if t.special_ability == UnitType.Special.FIRE_ARROW and not special.marks_fire:
		errors.append("%s: the fire arrow must mark fire" % t.id)
	return errors
