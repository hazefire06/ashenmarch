extends GutTest
## ScatterPlacer: the view-only ground scatter. Deterministic per seed, sized
## by the density knob, never in deep water or on a structure, the right
## models for each ground layer, and standing on the drawn ground.

const SEED: int = 12345


## Every model the placer can choose, one metre tall (pebbles 0.1 m) and
## `width` times as wide, so a test can read an item's height from its scale.
static func _sizes(width: float = 1.0) -> Dictionary[StringName, Vector3]:
	var sizes: Dictionary[StringName, Vector3] = {}
	for name: StringName in ScatterPlacer.KINDS:
		var tall: float = 0.1 if ScatterPlacer.KINDS[name] == ScatterPlacer.Kind.PEBBLE else 1.0
		sizes[name] = Vector3(tall * width, tall, tall * width)
	return sizes


static func _rows(size_x: int, size_z: int, letter: String) -> Array[String]:
	var rows: Array[String] = []
	for j: int in size_z:
		rows.append(letter.repeat(size_x))
	return rows


static func _place(
	terrain: Terrain, structures: MapStructures = null, water_m: PackedFloat32Array = PackedFloat32Array(),
	seed: int = SEED, density: float = 1.0, width: float = 1.0
) -> ScatterLayout:
	var view_heights: Dictionary[int, int] = {}
	if structures != null:
		view_heights = structures.view_heights(terrain)
	return ScatterPlacer.place(terrain, view_heights, water_m, structures, _sizes(width), seed, density)


## The names a layer's palette can choose.
static func _palette_names(layer: int) -> Dictionary[StringName, bool]:
	var names: Dictionary[StringName, bool] = {}
	for entry: Array in ScatterPlacer.PALETTES[layer]:
		names[entry[0]] = true
	return names


func test_the_same_input_places_the_same_items() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(24, 24, "."))
	var a: ScatterLayout = _place(terrain)
	var b: ScatterLayout = _place(terrain)
	assert_gt(a.size(), 50, "grass gets a fair amount of scatter")
	assert_eq(a.size(), b.size())
	assert_eq(a.models, b.models)
	assert_eq(a.transforms, b.transforms)
	var other: ScatterLayout = _place(terrain, null, PackedFloat32Array(), SEED + 1)
	assert_ne(other.transforms, a.transforms, "another seed, another layout")


func test_the_seed_is_stable_per_map_name() -> void:
	assert_eq(ScatterPlacer.seed_for("riverside"), ScatterPlacer.seed_for("riverside"))
	assert_ne(ScatterPlacer.seed_for("riverside"), ScatterPlacer.seed_for("the_ford"))
	# FNV-1a, 32 bits: fixed by its definition, not by the engine's hash().
	assert_eq(ScatterPlacer.seed_for("a"), 0xe40c292c)


func test_the_density_knob_scales_the_count() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(48, 48, "."))
	var full: int = _place(terrain).size()
	var half: int = _place(terrain, null, PackedFloat32Array(), SEED, 0.5).size()
	var none: int = _place(terrain, null, PackedFloat32Array(), SEED, 0.0).size()
	assert_almost_eq(float(half) / full, 0.5, 0.1, "half the density, about half the items (%d of %d)" % [half, full])
	assert_eq(none, 0)


func test_nothing_stands_in_deep_water() -> void:
	# A pond 2 m deep in the middle, a shallow ford strip 0.1 m deep beside it.
	var rows: Array[String] = _rows(30, 30, ".")
	for j: int in range(8, 22):
		rows[j] = "........" + "2".repeat(14) + "........"
	var terrain: Terrain = TestTerrains.from_ascii(rows)
	var water_m: PackedFloat32Array = PackedFloat32Array()
	water_m.resize(terrain.size_x * terrain.size_z)
	for k: int in water_m.size():
		if terrain.water[k] != 0:
			water_m[k] = 2.0
	var layout: ScatterLayout = _place(terrain, null, water_m)
	assert_gt(layout.size(), 0)
	for n: int in layout.size():
		var at: Vector3 = layout.transforms[n].origin
		var depth: float = ScatterPlacer.water_depth_m(terrain, ScatterPlacer.depths(terrain, water_m), at.x, at.z)
		assert_lte(depth, ScatterPlacer.REED_DEPTH_M, "item %d at %s is in %.2f m of water" % [n, at, depth])
		var inside: bool = at.x > 9.0 and at.x < 20.0 and at.z > 9.0 and at.z < 20.0
		assert_false(inside, "item %d at %s is inside the pond" % [n, at])


func test_nothing_stands_on_or_beside_a_structure() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(30, 30, "."))
	var house: StructureRecord = StructureRecord.new()
	house.kind = &"house"
	house.base_m = 0.0
	var samples: PackedInt32Array = PackedInt32Array()
	for j: int in range(10, 16):
		for i: int in range(10, 18):
			samples.append(j * terrain.size_x + i)
	house.samples = samples
	var structures: MapStructures = MapStructures.new()
	structures.records = [house]
	var layout: ScatterLayout = _place(terrain, structures)
	assert_gt(layout.size(), 0)
	# The footprint is samples 10..17 by 10..15, each half a cell wide, plus the margin.
	var reach: float = 0.5 + ScatterPlacer.STRUCTURE_MARGIN_M
	for n: int in layout.size():
		var at: Vector3 = layout.transforms[n].origin
		var near: bool = at.x > 10.0 - reach and at.x < 17.0 + reach and at.z > 10.0 - reach and at.z < 15.0 + reach
		assert_false(near, "item %d at %s is on or beside the house" % [n, at])


func test_a_wide_item_keeps_its_edge_off_a_structure() -> void:
	# Every model three times as wide as it is tall: a 0.4 m tuft is 1.2 m
	# across, more before WIDEN. Its edge, not just its centre, stays out.
	var terrain: Terrain = TestTerrains.from_ascii(_rows(30, 30, "b"))
	var wall: StructureRecord = StructureRecord.new()
	wall.kind = &"house"
	var samples: PackedInt32Array = PackedInt32Array()
	for i: int in range(5, 25):
		samples.append(15 * terrain.size_x + i)
	wall.samples = samples
	var structures: MapStructures = MapStructures.new()
	structures.records = [wall]
	var layout: ScatterLayout = _place(terrain, structures, PackedFloat32Array(), SEED, 1.0, 3.0)
	assert_gt(layout.size(), 0)
	var near: int = 0
	for n: int in layout.size():
		var at: Vector3 = layout.transforms[n].origin
		var scale: Vector3 = layout.transforms[n].basis.get_scale()
		var tall: float = _sizes(3.0)[layout.names[layout.models[n]]].y
		var radius: float = 0.5 * 3.0 * tall * maxf(scale.x, scale.z)
		if at.x < 5.0 - 2.0 or at.x > 24.0 + 2.0:
			continue
		var gap: float = absf(at.z - 15.0) - radius
		assert_gte(gap, 0.5 + ScatterPlacer.STRUCTURE_MARGIN_M - 0.001, "item %d at %s, %.2f m across, reaches the wall" % [n, at, radius * 2.0])
		if gap < 3.0:
			near += 1
	assert_gt(near, 0, "items still grow close to the wall")


func test_nothing_stands_on_a_blocked_sample() -> void:
	var rows: Array[String] = _rows(20, 20, ".")
	rows[10] = ".........##........."
	var terrain: Terrain = TestTerrains.from_ascii(rows)
	var layout: ScatterLayout = _place(terrain)
	for n: int in layout.size():
		var at: Vector3 = layout.transforms[n].origin
		assert_false(at.x > 8.0 and at.x < 11.0 and at.z > 9.0 and at.z < 11.0, "item %d at %s is on the blocked samples" % [n, at])


func test_each_layer_chooses_from_its_own_palette() -> void:
	var cases: Dictionary[String, int] = {
		".": ScatterPlacer.Layer.GRASS, "b": ScatterPlacer.Layer.BRUSH, "w": ScatterPlacer.Layer.FOREST,
		"s": ScatterPlacer.Layer.SAND, "r": ScatterPlacer.Layer.ROCK,
	}
	for letter: String in cases:
		var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, letter))
		var layout: ScatterLayout = _place(terrain)
		var allowed: Dictionary[StringName, bool] = _palette_names(cases[letter])
		assert_gt(layout.size(), 0, "layer %s gets something" % letter)
		var seen: Dictionary[StringName, bool] = {}
		for n: int in layout.size():
			var name: StringName = layout.names[layout.models[n]]
			seen[name] = true
			assert_true(allowed.has(name), "%s on layer %s" % [name, letter])
		assert_gt(seen.size(), 1, "layer %s mixes models" % letter)


func test_rock_gets_only_pebbles_and_a_little_grass() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, "r"))
	var layout: ScatterLayout = _place(terrain)
	var pebbles: int = 0
	for n: int in layout.size():
		if ScatterPlacer.KINDS[layout.names[layout.models[n]]] == ScatterPlacer.Kind.PEBBLE:
			pebbles += 1
	assert_gt(float(pebbles) / layout.size(), 0.75, "mostly pebbles on rock")


func test_steep_slopes_count_as_rock() -> void:
	# 1.5 m up per metre: far past the walkable 45 degrees.
	var terrain: Terrain = TestTerrains.ramp_x(30, 30, 1500)
	var layout: ScatterLayout = _place(terrain)
	var allowed: Dictionary[StringName, bool] = _palette_names(ScatterPlacer.Layer.ROCK)
	assert_gt(layout.size(), 0)
	for n: int in layout.size():
		assert_true(allowed.has(layout.names[layout.models[n]]), "%s on a cliff" % layout.names[layout.models[n]])


func test_reeds_grow_at_the_water_edge() -> void:
	var rows: Array[String] = _rows(40, 40, ".")
	for j: int in range(15, 25):
		rows[j] = "3".repeat(40)
	var terrain: Terrain = TestTerrains.from_ascii(rows)
	var water_m: PackedFloat32Array = PackedFloat32Array()
	water_m.resize(terrain.size_x * terrain.size_z)
	for k: int in water_m.size():
		if terrain.water[k] != 0:
			water_m[k] = 1.5
	var layout: ScatterLayout = _place(terrain, null, water_m)
	var reeds_near: int = 0
	var reeds_far: int = 0
	for n: int in layout.size():
		if layout.names[layout.models[n]] != &"grass_wispy_tall":
			continue
		var z: float = layout.transforms[n].origin.z
		if (z > 12.0 and z < 15.0) or (z > 24.0 and z < 27.0):
			reeds_near += 1
		elif z < 8.0 or z > 32.0:
			reeds_far += 1
	assert_gt(reeds_near, 5, "reeds along both banks")
	assert_gt(reeds_near, reeds_far * 3, "more reeds at the bank than far from it (%d, %d)" % [reeds_near, reeds_far])


func test_items_stand_on_the_drawn_ground() -> void:
	var size: int = 20
	var heights: PackedInt32Array = PackedInt32Array()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	heights.resize(size * size)
	for k: int in heights.size():
		heights[k] = rng.randi_range(0, 600)
	var empty: PackedByteArray = PackedByteArray()
	empty.resize(size * size)
	var terrain: Terrain = Terrain.new(size, size, 1000, heights, empty, empty.duplicate(), 1000)
	var layout: ScatterLayout = _place(terrain)
	assert_gt(layout.size(), 50)
	var mesh: ArrayMesh = TerrainMeshBuilder.build_chunk(terrain, 0, 0)
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for n: int in layout.size():
		var at: Vector3 = layout.transforms[n].origin
		var drawn: float = _mesh_height(vertices, indices, at.x, at.z)
		assert_almost_eq(at.y, drawn, 0.01, "item %d at %s" % [n, at])


func test_items_under_a_structure_free_slab_use_the_view_heights() -> void:
	# A raised 4 x 4 slab the view draws at 0, with no structure record left
	# on it: an item beside it stands on the drawn slope, not the sim's.
	var terrain: Terrain = TestTerrains.flat(12, 12)
	var view_heights: Dictionary[int, int] = {}
	for j: int in range(4, 8):
		for i: int in range(4, 8):
			terrain.heights[j * 12 + i] = 3000
			view_heights[j * 12 + i] = 0
	var heights: PackedInt32Array = ScatterPlacer.view_height_array(terrain, view_heights)
	assert_almost_eq(ScatterPlacer.ground_height_m(terrain, heights, 5.5, 5.5), 0.0, 0.0001)
	assert_almost_eq(ScatterPlacer.ground_height_m(terrain, ScatterPlacer.view_height_array(terrain, {}), 5.5, 5.5), 3.0, 0.0001)


func test_sizes_stay_low() -> void:
	var cases: Array[String] = [".", "b", "w", "s", "r"]
	for letter: String in cases:
		var terrain: Terrain = TestTerrains.from_ascii(_rows(30, 30, letter))
		var layout: ScatterLayout = _place(terrain)
		for n: int in layout.size():
			var name: StringName = layout.names[layout.models[n]]
			var kind: int = ScatterPlacer.KINDS[name]
			var tall: float = layout.transforms[n].basis.get_scale().y * _sizes()[name].y
			if kind == ScatterPlacer.Kind.PEBBLE:
				var factor: float = layout.transforms[n].basis.get_scale().y
				assert_between(factor, 0.5 * 0.85, 2.0 * 1.15, "%s scaled %.2f" % [name, factor])
			elif kind == ScatterPlacer.Kind.BUSH:
				assert_lte(tall, 1.0 + 0.001, "%s is %.2f m" % [name, tall])
			else:
				assert_lte(tall, 0.8 + 0.001, "%s is %.2f m" % [name, tall])


func test_items_are_not_in_rows() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(30, 30, "."))
	var layout: ScatterLayout = _place(terrain)
	var xs: Dictionary[float, bool] = {}
	for n: int in layout.size():
		xs[snappedf(fposmod(layout.transforms[n].origin.x, 1.0), 0.05)] = true
	assert_gt(xs.size(), 15, "positions spread through each cell, not on a grid")


## The height of the triangle under (x, z) among the mesh's triangles.
static func _mesh_height(vertices: PackedVector3Array, indices: PackedInt32Array, x: float, z: float) -> float:
	var p: Vector2 = Vector2(x, z)
	for t: int in range(0, indices.size(), 3):
		var a: Vector3 = vertices[indices[t]]
		var b: Vector3 = vertices[indices[t + 1]]
		var c: Vector3 = vertices[indices[t + 2]]
		var w: Vector3 = _barycentric(p, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z))
		if w.x >= -0.0001 and w.y >= -0.0001 and w.z >= -0.0001:
			return a.y * w.x + b.y * w.y + c.y * w.z
	return NAN


static func _barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0: Vector2 = b - a
	var v1: Vector2 = c - a
	var v2: Vector2 = p - a
	var den: float = v0.x * v1.y - v1.x * v0.y
	var v: float = (v2.x * v1.y - v1.x * v2.y) / den
	var w: float = (v0.x * v2.y - v2.x * v0.y) / den
	return Vector3(1.0 - v - w, v, w)
