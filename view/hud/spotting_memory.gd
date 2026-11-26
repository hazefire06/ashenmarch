class_name SpottingMemory
extends RefCounted
## What the corner map remembers about enemies the player's troops have
## spotted: which are spotted now, and a fading mark where each was last seen.
## Display only; call clear() when the world changes (a new mission or a
## restart), since marks are keyed by unit id. Meant to be updated every 8
## ticks, never from the sim step.
##
## To keep an update cheap, each one re-evaluates only a quarter of the enemies
## (round-robin by the order each was first seen), so a full refresh takes REFRESH_UPDATES updates.
## A spotted enemy not re-evaluated keeps its state and its dot follows its
## position; one that died or vanished is dropped every update. Each enemy
## remembers which of your units spotted it last and that one is tried first.

## 10 s at 30 ticks/s.
const FADE_TICKS: int = 300
## Updates for every enemy to be re-evaluated once.
const REFRESH_UPDATES: int = 4

## Enemy id -> position in map metres (x, z), for enemies spotted now.
var _spotted: Dictionary[int, Vector2] = {}
## Enemy id -> tick it was last confirmed spotted.
var _seen_tick: Dictionary[int, int] = {}
## Enemy id -> where it was when last confirmed spotted (a mark goes here).
var _seen_pos: Dictionary[int, Vector2] = {}
## Enemy id -> id of the viewer unit that last spotted it.
var _spotter: Dictionary[int, int] = {}
## Enemy id -> {position: Vector2, seen_tick: int}.
var _marks: Dictionary[int, Dictionary] = {}
## Enemy id -> its update slot (0 .. REFRESH_UPDATES - 1), dealt out in turn.
var _slot: Dictionary[int, int] = {}
var _now: int = 0
var _phase: int = 0


func update(world: World, viewer: UnitType.Faction) -> void:
	_now = world.tick
	for unit: Unit in world.units:
		if unit.faction == viewer or not unit.is_alive():
			continue
		var id: int = unit.id
		var here: Vector2 = Vector2(unit.x, unit.z) / float(World.UNITS_PER_METER)
		if not _slot.has(id):
			_slot[id] = _slot.size() % REFRESH_UPDATES
		if _slot[id] != _phase:
			if _spotted.has(id):
				_spotted[id] = here
			continue
		var by: int = Visibility.spotted_by_hint(world, unit, viewer, _spotter.get(id, -1))
		if by >= 0:
			_spotted[id] = here
			_seen_tick[id] = _now
			_seen_pos[id] = here
			_spotter[id] = by
			_marks.erase(id)
		elif _spotted.has(id):
			_marks[id] = {"position": _seen_pos[id], "seen_tick": _seen_tick[id]}
			_forget(id)
	for id: int in _spotted.keys():
		if not _is_live(world, id):
			_forget(id)
	for id: int in _marks.keys():
		if not _is_live(world, id) or _now - int(_marks[id]["seen_tick"]) >= FADE_TICKS:
			_marks.erase(id)
	_phase = (_phase + 1) % REFRESH_UPDATES


## Unit ids spotted as of the last update.
func spotted() -> PackedInt32Array:
	return PackedInt32Array(_spotted.keys())


## One {position: Vector2 (map metres x, z), alpha: float} per fading mark.
func marks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in _marks:
		var mark: Dictionary = _marks[id]
		var age: int = _now - int(mark["seen_tick"])
		out.append({"position": mark["position"], "alpha": clampf(1.0 - float(age) / FADE_TICKS, 0.0, 1.0)})
	return out


func clear() -> void:
	_spotted.clear()
	_seen_tick.clear()
	_slot.clear()
	_seen_pos.clear()
	_spotter.clear()
	_marks.clear()
	_now = 0
	_phase = 0


func _forget(id: int) -> void:
	_spotted.erase(id)
	_seen_tick.erase(id)
	_seen_pos.erase(id)
	_spotter.erase(id)


func _is_live(world: World, id: int) -> bool:
	var unit: Unit = world.entities.get(id) as Unit
	return unit != null and unit.is_alive()
