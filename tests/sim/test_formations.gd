extends GutTest
## Formations must give exactly N well-spaced slots, anchored on the click
## point, that turn with the facing and come out identical on every call.

const SPACING: int = 1400
const CENTER_X: int = 250000
const CENTER_Z: int = 190000
const COUNTS: Array[int] = [1, 2, 5, 20, 37]
const NORTH: Vector2i = Vector2i(0, -FixedMath.DIR_ONE)
const EAST: Vector2i = Vector2i(FixedMath.DIR_ONE, 0)


func _all_kinds() -> Array[Formations.Kind]:
	var kinds: Array[Formations.Kind] = []
	for value: int in Formations.Kind.values():
		kinds.append(value as Formations.Kind)
	return kinds


func _oblique() -> Vector2i:
	return FixedMath.normalize(3, -7, FixedMath.DIR_ONE)


func _make(kind: Formations.Kind, count: int, facing: Vector2i) -> Array[FormationSlot]:
	return Formations.slots(kind, count, CENTER_X, CENTER_Z, facing.x, facing.y, SPACING)


func _label(kind: Formations.Kind, count: int) -> String:
	return "%s N=%d" % [Formations.DISPLAY_NAMES[kind], count]


## Slot position relative to the click point.
func _rel(slot: FormationSlot) -> Vector2i:
	return Vector2i(slot.x - CENTER_X, slot.z - CENTER_Z)


func _dist_from_center(slot: FormationSlot) -> int:
	return FixedMath.length(slot.x - CENTER_X, slot.z - CENTER_Z)


func _min_pair_distance(slots: Array[FormationSlot]) -> int:
	var best: int = 1 << 60
	for i: int in slots.size():
		for j: int in range(i + 1, slots.size()):
			best = mini(best, FixedMath.length(slots[i].x - slots[j].x, slots[i].z - slots[j].z))
	return best


## The spacing each kind promises between its closest pair.
func _min_gap(kind: Formations.Kind) -> int:
	match kind:
		Formations.Kind.RABBLE:
			return SPACING * 3 / 2 * 35 / 100
		Formations.Kind.LOOSE_LINE:
			return SPACING * 5 / 2 - 20
		_:
			return SPACING - 20


func _same(a: Array[FormationSlot], b: Array[FormationSlot]) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if a[i].x != b[i].x or a[i].z != b[i].z:
			return false
		if a[i].facing_x != b[i].facing_x or a[i].facing_z != b[i].facing_z:
			return false
	return true


func test_display_names_cover_every_kind() -> void:
	assert_eq(Formations.DISPLAY_NAMES.size(), Formations.Kind.size())


func test_spacing_for_adds_the_gap_to_two_radii() -> void:
	assert_eq(Formations.spacing_for(400), 800 + Formations.SPACING_GAP)
	assert_eq(Formations.spacing_for(0), Formations.SPACING_GAP)


func test_non_positive_count_gives_no_slots() -> void:
	for kind: Formations.Kind in _all_kinds():
		assert_eq(_make(kind, 0, NORTH).size(), 0, _label(kind, 0))
		assert_eq(_make(kind, -3, NORTH).size(), 0, _label(kind, -3))


func test_slot_count_is_exact() -> void:
	for kind: Formations.Kind in _all_kinds():
		for n: int in COUNTS:
			assert_eq(_make(kind, n, _oblique()).size(), n, _label(kind, n))


func test_slot_facings_have_unit_length() -> void:
	for kind: Formations.Kind in _all_kinds():
		for n: int in COUNTS:
			for slot: FormationSlot in _make(kind, n, _oblique()):
				var facing_len: int = FixedMath.length(slot.facing_x, slot.facing_z)
				assert_almost_eq(facing_len, FixedMath.DIR_ONE, 2, _label(kind, n))


func test_neighbors_keep_their_spacing() -> void:
	for kind: Formations.Kind in _all_kinds():
		for n: int in COUNTS:
			if n < 2:
				continue
			var gap: int = _min_pair_distance(_make(kind, n, _oblique()))
			assert_true(gap >= _min_gap(kind), "%s: closest pair %d < %d" % [_label(kind, n), gap, _min_gap(kind)])


func test_zero_facing_means_north() -> void:
	for kind: Formations.Kind in _all_kinds():
		assert_true(_same(_make(kind, 9, Vector2i.ZERO), _make(kind, 9, NORTH)), _label(kind, 9))


func test_facing_length_does_not_scale_the_shape() -> void:
	for kind: Formations.Kind in _all_kinds():
		var scaled: Array[FormationSlot] = Formations.slots(kind, 9, CENTER_X, CENTER_Z, 0, -5000, SPACING)
		assert_true(_same(scaled, _make(kind, 9, NORTH)), _label(kind, 9))


func test_blocks_are_centered_on_the_click() -> void:
	var blocks: Array[Formations.Kind] = [
		Formations.Kind.SHORT_LINE, Formations.Kind.LONG_LINE, Formations.Kind.LOOSE_LINE,
		Formations.Kind.STAGGERED_LINE, Formations.Kind.BOX, Formations.Kind.RABBLE,
	]
	for kind: Formations.Kind in blocks:
		var limit: int = SPACING * 3 / 2 if kind == Formations.Kind.RABBLE else SPACING
		for n: int in COUNTS:
			var sum: Vector2i = Vector2i.ZERO
			for slot: FormationSlot in _make(kind, n, _oblique()):
				sum += _rel(slot)
			var centroid: int = FixedMath.length(sum.x / n, sum.y / n)
			assert_true(centroid <= limit, "%s: centroid %d from click" % [_label(kind, n), centroid])


func test_wedge_apex_is_on_the_click() -> void:
	for n: int in COUNTS:
		var nearest: int = _dist_from_center(_make(Formations.Kind.WEDGE, n, _oblique())[0])
		assert_almost_eq(nearest, 0, 2, _label(Formations.Kind.WEDGE, n))


func test_encirclement_apex_is_on_the_click_for_odd_counts() -> void:
	for kind: Formations.Kind in [Formations.Kind.SHALLOW_ENCIRCLEMENT, Formations.Kind.DEEP_ENCIRCLEMENT]:
		for n: int in [1, 5, 37]:
			var nearest: int = 1 << 60
			for slot: FormationSlot in _make(kind, n, _oblique()):
				nearest = mini(nearest, _dist_from_center(slot))
			assert_almost_eq(nearest, 0, 2, _label(kind, n))


func test_encirclements_mirror_across_the_facing_axis() -> void:
	# An even count has no slot at the apex, so the middle pair straddles the
	# click point instead. Mirror symmetry covers both cases.
	for kind: Formations.Kind in [Formations.Kind.SHALLOW_ENCIRCLEMENT, Formations.Kind.DEEP_ENCIRCLEMENT]:
		for n: int in COUNTS:
			var slots: Array[FormationSlot] = _make(kind, n, NORTH)
			for k: int in n:
				var a: Vector2i = _rel(slots[k])
				var b: Vector2i = _rel(slots[n - 1 - k])
				assert_almost_eq(a.x, -b.x, 2, "%s slot %d x" % [_label(kind, n), k])
				assert_almost_eq(a.y, b.y, 2, "%s slot %d z" % [_label(kind, n), k])


func test_circle_ring_is_equidistant_and_faces_outward() -> void:
	var slots: Array[FormationSlot] = _make(Formations.Kind.CIRCLE, 12, _oblique())
	var radius: int = _dist_from_center(slots[0])
	for slot: FormationSlot in slots:
		assert_almost_eq(_dist_from_center(slot), radius, 3)
		var rel: Vector2i = _rel(slot)
		assert_true(rel.x * slot.facing_x + rel.y * slot.facing_z > 0, "slot faces the center")


func test_circle_slots_face_away_from_the_center() -> void:
	for n: int in [2, 5, 20, 37, 100, 131, 300]:
		for slot: FormationSlot in _make(Formations.Kind.CIRCLE, n, _oblique()):
			var rel: Vector2i = _rel(slot)
			if rel == Vector2i.ZERO:
				continue
			assert_true(rel.x * slot.facing_x + rel.y * slot.facing_z > 0, _label(Formations.Kind.CIRCLE, n))


func test_big_circles_use_inner_rings_and_keep_spacing() -> void:
	# 6 spacings is the widest ring; 130 fills every ring plus the middle, and
	# 131 has to grow the circle.
	for n: int in [38, 100, 130, 131, 300]:
		var slots: Array[FormationSlot] = _make(Formations.Kind.CIRCLE, n, _oblique())
		assert_eq(slots.size(), n)
		var gap: int = _min_pair_distance(slots)
		assert_true(gap >= SPACING - 20, "N=%d: closest pair %d" % [n, gap])
		var farthest: int = 0
		for slot: FormationSlot in slots:
			farthest = maxi(farthest, _dist_from_center(slot))
		if n <= 130:
			assert_almost_eq(farthest, 6 * SPACING, 20, "N=%d outer radius" % n)
		else:
			assert_true(farthest > 6 * SPACING, "N=%d should outgrow the cap" % n)


func test_shapes_rotate_with_the_facing() -> void:
	# North to east is a quarter turn: (dx, dz) becomes (-dz, dx).
	for kind: Formations.Kind in _all_kinds():
		for n: int in COUNTS:
			var north: Array[FormationSlot] = _make(kind, n, NORTH)
			var east: Array[FormationSlot] = _make(kind, n, EAST)
			for i: int in n:
				var rel: Vector2i = _rel(north[i])
				var msg: String = "%s slot %d" % [_label(kind, n), i]
				assert_almost_eq(east[i].x - CENTER_X, -rel.y, 3, msg)
				assert_almost_eq(east[i].z - CENTER_Z, rel.x, 3, msg)
				assert_almost_eq(east[i].facing_x, -north[i].facing_z, 3, msg)
				assert_almost_eq(east[i].facing_z, north[i].facing_x, 3, msg)


func test_facing_north_puts_the_front_at_smaller_z() -> void:
	var slots: Array[FormationSlot] = _make(Formations.Kind.LONG_LINE, 5, NORTH)
	for slot: FormationSlot in slots:
		assert_eq(slot.facing_x, 0)
		assert_eq(slot.facing_z, -FixedMath.DIR_ONE)
	var short: Array[FormationSlot] = _make(Formations.Kind.SHORT_LINE, 20, NORTH)
	assert_lt(short[0].z, short[19].z, "row 0 is in front (smaller z)")


func _x_spread(slots: Array[FormationSlot]) -> int:
	var lo: int = 1 << 60
	var hi: int = -(1 << 60)
	for slot: FormationSlot in slots:
		lo = mini(lo, slot.x)
		hi = maxi(hi, slot.x)
	return hi - lo


func test_long_line_is_wider_than_short_line() -> void:
	var long_width: int = _x_spread(_make(Formations.Kind.LONG_LINE, 20, NORTH))
	var short_width: int = _x_spread(_make(Formations.Kind.SHORT_LINE, 20, NORTH))
	assert_gt(long_width, short_width)


func test_short_line_is_two_ranks_and_long_line_is_one() -> void:
	var short: Array[FormationSlot] = _make(Formations.Kind.SHORT_LINE, 20, NORTH)
	var ranks: Dictionary[int, int] = {}
	for slot: FormationSlot in short:
		ranks[slot.z] = ranks.get(slot.z, 0) + 1
	assert_eq(ranks.size(), 2)
	for z: int in ranks:
		assert_eq(ranks[z], 10)
	var long_ranks: Dictionary[int, int] = {}
	for slot: FormationSlot in _make(Formations.Kind.LONG_LINE, 20, NORTH):
		long_ranks[slot.z] = 1
	assert_eq(long_ranks.size(), 1)


func test_staggered_line_shifts_odd_rows_by_half_a_spacing() -> void:
	var slots: Array[FormationSlot] = _make(Formations.Kind.STAGGERED_LINE, 20, NORTH)
	# Rows of 10: slot c and slot 10 + c differ by half a spacing sideways.
	for c: int in 10:
		assert_eq(slots[10 + c].x - slots[c].x, SPACING / 2)


func test_encirclements_are_concave_toward_the_front() -> void:
	for n: int in [2, 5, 20, 37]:
		var shallow: Array[FormationSlot] = _make(Formations.Kind.SHALLOW_ENCIRCLEMENT, n, NORTH)
		var deep: Array[FormationSlot] = _make(Formations.Kind.DEEP_ENCIRCLEMENT, n, NORTH)
		for arc: Array[FormationSlot] in [shallow, deep]:
			# North is smaller z, so "further forward" means a smaller z than
			# the click point.
			assert_lt(arc[0].z, CENTER_Z, "N=%d left end" % n)
			assert_lt(arc[n - 1].z, CENTER_Z, "N=%d right end" % n)
		assert_lt(deep[0].z, shallow[0].z, "N=%d deep wraps further on the left" % n)
		assert_lt(deep[n - 1].z, shallow[n - 1].z, "N=%d deep wraps further on the right" % n)


func test_encirclement_slots_face_the_arc_center() -> void:
	# The arc's circle center is straight ahead of the apex, so an end slot
	# faces inward and forward, and the slots on either side face opposite ways.
	for kind: Formations.Kind in [Formations.Kind.SHALLOW_ENCIRCLEMENT, Formations.Kind.DEEP_ENCIRCLEMENT]:
		var slots: Array[FormationSlot] = _make(kind, 5, NORTH)
		assert_gt(slots[0].facing_x, 0, "left end faces right")
		assert_lt(slots[4].facing_x, 0, "right end faces left")
		assert_eq(slots[2].facing_x, 0, "apex faces forward")
		assert_eq(slots[2].facing_z, -FixedMath.DIR_ONE)


func test_wedge_apex_is_frontmost() -> void:
	for n: int in COUNTS:
		var slots: Array[FormationSlot] = _make(Formations.Kind.WEDGE, n, NORTH)
		for slot: FormationSlot in slots:
			assert_true(slot.z >= slots[0].z, "%s: a slot is in front of the apex" % _label(Formations.Kind.WEDGE, n))


func test_wedge_rows_grow_by_one() -> void:
	# 10 slots: rows of 1, 2, 3, 4.
	var slots: Array[FormationSlot] = _make(Formations.Kind.WEDGE, 10, NORTH)
	var rows: Dictionary[int, int] = {}
	for slot: FormationSlot in slots:
		rows[slot.z] = rows.get(slot.z, 0) + 1
	assert_eq(rows.size(), 4)
	for r: int in 4:
		assert_eq(rows[CENTER_Z + r * SPACING], r + 1)


func test_rabble_stays_within_its_jitter_of_a_loose_box() -> void:
	var pitch: int = SPACING * 3 / 2
	var limit: int = pitch * 300 / 1000 + 3
	var box: Array[FormationSlot] = Formations.slots(
		Formations.Kind.BOX, 37, CENTER_X, CENTER_Z, NORTH.x, NORTH.y, pitch
	)
	var rabble: Array[FormationSlot] = _make(Formations.Kind.RABBLE, 37, NORTH)
	var moved: int = 0
	for i: int in 37:
		var dx: int = rabble[i].x - box[i].x
		var dz: int = rabble[i].z - box[i].z
		assert_true(absi(dx) <= limit and absi(dz) <= limit, "slot %d jittered (%d, %d)" % [i, dx, dz])
		if dx != 0 or dz != 0:
			moved += 1
	assert_gt(moved, 30, "most slots should be jittered")


func test_same_input_gives_identical_slots() -> void:
	for kind: Formations.Kind in _all_kinds():
		for n: int in COUNTS:
			assert_true(_same(_make(kind, n, _oblique()), _make(kind, n, _oblique())), _label(kind, n))
