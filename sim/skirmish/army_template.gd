class_name ArmyTemplate
extends Resource
## A recipe for an AI skirmish army (data/skirmish/templates/<id>.tres): which
## unit types it fields and what share of the budget goes to each. fill turns
## it into an Army for a budget, the same way every time, so a skirmish's
## setup data is enough to rebuild the AI's army.
##
## type_ids and shares_permille are parallel: entry i spends
## shares_permille[i] / 1000 of the budget on type_ids[i]. Listed melee first,
## as everywhere, though Army.type_list sorts anyway.

## Stable key, e.g. &"dark_horde"; the menus and the results screen name the
## template by it.
@export var id: StringName = &""
@export var display_name: String = ""
@export var faction: UnitType.Faction = UnitType.Faction.LIGHT
@export var type_ids: Array[StringName] = []
## Per entry, its share of the budget in permille; together they make 1000.
@export var shares_permille: PackedInt32Array = PackedInt32Array()


## Problems that make the template unusable, or an empty array. Every one is
## listed.
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var who: String = String(id) if id != &"" else resource_path
	if id == &"":
		errors.append("%s: id is empty" % who)
	if display_name.is_empty():
		errors.append("%s: display_name is empty" % who)
	if faction < 0 or faction >= UnitType.Faction.size():
		errors.append("%s: faction %d is not a Faction" % [who, faction])
	if type_ids.is_empty():
		errors.append("%s: a template needs at least one entry" % who)
	if type_ids.size() != shares_permille.size():
		errors.append("%s: type_ids and shares_permille differ in length" % who)
		return errors
	var seen: Dictionary[StringName, bool] = {}
	var total: int = 0
	for i: int in type_ids.size():
		var type_id: StringName = type_ids[i]
		if seen.has(type_id):
			errors.append("%s: %s is listed twice" % [who, type_id])
		seen[type_id] = true
		var t: UnitType = catalog.find(type_id)
		if t == null:
			errors.append("%s: unknown unit type %s" % [who, type_id])
		else:
			if t.faction != faction:
				errors.append("%s: %s is not on the template's side" % [who, type_id])
			if t.cost <= 0:
				errors.append("%s: %s can't be bought" % [who, type_id])
		if shares_permille[i] <= 0:
			errors.append("%s: %s needs a positive share" % [who, type_id])
		total += shares_permille[i]
	if total != 1000:
		errors.append("%s: shares add up to %d, not 1000" % [who, total])
	return errors


## The army this template fields for a budget, deterministically:
## 1. each entry gets as many units as its share of the budget buys, rounded
##    down;
## 2. if that is more than Army.MAX_UNITS in all, the counts are scaled down to
##    the cap in proportion (rounded down, the slots left going to the largest
##    remainders, ties to the earlier entry), and an entry scaled to none gets
##    one back from the entry with the most, so a cheap horde can't crowd a
##    type out of the army altogether;
## 3. what is left goes one unit at a time to the affordable entry furthest
##    below its share in points (ties to the earlier entry), until nothing is
##    affordable or the army is full.
## The template must validate; an invalid one gives an empty army.
func fill(budget: int, catalog: UnitCatalog) -> Army:
	var army: Army = Army.new(faction)
	if not validate(catalog).is_empty():
		push_error("ArmyTemplate.fill: %s doesn't validate" % id)
		return army
	var n: int = type_ids.size()
	var costs: PackedInt32Array = PackedInt32Array()
	var counts: PackedInt32Array = PackedInt32Array()
	costs.resize(n)
	counts.resize(n)
	var total: int = 0
	for i: int in n:
		costs[i] = catalog.find(type_ids[i]).cost
		counts[i] = budget * shares_permille[i] / 1000 / costs[i]
		total += counts[i]
	if total > Army.MAX_UNITS:
		counts = _scaled_to_cap(counts, total)
	var spent: int = 0
	total = 0
	for i: int in n:
		spent += counts[i] * costs[i]
		total += counts[i]
	while total < Army.MAX_UNITS:
		var best: int = -1
		var best_deficit: int = 0
		for i: int in n:
			if costs[i] > budget - spent:
				continue
			# Points still owed to the entry's share (negative once over it).
			var deficit: int = budget * shares_permille[i] / 1000 - counts[i] * costs[i]
			if best < 0 or deficit > best_deficit:
				best = i
				best_deficit = deficit
		if best < 0:
			break
		counts[best] += 1
		spent += costs[best]
		total += 1
	for i: int in n:
		army.set_count(type_ids[i], counts[i])
	return army


# Counts wanted (summing to total, over the cap) scaled down to exactly
# Army.MAX_UNITS: see fill, step 2.
static func _scaled_to_cap(wanted: PackedInt32Array, total: int) -> PackedInt32Array:
	var n: int = wanted.size()
	var counts: PackedInt32Array = PackedInt32Array()
	var remainders: PackedInt32Array = PackedInt32Array()
	counts.resize(n)
	remainders.resize(n)
	var placed: int = 0
	for i: int in n:
		counts[i] = wanted[i] * Army.MAX_UNITS / total
		remainders[i] = wanted[i] * Army.MAX_UNITS % total
		placed += counts[i]
	while placed < Army.MAX_UNITS:
		var best: int = 0
		for i: int in n:
			if remainders[i] > remainders[best]:
				best = i
		counts[best] += 1
		remainders[best] = -1
		placed += 1
	for i: int in n:
		if wanted[i] > 0 and counts[i] == 0:
			var most: int = 0
			for j: int in n:
				if counts[j] > counts[most]:
					most = j
			counts[most] -= 1
			counts[i] = 1
	return counts
