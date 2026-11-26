class_name ScatterPlacer
extends RefCounted
## Where the ground scatter goes (A5, view only): grass tufts, small plants,
## sparse bushes and pebbles over each map, chosen by the same ground layers
## the terrain shader draws (grass, brush, forest floor, sand, rock, mud) and
## standing on the drawn ground. Units walk through all of it; the sim never
## sees it.
##
## Pure functions of the map: the same terrain, structures, water and seed give
## the same layout on every load. Its own RandomNumberGenerator and noise,
## seeded from the map's name (seed_for), never the sim's.
##
## Each terrain cell gets candidates at the densest layer's rate, scaled by a
## clumping noise (patches, not a carpet) and the density knob; each lands at
## a random spot in the cell (no rows) and keeps the layer under it with the
## odds of that layer's density. Then the water, the structures and the
## palettes decide what, if anything, stands there.

enum Kind { GRASS, PLANT, BUSH, PEBBLE }
## The ground layers, in WorldTextures.LAYERS order. The first five are the
## Terrain.Ground values; MUD is laid along the water.
enum Layer { GRASS, BRUSH, FOREST, SAND, ROCK, MUD }

## Every model the placer uses, by its name in world.toml, and its kind.
const KINDS: Dictionary[StringName, int] = {
	&"grass_common_short": Kind.GRASS, &"grass_common_tall": Kind.GRASS,
	&"grass_wispy_short": Kind.GRASS, &"grass_wispy_tall": Kind.GRASS,
	&"clover_1": Kind.GRASS, &"clover_2": Kind.GRASS,
	&"fern_1": Kind.PLANT, &"flower_3_group": Kind.PLANT, &"flower_4_group": Kind.PLANT,
	&"plant_1": Kind.PLANT, &"plant_7": Kind.PLANT, &"mushroom_common": Kind.PLANT,
	&"bush_common": Kind.BUSH, &"bush_common_flowers": Kind.BUSH,
	&"pebble_round_1": Kind.PEBBLE, &"pebble_round_2": Kind.PEBBLE, &"pebble_round_3": Kind.PEBBLE,
	&"pebble_round_4": Kind.PEBBLE, &"pebble_round_5": Kind.PEBBLE,
	&"pebble_square_1": Kind.PEBBLE, &"pebble_square_2": Kind.PEBBLE, &"pebble_square_3": Kind.PEBBLE,
	&"pebble_square_4": Kind.PEBBLE, &"pebble_square_5": Kind.PEBBLE, &"pebble_square_6": Kind.PEBBLE,
}

## Items per square metre on each layer (Layer order), before the clumping
## and the density knob. The tuning knobs for how much scatter there is.
const DENSITY: Array[float] = [0.35, 0.32, 0.28, 0.06, 0.14, 0.28]

## What each layer (Layer order) grows: [model, weight, low, high]. low..high
## is the height in metres it is sized to, or for a pebble a scale of its
## native size. Units are about 1.8 m tall: grass and plants stay at or under
## 0.8 m, bushes 1.0 m. bush_common is in the set but grows nowhere: its leaves
## are the kit's autumn red, which reads as black blots on the green ground.
const PALETTES: Array = [
	[
		[&"grass_common_short", 6.0, 0.28, 0.45], [&"grass_common_tall", 2.0, 0.45, 0.7],
		[&"clover_1", 0.6, 0.12, 0.2], [&"flower_3_group", 0.4, 0.3, 0.45],
	],
	[
		[&"grass_common_tall", 2.0, 0.45, 0.75], [&"grass_common_short", 2.5, 0.3, 0.45],
		[&"fern_1", 1.3, 0.3, 0.5], [&"plant_1", 1.3, 0.3, 0.55], [&"bush_common_flowers", 0.25, 0.6, 1.0],
	],
	[
		[&"fern_1", 3.0, 0.3, 0.55], [&"plant_1", 2.0, 0.3, 0.55], [&"mushroom_common", 0.4, 0.12, 0.25],
		[&"grass_common_tall", 0.6, 0.3, 0.5], [&"bush_common_flowers", 0.3, 0.6, 1.0],
	],
	[
		[&"pebble_round_1", 0.8, 0.5, 1.5], [&"pebble_square_1", 0.6, 0.5, 1.5],
		[&"grass_wispy_short", 1.4, 0.2, 0.4],
	],
	[
		[&"pebble_round_1", 1.0, 0.5, 2.0], [&"pebble_round_3", 1.0, 0.5, 2.0], [&"pebble_square_1", 1.0, 0.5, 2.0],
		[&"grass_wispy_short", 0.25, 0.2, 0.35],
	],
	[
		[&"grass_wispy_tall", 3.0, 0.55, 0.8], [&"grass_wispy_short", 0.8, 0.3, 0.5],
		[&"pebble_round_3", 0.3, 0.5, 1.0],
	],
]
## The weights also keep the triangle count down: the kit's wispy grass (494
## triangles), flower groups (755 and 1690), mushrooms (880) and bushes (1368)
## are a few times the common grass tuft's 155, so they are the accents. And
## each model used is a draw call of its own (ScatterView), so the palettes
## share a few: the set's other plants, flowers and pebbles grow nowhere for
## now.
## Models that grow in patches (flower beds, clover drifts) rather than
## evenly: their weight follows a second noise.
const PATCHY: Array[StringName] = [&"clover_1", &"clover_2", &"flower_3_group", &"flower_4_group"]

## Water deeper than this (metres) has nothing in it; only the mud layer's
## reeds and pebbles wade in at all, and only WADING_SHARE of them.
const REED_DEPTH_M: float = 0.15
const DRY_DEPTH_M: float = 0.02
const WADING_SHARE: float = 0.25
## Nothing stands within this many metres of a structure's footprint.
const STRUCTURE_MARGIN_M: float = 0.5
## The layer under an item is read up to this many samples off its own, so a
## layer border is a ragged mix rather than a step along the samples.
const BORDER_JITTER: float = 1.0
## Faces steeper than this (the world normal's y) are rock, as in the terrain
## shader (TerrainView.ROCK_NORMAL_Y).
const STEEP_NORMAL_Y: float = 0.707
## Clumping: the density is scaled by 1 + CLUMP_STRENGTH * noise, noise about
## -0.7..0.7 over patches CLUMP_M across, kept within CLUMP_MIN..CLUMP_MAX.
const CLUMP_M: float = 14.0
const CLUMP_STRENGTH: float = 1.3
const CLUMP_MIN: float = 0.1
const CLUMP_MAX: float = 2.0
## Patchy models' weight: PATCH_BASE + PATCH_GAIN * noise, noise over
## PATCH_M, never below 0.
const PATCH_M: float = 9.0
const PATCH_BASE: float = 0.3
const PATCH_GAIN: float = 2.0
## How far each kind leans with the ground (Kind order): 0 stands upright, 1
## lies along the slope. Grass and plants grow mostly up.
const TILT: Array[float] = [0.4, 0.5, 0.25, 1.0]
## Each item's width and depth vary by this share around its height's scale.
const SPREAD: float = 0.15
## Per kind: width and depth over the height's scale. The kit's grass tufts
## are tall and narrow; sized to stay under a unit's knee they would be a few
## blades, so they are spread wider to read as cover.
const WIDEN: Array[float] = [2.0, 1.0, 1.0, 1.0]
## The density knob on the Web (WebGL2 on modest GPUs); 1.0 elsewhere.
const DENSITY_SCALE_WEB: float = 0.4


## The density knob for this platform.
static func default_density_scale() -> float:
	return DENSITY_SCALE_WEB if OS.has_feature("web") else 1.0


## A seed from a map's name, FNV-1a over its UTF-8 bytes (32 bits): the same
## on every engine version, unlike hash().
static func seed_for(map_name: String) -> int:
	var h: int = 0x811c9dc5
	for b: int in map_name.to_utf8_buffer():
		h = ((h ^ b) * 0x01000193) & 0xffffffff
	return h


## The layout for a map. view_heights are the heights the view draws under
## structures (MapStructures.view_heights), water_m the water surface per
## sample (WaterMap.load_beside; empty for none), structures may be null.
## native_sizes holds each model's native bounds (ScatterSet.native_sizes):
## its height sizes it, its width keeps its edge off structures; palette
## entries without one are skipped. density_scale multiplies every
## density (0 places nothing).
static func place(
	terrain: Terrain, view_heights: Dictionary[int, int], water_m: PackedFloat32Array,
	structures: MapStructures, native_sizes: Dictionary[StringName, Vector3], seed: int,
	density_scale: float = 1.0
) -> ScatterLayout:
	var layout: ScatterLayout = ScatterLayout.new()
	var palettes: Array = _usable_palettes(native_sizes, layout)
	if density_scale <= 0.0 or layout.names.is_empty():
		return layout
	var heights: PackedInt32Array = view_height_array(terrain, view_heights)
	var depth: PackedFloat32Array = depths(terrain, water_m)
	var mud: PackedFloat32Array = TerrainView.mud_weights(terrain)
	var keep: PackedByteArray = keep_out(terrain, structures)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	var clump: FastNoiseLite = _noise(seed, CLUMP_M)
	var patch: FastNoiseLite = _noise(seed + 1, PATCH_M)
	var cell_m: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var max_density: float = DENSITY.max()
	var w: int = terrain.size_x
	for j: int in terrain.size_z - 1:
		for i: int in terrain.size_x - 1:
			var amount: float = clampf(
				1.0 + CLUMP_STRENGTH * clump.get_noise_2d((i + 0.5) * cell_m, (j + 0.5) * cell_m), CLUMP_MIN, CLUMP_MAX
			)
			var expected: float = max_density * amount * density_scale * cell_m * cell_m
			var count: int = floori(expected)
			if rng.randf() < expected - count:
				count += 1
			for c: int in count:
				var x: float = (i + rng.randf()) * cell_m
				var z: float = (j + rng.randf()) * cell_m
				var si: int = clampi(roundi(x / cell_m + (rng.randf() - 0.5) * 2.0 * BORDER_JITTER), 0, w - 1)
				var sj: int = clampi(roundi(z / cell_m + (rng.randf() - 0.5) * 2.0 * BORDER_JITTER), 0, terrain.size_z - 1)
				var k: int = sj * w + si
				var ground: int = terrain.ground[k]
				var layer: int = ground
				var normal: Vector3 = ground_normal(terrain, heights, x, z)
				if normal.y < STEEP_NORMAL_Y:
					layer = Layer.ROCK
					ground = Terrain.Ground.ROCK
				elif mud[k] > 0.0 and rng.randf() < mud[k]:
					layer = Layer.MUD
				if rng.randf() * max_density >= DENSITY[layer]:
					continue
				var wet: float = water_depth_m(terrain, depth, x, z)
				if wet > (REED_DEPTH_M if layer == Layer.MUD else DRY_DEPTH_M):
					continue
				if wet > DRY_DEPTH_M and rng.randf() >= WADING_SHARE:
					continue
				var entry: Array = _pick(palettes[layer], patch.get_noise_2d(x, z), rng)
				if entry.is_empty():
					continue
				var name: StringName = entry[0]
				var kind: int = KINDS[name]
				var native: Vector3 = native_sizes[name]
				var size: float = lerpf(entry[2], entry[3], rng.randf())
				var scale: float = size if kind == Kind.PEBBLE else size / maxf(native.y, 0.001)
				var yaw: float = rng.randf() * TAU
				var spread_x: float = 1.0 + (rng.randf() - 0.5) * 2.0 * SPREAD
				var spread_z: float = 1.0 + (rng.randf() - 0.5) * 2.0 * SPREAD
				# The footprint's radius, whatever the yaw: half the native
				# width or depth, whichever is larger, at the larger spread.
				var radius: float = 0.5 * maxf(native.x, native.z) * scale * WIDEN[kind] * maxf(spread_x, spread_z)
				if _kept_out(terrain, keep, x, z, cell_m, radius):
					continue
				var lean: Quaternion = Quaternion.IDENTITY.slerp(Quaternion(Vector3.UP, normal), TILT[kind])
				var basis: Basis = Basis(lean) * Basis(Vector3.UP, yaw) * Basis.from_scale(
					Vector3(scale * spread_x * WIDEN[kind], scale, scale * spread_z * WIDEN[kind])
				)
				var origin: Vector3 = Vector3(x, ground_height_m(terrain, heights, x, z), z)
				layout.models.append(layout.names.find(name))
				layout.transforms.append(Transform3D(basis, origin))
				layout.grounds.append(ground)
	return layout


## The heights the view draws (milli-units per sample): the sim's, with
## view_heights in their place where a structure stands.
static func view_height_array(terrain: Terrain, view_heights: Dictionary[int, int]) -> PackedInt32Array:
	var heights: PackedInt32Array = terrain.heights.duplicate()
	for k: int in view_heights:
		heights[k] = view_heights[k]
	return heights


## The drawn ground's height in metres at (x_m, z_m): the terrain mesh's
## triangle there (TerrainMeshBuilder splits each cell along its
## (i, j)-(i+1, j+1) diagonal), from heights (view_height_array).
static func ground_height_m(terrain: Terrain, heights: PackedInt32Array, x_m: float, z_m: float) -> float:
	var corner: Array = _cell(terrain, heights, x_m, z_m)
	var u: float = corner[0]
	var v: float = corner[1]
	var h: Vector4 = corner[2]
	# h is (h00, h10, h01, h11).
	if u >= v:
		return h.x + u * (h.y - h.x) + v * (h.w - h.y)
	return h.x + v * (h.z - h.x) + u * (h.w - h.z)


## The drawn ground's face normal at (x_m, z_m), a unit vector.
static func ground_normal(terrain: Terrain, heights: PackedInt32Array, x_m: float, z_m: float) -> Vector3:
	var corner: Array = _cell(terrain, heights, x_m, z_m)
	var h: Vector4 = corner[2]
	var cell_m: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var dx: float
	var dz: float
	if corner[0] >= corner[1]:
		dx = h.y - h.x
		dz = h.w - h.y
	else:
		dx = h.w - h.z
		dz = h.z - h.x
	return Vector3(-dx / cell_m, 1.0, -dz / cell_m).normalized()


## Water depth in metres per sample: the surface (water_m) less the bed, 0
## where dry or with no water map.
static func depths(terrain: Terrain, water_m: PackedFloat32Array) -> PackedFloat32Array:
	var result: PackedFloat32Array = PackedFloat32Array()
	result.resize(terrain.size_x * terrain.size_z)
	if water_m.size() != result.size():
		return result
	for k: int in result.size():
		if water_m[k] > 0.0:
			result[k] = maxf(water_m[k] - terrain.heights[k] / float(World.UNITS_PER_METER), 0.0)
	return result


## Water depth in metres at (x_m, z_m), bilinear between the samples' depths.
static func water_depth_m(terrain: Terrain, depth: PackedFloat32Array, x_m: float, z_m: float) -> float:
	var cell_m: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var fx: float = x_m / cell_m
	var fz: float = z_m / cell_m
	var i: int = clampi(floori(fx), 0, terrain.size_x - 2)
	var j: int = clampi(floori(fz), 0, terrain.size_z - 2)
	var u: float = clampf(fx - i, 0.0, 1.0)
	var v: float = clampf(fz - j, 0.0, 1.0)
	var k: int = j * terrain.size_x + i
	var near: float = lerpf(depth[k], depth[k + 1], u)
	var far: float = lerpf(depth[k + terrain.size_x], depth[k + terrain.size_x + 1], u)
	return lerpf(near, far, v)


## One byte per sample, 1 where nothing may stand near: every sample a
## structure covers (a house, a wall, Old Mill's slab under the mill) and
## every blocked one.
static func keep_out(terrain: Terrain, structures: MapStructures) -> PackedByteArray:
	var keep: PackedByteArray = terrain.blocked.duplicate()
	if structures != null:
		for record: StructureRecord in structures.records:
			for k: int in record.samples:
				keep[k] = 1
	return keep


## Whether an item centred on (x, z) with this footprint radius comes within
## half a cell plus STRUCTURE_MARGIN_M of a kept-out sample, along x and z
## alike: its edge is kept out, not just its centre.
static func _kept_out(terrain: Terrain, keep: PackedByteArray, x: float, z: float, cell_m: float, radius: float) -> bool:
	var reach: float = 0.5 * cell_m + STRUCTURE_MARGIN_M + radius
	var span: int = ceili(reach / cell_m)
	var ci: int = roundi(x / cell_m)
	var cj: int = roundi(z / cell_m)
	for sj: int in range(maxi(cj - span, 0), mini(cj + span, terrain.size_z - 1) + 1):
		for si: int in range(maxi(ci - span, 0), mini(ci + span, terrain.size_x - 1) + 1):
			if keep[sj * terrain.size_x + si] == 0:
				continue
			if absf(x - si * cell_m) < reach and absf(z - sj * cell_m) < reach:
				return true
	return false


## (u, v, Vector4(h00, h10, h01, h11) in metres) of the cell under (x_m, z_m).
static func _cell(terrain: Terrain, heights: PackedInt32Array, x_m: float, z_m: float) -> Array:
	var cell_m: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var fx: float = x_m / cell_m
	var fz: float = z_m / cell_m
	var i: int = clampi(floori(fx), 0, terrain.size_x - 2)
	var j: int = clampi(floori(fz), 0, terrain.size_z - 2)
	var k: int = j * terrain.size_x + i
	var m: float = float(World.UNITS_PER_METER)
	var h: Vector4 = Vector4(
		heights[k] / m, heights[k + 1] / m, heights[k + terrain.size_x] / m, heights[k + terrain.size_x + 1] / m
	)
	return [clampf(fx - i, 0.0, 1.0), clampf(fz - j, 0.0, 1.0), h]


## PALETTES without the entries native_sizes lacks, and layout.names filled
## with every model that is left.
static func _usable_palettes(native_sizes: Dictionary[StringName, Vector3], layout: ScatterLayout) -> Array:
	var result: Array = []
	for palette: Array in PALETTES:
		var usable: Array = []
		for entry: Array in palette:
			if native_sizes.has(entry[0]):
				usable.append(entry)
				if not layout.names.has(entry[0]):
					layout.names.append(entry[0])
		result.append(usable)
	return result


## An entry of palette, by weight; patchy ones weighed by patch_noise. Empty
## when the palette is.
static func _pick(palette: Array, patch_noise: float, rng: RandomNumberGenerator) -> Array:
	var patch: float = maxf(PATCH_BASE + PATCH_GAIN * patch_noise, 0.0)
	var total: float = 0.0
	for entry: Array in palette:
		total += entry[1] * (patch if PATCHY.has(entry[0]) else 1.0)
	if total <= 0.0:
		return []
	var roll: float = rng.randf() * total
	for entry: Array in palette:
		roll -= entry[1] * (patch if PATCHY.has(entry[0]) else 1.0)
		if roll < 0.0:
			return entry
	return palette[palette.size() - 1]


static func _noise(seed: int, period_m: float) -> FastNoiseLite:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / period_m
	noise.fractal_octaves = 2
	return noise
