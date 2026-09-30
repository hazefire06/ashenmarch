class_name UnitSelection
extends RefCounted
## The player's current selection and saved control groups, as unit ids.
## Pure view state: it never touches the sim, and in multiplayer each player
## has their own. Kept free of Nodes so it's testable without a scene tree.

const GROUP_COUNT: int = 10

## Emitted whenever the selection changes (not when only groups change).
signal changed

## Selected unit ids, ascending.
var _selected: PackedInt32Array = PackedInt32Array()
var _groups: Array[PackedInt32Array] = []


func _init() -> void:
	for i: int in GROUP_COUNT:
		_groups.append(PackedInt32Array())


## Selected unit ids, ascending.
func ids() -> PackedInt32Array:
	return _selected.duplicate()


func size() -> int:
	return _selected.size()


func is_empty() -> bool:
	return _selected.is_empty()


func is_selected(unit_id: int) -> bool:
	var at: int = _selected.bsearch(unit_id)
	return at < _selected.size() and _selected[at] == unit_id


## Replaces the selection.
func select(unit_ids: PackedInt32Array) -> void:
	_replace(_normalized(unit_ids))


## Adds to the selection.
func add(unit_ids: PackedInt32Array) -> void:
	var merged: PackedInt32Array = _selected.duplicate()
	merged.append_array(unit_ids)
	_replace(_normalized(merged))


## Adds the unit if it isn't selected, removes it if it is (shift-click).
func toggle(unit_id: int) -> void:
	var next: PackedInt32Array = _selected.duplicate()
	var at: int = next.bsearch(unit_id)
	if at < next.size() and next[at] == unit_id:
		next.remove_at(at)
	else:
		next.insert(at, unit_id)
	_replace(next)


func clear() -> void:
	_replace(PackedInt32Array())


## Stores the current selection in group slot 0..GROUP_COUNT-1.
func save_group(slot: int) -> void:
	_groups[slot] = _selected.duplicate()


## Selects group slot's units. Returns false (selection unchanged) if the
## group is empty.
func recall_group(slot: int) -> bool:
	if _groups[slot].is_empty():
		return false
	_replace(_groups[slot].duplicate())
	return true


func group(slot: int) -> PackedInt32Array:
	return _groups[slot].duplicate()


## Drops every id, from the selection and all groups, for which keep(id) is
## false (dead or despawned units).
func prune(keep: Callable) -> void:
	for slot: int in GROUP_COUNT:
		_groups[slot] = _filtered(_groups[slot], keep)
	var kept: PackedInt32Array = _filtered(_selected, keep)
	if kept.size() != _selected.size():
		_replace(kept)


func _replace(sorted_ids: PackedInt32Array) -> void:
	if sorted_ids == _selected:
		return
	_selected = sorted_ids
	changed.emit()


static func _filtered(unit_ids: PackedInt32Array, keep: Callable) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for unit_id: int in unit_ids:
		if keep.call(unit_id):
			out.append(unit_id)
	return out


static func _normalized(unit_ids: PackedInt32Array) -> PackedInt32Array:
	var sorted: PackedInt32Array = unit_ids.duplicate()
	sorted.sort()
	var out: PackedInt32Array = PackedInt32Array()
	for unit_id: int in sorted:
		if out.is_empty() or out[out.size() - 1] != unit_id:
			out.append(unit_id)
	return out
