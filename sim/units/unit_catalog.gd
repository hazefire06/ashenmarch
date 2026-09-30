class_name UnitCatalog
extends Resource
## Every unit type the game knows, in a fixed order (data/units/catalog.tres).
## Commands name types by id; units store the catalog index, so two worlds
## built from the same catalog hash identically. An explicit list rather than
## a directory scan because exported builds rename .tres files to .remap.

@export var types: Array[UnitType] = []

var _index_by_id: Dictionary[StringName, int] = {}


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


## Problems with any type or with the list itself, or an empty array.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
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
	return errors
