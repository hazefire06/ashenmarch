class_name Soldier
extends RefCounted
## One member of the player's campaign roster: who he is and what he carries
## from mission to mission. Units in a mission are matched back to their
## Soldier by `id` (Unit.soldier_id), so the id is stable for the whole
## campaign and never reused, even after he falls.
##
## A record, not a sim entity: it is only read and written between missions, so
## it is not hashed. Its dictionary form is what a save file holds (JSON-safe:
## no 64-bit numbers, no StringNames).

## Campaign-unique, from 1 (0 means "not a campaign soldier", Unit.soldier_id).
var id: int = 0
## Id of his UnitType in the catalog.
var type_id: StringName = &""
## Given name, picked by CampaignState.name_for when he was recruited.
var name: String = ""
## Enemies he has killed across the campaign; drives his veterancy.
var kills: int = 0
## Hit points he has, or 0 for full health: the DeployCommand convention. A
## survivor who is not hurt is stored as 0, never as his type's maximum, so a
## later change to that maximum doesn't leave him short of it.
var hp: int = 0
## Missions he has survived.
var missions: int = 0
## Id of the mission he died (or was converted) in; empty while he is alive.
var fallen_in: StringName = &""


func _init(soldier_id: int = 0, soldier_type: StringName = &"", given_name: String = "") -> void:
	id = soldier_id
	type_id = soldier_type
	name = given_name


## The record as JSON-safe values: ints, and Strings in place of StringNames.
func to_dict() -> Dictionary:
	return {
		"id": id,
		"type_id": String(type_id),
		"name": name,
		"kills": kills,
		"hp": hp,
		"missions": missions,
		"fallen_in": String(fallen_in),
	}


## Reads a record back from what JSON gave (numbers arrive as floats). Returns
## null if it isn't well formed, and says why in `error_out` (one message): not
## a dictionary, a key missing, a value of the wrong kind, an id below 1, an
## empty type_id, or a count below 0.
static func from_dict(d: Variant, error_out: PackedStringArray = PackedStringArray()) -> Soldier:
	if not d is Dictionary:
		error_out.append("a soldier record must be a dictionary")
		return null
	var record: Dictionary = d
	for key: String in ["id", "kills", "hp", "missions"]:
		if not record.has(key):
			error_out.append("soldier is missing %s" % key)
			return null
		if not is_whole_number(record[key]):
			error_out.append("soldier %s must be a whole number" % key)
			return null
	for key: String in ["type_id", "name", "fallen_in"]:
		if not record.has(key):
			error_out.append("soldier is missing %s" % key)
			return null
		if not record[key] is String:
			error_out.append("soldier %s must be text" % key)
			return null
	if int(record["id"]) < 1:
		error_out.append("soldier id must be 1 or more")
		return null
	if String(record["type_id"]).is_empty():
		error_out.append("soldier type_id is empty")
		return null
	for key: String in ["kills", "hp", "missions"]:
		if int(record[key]) < 0:
			error_out.append("soldier %s can't be negative" % key)
			return null
	var s: Soldier = Soldier.new(int(record["id"]), StringName(record["type_id"] as String), record["name"] as String)
	s.kills = int(record["kills"])
	s.hp = int(record["hp"])
	s.missions = int(record["missions"])
	s.fallen_in = StringName(record["fallen_in"] as String)
	return s


## True for an int, or a float with a whole value in the range a double holds
## exactly: what a JSON integer looks like after parsing. Anything else (text,
## 1.5, 1e300) isn't a count or an id.
static func is_whole_number(value: Variant) -> bool:
	if value is int:
		return true
	if value is float:
		var f: float = value
		return absf(f) < 9.0e15 and f == floorf(f)
	return false
