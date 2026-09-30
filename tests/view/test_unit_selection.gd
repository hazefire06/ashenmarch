extends GutTest
## Selection and control groups: replace, add, shift-toggle, save and recall,
## and pruning of dead units, with a change signal only on real changes.

var _sel: UnitSelection
var _changes: int


func before_each() -> void:
	_sel = UnitSelection.new()
	_changes = 0
	_sel.changed.connect(func() -> void: _changes += 1)


func test_select_sorts_and_dedupes() -> void:
	_sel.select(PackedInt32Array([5, 2, 5, 9]))
	assert_eq(_sel.ids(), PackedInt32Array([2, 5, 9]))
	assert_true(_sel.is_selected(5))
	assert_false(_sel.is_selected(3))
	assert_eq(_changes, 1)


func test_add_and_toggle() -> void:
	_sel.select(PackedInt32Array([1, 2]))
	_sel.add(PackedInt32Array([2, 3]))
	assert_eq(_sel.ids(), PackedInt32Array([1, 2, 3]))
	_sel.toggle(2)
	assert_eq(_sel.ids(), PackedInt32Array([1, 3]))
	_sel.toggle(2)
	assert_eq(_sel.ids(), PackedInt32Array([1, 2, 3]))


func test_no_signal_when_nothing_changes() -> void:
	_sel.select(PackedInt32Array([1, 2]))
	_sel.select(PackedInt32Array([2, 1]))
	_sel.add(PackedInt32Array([1]))
	assert_eq(_changes, 1)


func test_groups_save_and_recall() -> void:
	_sel.select(PackedInt32Array([4, 7]))
	_sel.save_group(0)
	_sel.select(PackedInt32Array([1]))
	_sel.save_group(9)
	_sel.clear()
	assert_true(_sel.recall_group(0))
	assert_eq(_sel.ids(), PackedInt32Array([4, 7]))
	assert_true(_sel.recall_group(9))
	assert_eq(_sel.ids(), PackedInt32Array([1]))
	assert_false(_sel.recall_group(3), "empty group")
	assert_eq(_sel.ids(), PackedInt32Array([1]), "unchanged by an empty recall")


func test_group_is_a_copy_of_the_selection() -> void:
	_sel.select(PackedInt32Array([4, 7]))
	_sel.save_group(2)
	_sel.add(PackedInt32Array([8]))
	assert_eq(_sel.group(2), PackedInt32Array([4, 7]))


func test_prune_drops_dead_units_everywhere() -> void:
	_sel.select(PackedInt32Array([1, 2, 3]))
	_sel.save_group(0)
	_sel.prune(func(unit_id: int) -> bool: return unit_id != 2)
	assert_eq(_sel.ids(), PackedInt32Array([1, 3]))
	assert_eq(_sel.group(0), PackedInt32Array([1, 3]))
