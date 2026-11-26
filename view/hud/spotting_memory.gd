class_name SpottingMemory
extends RefCounted
## What the corner map remembers about enemies the player's troops have
## spotted: which are spotted now, and a fading mark where each was last seen.
## Display only; meant to be updated every 8 ticks, never from the sim step.

## 10 s at 30 ticks/s.
const FADE_TICKS: int = 300

var _spotted: Dictionary[int, Vector2] = {}
## Unit id -> {position: Vector2, seen_tick: int}.
var _marks: Dictionary[int, Dictionary] = {}
var _now: int = 0


func update(world: World, viewer: UnitType.Faction) -> void:
	_now = world.tick
	var by_id: Dictionary[int, Unit] = {}
	var now_spotted: Dictionary[int, Vector2] = {}
	for unit: Unit in world.units:
		by_id[unit.id] = unit
		if unit.faction == viewer or not unit.is_alive():
			continue
		if Visibility.spotted_by(world, unit, viewer):
			now_spotted[unit.id] = Vector2(unit.x, unit.z) / float(World.UNITS_PER_METER)
	for id: int in _spotted:
		if now_spotted.has(id):
			continue
		var gone: Unit = by_id.get(id)
		if gone != null and gone.is_alive():
			_marks[id] = {"position": _spotted[id], "seen_tick": _now}
	for id: int in now_spotted:
		_marks.erase(id)
	for id: int in _marks.keys():
		var unit: Unit = by_id.get(id)
		if unit == null or not unit.is_alive() or _now - int(_marks[id]["seen_tick"]) >= FADE_TICKS:
			_marks.erase(id)
	_spotted = now_spotted


## Unit ids spotted as of the last update.
func spotted() -> PackedInt32Array:
	return PackedInt32Array(_spotted.keys())


## One {position: Vector2 (map metres x, z), alpha: float} per fading mark.
func marks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in _marks:
		var mark: Dictionary = _marks[id]
		var age: int = _now - int(mark["seen_tick"])
		out.append({"position": mark["position"], "alpha": 1.0 - float(age) / FADE_TICKS})
	return out


func clear() -> void:
	_spotted.clear()
	_marks.clear()
	_now = 0
