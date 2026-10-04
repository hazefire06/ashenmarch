class_name CampaignDef
extends Resource
## A whole campaign as data: its missions in play order and the pool of given
## names recruits are called by. Read-only at runtime; CampaignState is what
## changes from mission to mission.

## The fewest soldier names a campaign needs. A name is picked by soldier id
## and a numeral marks each lap of the list (CampaignState.name_for), so fewer
## would repeat names within a mission's roster.
const MIN_NAMES: int = 50

## In play order; a mission's index here is CampaignState.mission_index.
@export var missions: Array[MissionDef] = []
## Original given names for recruits, distinct, at least MIN_NAMES of them.
@export var soldier_names: PackedStringArray = PackedStringArray()


## Problems that make the campaign unusable, or an empty array. Every one is
## listed; a mission's problems are prefixed with its id.
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if missions.is_empty():
		errors.append("a campaign needs at least one mission")
	var seen: Dictionary[StringName, bool] = {}
	for i: int in missions.size():
		var m: MissionDef = missions[i]
		if m == null:
			errors.append("mission %d is null" % i)
			continue
		# An empty id is already reported by the mission itself.
		if m.id != &"" and seen.has(m.id):
			errors.append("duplicate mission id %s" % m.id)
		seen[m.id] = true
		var label: String = String(m.id) if m.id != &"" else "#%d" % i
		for problem: String in m.validate(catalog):
			errors.append("mission %s: %s" % [label, problem])
	if soldier_names.size() < MIN_NAMES:
		errors.append("soldier_names needs at least %d names, has %d" % [MIN_NAMES, soldier_names.size()])
	var names_seen: Dictionary[String, bool] = {}
	for i: int in soldier_names.size():
		var n: String = soldier_names[i]
		if n.is_empty():
			errors.append("soldier_names[%d] is empty" % i)
		elif names_seen.has(n):
			errors.append("soldier_names lists %s twice" % n)
		names_seen[n] = true
	return errors
