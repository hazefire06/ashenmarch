extends GutTest
## SlotAssignment must find the assignment with the least total straight-line
## distance, for any unit count up to the slot count.

const RANGE: int = 50000


func _generator(seed_value: int) -> RandomNumberGenerator:
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = seed_value
	return gen


func _points(gen: RandomNumberGenerator, count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i: int in count:
		out.append(Vector2i(gen.randi_range(-RANGE, RANGE), gen.randi_range(-RANGE, RANGE)))
	return out


func _dist(a: Vector2i, b: Vector2i) -> int:
	return FixedMath.length(a.x - b.x, a.y - b.y)


## True if every unit has its own in-range slot.
func _is_valid(assignment: PackedInt32Array, unit_count: int, slot_count: int) -> bool:
	if assignment.size() != unit_count:
		return false
	var seen: Dictionary[int, bool] = {}
	for slot: int in assignment:
		if slot < 0 or slot >= slot_count or seen.has(slot):
			return false
		seen[slot] = true
	return true


## Cheapest total cost by trying every way to give each unit its own slot.
func _brute_force(units: Array[Vector2i], slots: Array[Vector2i]) -> int:
	var used: Array[bool] = []
	used.resize(slots.size())
	used.fill(false)
	return _search(units, slots, 0, used)


func _search(units: Array[Vector2i], slots: Array[Vector2i], unit: int, used: Array[bool]) -> int:
	if unit == units.size():
		return 0
	var best: int = 1 << 60
	for j: int in slots.size():
		if used[j]:
			continue
		used[j] = true
		best = mini(best, _dist(units[unit], slots[j]) + _search(units, slots, unit + 1, used))
		used[j] = false
	return best


## Each unit in order takes the nearest slot still free.
func _greedy_cost(units: Array[Vector2i], slots: Array[Vector2i]) -> int:
	var taken: Array[bool] = []
	taken.resize(slots.size())
	taken.fill(false)
	var total: int = 0
	for unit: Vector2i in units:
		var best_slot: int = -1
		var best: int = 1 << 60
		for j: int in slots.size():
			if not taken[j] and _dist(unit, slots[j]) < best:
				best = _dist(unit, slots[j])
				best_slot = j
		taken[best_slot] = true
		total += best
	return total


func test_no_units_gives_an_empty_assignment() -> void:
	var slots: Array[Vector2i] = [Vector2i(5, 5)]
	assert_eq(SlotAssignment.assign([], slots).size(), 0)
	assert_eq(SlotAssignment.assign([], []).size(), 0)


func test_crossing_paths_are_uncrossed() -> void:
	var units: Array[Vector2i] = [Vector2i(0, 0), Vector2i(10, 0)]
	var slots: Array[Vector2i] = [Vector2i(10, 0), Vector2i(0, 0)]
	var result: PackedInt32Array = SlotAssignment.assign(units, slots)
	assert_eq(result[0], 1)
	assert_eq(result[1], 0)
	assert_eq(SlotAssignment.total_cost(units, slots, result), 0)


func test_matches_brute_force_on_random_cases() -> void:
	var gen: RandomNumberGenerator = _generator(99)
	var failures: Array[String] = []
	for case_index: int in 200:
		var n: int = gen.randi_range(1, 7)
		var units: Array[Vector2i] = _points(gen, n)
		var slots: Array[Vector2i] = _points(gen, n)
		var result: PackedInt32Array = SlotAssignment.assign(units, slots)
		if not _is_valid(result, n, n):
			failures.append("case %d: invalid assignment %s" % [case_index, result])
			continue
		var got: int = SlotAssignment.total_cost(units, slots, result)
		var want: int = _brute_force(units, slots)
		if got != want:
			failures.append("case %d (N=%d): cost %d, brute force %d" % [case_index, n, got, want])
	assert_eq(failures.size(), 0, "\n".join(failures))


func test_matches_brute_force_with_spare_slots() -> void:
	var gen: RandomNumberGenerator = _generator(5)
	var failures: Array[String] = []
	for case_index: int in 60:
		var n: int = gen.randi_range(1, 5)
		var m: int = n + gen.randi_range(1, 3)
		var units: Array[Vector2i] = _points(gen, n)
		var slots: Array[Vector2i] = _points(gen, m)
		var result: PackedInt32Array = SlotAssignment.assign(units, slots)
		if not _is_valid(result, n, m):
			failures.append("case %d: invalid assignment %s" % [case_index, result])
			continue
		var got: int = SlotAssignment.total_cost(units, slots, result)
		var want: int = _brute_force(units, slots)
		if got != want:
			failures.append("case %d (N=%d, M=%d): cost %d, brute force %d" % [case_index, n, m, got, want])
	assert_eq(failures.size(), 0, "\n".join(failures))


func test_never_worse_than_greedy() -> void:
	var gen: RandomNumberGenerator = _generator(11)
	var strictly_better: int = 0
	for case_index: int in 60:
		var n: int = gen.randi_range(2, 40)
		var units: Array[Vector2i] = _points(gen, n)
		var slots: Array[Vector2i] = _points(gen, n)
		var result: PackedInt32Array = SlotAssignment.assign(units, slots)
		assert_true(_is_valid(result, n, n), "case %d valid" % case_index)
		var optimal: int = SlotAssignment.total_cost(units, slots, result)
		var greedy: int = _greedy_cost(units, slots)
		assert_true(optimal <= greedy, "case %d: %d > greedy %d" % [case_index, optimal, greedy])
		if optimal < greedy:
			strictly_better += 1
	# If greedy always tied, this test would prove nothing.
	assert_gt(strictly_better, 0, "greedy should lose on some cases")


func test_units_already_on_slots_map_to_their_own_slot() -> void:
	var gen: RandomNumberGenerator = _generator(3)
	var n: int = 30
	# A distinct z per slot keeps every position unique, so the only zero-cost
	# assignment is the identity.
	var slots: Array[Vector2i] = []
	for i: int in n:
		slots.append(Vector2i(gen.randi_range(-RANGE, RANGE), i * 500))
	# Fisher-Yates with the seeded generator; Array.shuffle would use the
	# global one.
	var order: Array[int] = []
	for i: int in n:
		order.append(i)
	for i: int in range(n - 1, 0, -1):
		var j: int = gen.randi_range(0, i)
		var swap: int = order[i]
		order[i] = order[j]
		order[j] = swap
	var units: Array[Vector2i] = []
	for i: int in n:
		units.append(slots[order[i]])

	var result: PackedInt32Array = SlotAssignment.assign(units, slots)
	assert_eq(SlotAssignment.total_cost(units, slots, result), 0)
	for i: int in n:
		assert_eq(result[i], order[i], "unit %d" % i)


func test_same_input_gives_the_same_assignment() -> void:
	var gen: RandomNumberGenerator = _generator(21)
	# Many units at the same spot make plenty of ties.
	var units: Array[Vector2i] = _points(gen, 12)
	var slots: Array[Vector2i] = []
	for i: int in 12:
		slots.append(Vector2i((i % 3) * 1000, (i % 2) * 1000))
	assert_eq(SlotAssignment.assign(units, slots), SlotAssignment.assign(units, slots))


func test_timing_for_one_hundred_units() -> void:
	var gen: RandomNumberGenerator = _generator(100)
	var units: Array[Vector2i] = _points(gen, 100)
	var slots: Array[Vector2i] = _points(gen, 100)
	var start: int = Time.get_ticks_usec()
	var result: PackedInt32Array = SlotAssignment.assign(units, slots)
	var elapsed: int = Time.get_ticks_usec() - start
	gut.p("SlotAssignment.assign, N=100: %.1f ms" % (elapsed / 1000.0))
	assert_true(_is_valid(result, 100, 100))
