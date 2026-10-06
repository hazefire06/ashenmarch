class_name Army
extends RefCounted
## One side's skirmish army: how many of each unit type it fields. The player
## buys one on the skirmish screen; the AI's comes from an ArmyTemplate. Both
## are paid for in UnitType.cost points out of the same budget.
##
## The counts are a dictionary for the menus' sake, but nothing that reaches
## the sim reads them in dictionary order: type_list sorts, because the order
## a block is laid out in decides entity ids.

## The most units an army may field, for performance (two armies at the cap
## are 120 units).
const MAX_UNITS: int = 60

var faction: UnitType.Faction = UnitType.Faction.LIGHT
## How many of each type, by type id. A type the army doesn't field has no
## key (set_count erases it at 0).
var counts: Dictionary[StringName, int] = {}


func _init(side: UnitType.Faction = UnitType.Faction.LIGHT) -> void:
	faction = side


## How many units in all.
func size() -> int:
	var n: int = 0
	for type_id: StringName in counts:
		n += counts[type_id]
	return n


func count_of(type_id: StringName) -> int:
	return counts.get(type_id, 0)


## Sets how many of a type it fields; 0 or less removes the type.
func set_count(type_id: StringName, n: int) -> void:
	if n <= 0:
		counts.erase(type_id)
	else:
		counts[type_id] = n


## Total points, at each type's cost. A type the catalog doesn't know counts
## nothing (validate reports it).
func cost(catalog: UnitCatalog) -> int:
	var total: int = 0
	for type_id: StringName in counts:
		var t: UnitType = catalog.find(type_id)
		if t != null:
			total += t.cost * counts[type_id]
	return total


## Problems that make the army unplayable within this budget, or an empty
## array. Every one is listed.
func validate(catalog: UnitCatalog, budget: int) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if faction < 0 or faction >= UnitType.Faction.size():
		errors.append("faction %d is not a Faction" % faction)
	for type_id: StringName in _sorted_ids():
		var t: UnitType = catalog.find(type_id)
		if t == null:
			errors.append("unknown unit type %s" % type_id)
			continue
		if t.faction != faction:
			errors.append("%s is not on this army's side" % type_id)
		if t.cost <= 0:
			errors.append("%s can't be bought" % type_id)
		if counts[type_id] < 0:
			errors.append("%s has a negative count" % type_id)
	var n: int = size()
	if n < 1:
		errors.append("an army needs at least one unit")
	if n > MAX_UNITS:
		errors.append("an army can field at most %d units, has %d" % [MAX_UNITS, n])
	var points: int = cost(catalog)
	if points > budget:
		errors.append("the army costs %d points, over the budget of %d" % [points, budget])
	return errors


## Every unit's type id, one per unit, in deploy order: melee, then ranged,
## then support, and within a role by catalog index. A formation lays a block
## out front to back in this order, so the melee stands in front. Unknown
## types are left out.
func type_list(catalog: UnitCatalog) -> Array[StringName]:
	var known: Array[StringName] = []
	for type_id: StringName in counts:
		if catalog.find(type_id) != null:
			known.append(type_id)
	known.sort_custom(func(a: StringName, b: StringName) -> bool:
		return _deploy_key(catalog, a) < _deploy_key(catalog, b))
	var out: Array[StringName] = []
	for type_id: StringName in known:
		for k: int in counts[type_id]:
			out.append(type_id)
	return out


## A copy that shares nothing with this one.
func copy() -> Army:
	var other: Army = Army.new(faction)
	for type_id: StringName in counts:
		other.counts[type_id] = counts[type_id]
	return other


# Role first, catalog index second: one integer, so the sort is total.
static func _deploy_key(catalog: UnitCatalog, type_id: StringName) -> int:
	var t: UnitType = catalog.find(type_id)
	return int(t.role) * 1_000_000 + catalog.index_of(type_id)


func _sorted_ids() -> Array[StringName]:
	var ids: Array[StringName] = Array(counts.keys(), TYPE_STRING_NAME, &"", null)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids
