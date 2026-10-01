class_name FireView
extends Node3D
## Flames and smoke over the sim's burning cells. Reads the World; never
## writes it. MainView calls setup() once and after_step() after each
## World.step().
##
## Each burning cell (a key of Fire.burn_end) gets one flame: a camera-facing
## billboard standing on the ground at the cell, in one MultiMesh, drawn by
## fire.gdshader. A third of them, those where (i + j) % 3 == 0 for the
## cell's sample (i, j), also get a column of rising smoke (smoke.gdshader) in
## a second MultiMesh. Everything animated (the flicker, the rise) is a
## function of TIME in the shaders; this class only places the instances.
##
## The buffers are rewritten, whole, on ticks where something changed: a
## fire changes a few cells a tick, and a rewrite of 4096 flames is about a
## millisecond. Past FLAME_LIMIT burning cells the first FLAME_LIMIT in
## ascending sample index are shown, which is stable from tick to tick.
## Each cell's jitter and flicker phase come from a hash of its sample
## index, so a rebuild moves nothing.
##
## No terrain means no fire (World.fire is null); then, like before any fire,
## this draws nothing.

const FLAME_SHADER: Shader = preload("res://view/effects/fire.gdshader")
const SMOKE_SHADER: Shader = preload("res://view/effects/smoke.gdshader")
## Most flames and smoke columns drawn.
const FLAME_LIMIT: int = 4096
const SMOKE_LIMIT: int = 1500
## A flame's width and height in meters, before the scale jitter. The smoke
## puff's size is the smoke shader's own.
const FLAME_SIZE: Vector2 = Vector2(0.9, 1.2)
## How far a flame strays from its cell's sample point on each axis, meters,
## so a burning field isn't a lattice.
const JITTER: float = 0.35
## A flame is this much bigger or smaller at most (0.25 is 75% to 125%).
const SCALE_JITTER: float = 0.25
## Different hashes for the flame and the smoke of one cell, so the smoke
## doesn't sit exactly over the flame's jitter.
const FLAME_SALT: int = 0
const SMOKE_SALT: int = 0x5BD1E995
## Floats per instance in the MultiMesh buffer: a 3x4 transform (the origin
## is the ground point; the rest stays identity), then custom data
## (phase, scale, 0, 0).
const INSTANCE_FLOATS: int = 16

var _world: World
var _flames: MultiMeshInstance3D
var _smoke: MultiMeshInstance3D
## The sample index drawn by flame n and by smoke column n, both ascending.
var _flame_cells: PackedInt32Array = PackedInt32Array()
var _smoke_cells: PackedInt32Array = PackedInt32Array()
## What the MultiMeshes hold, kept here too: instance data can't be read back
## from a MultiMesh without a renderer, and it's what flame_position() answers
## from.
var _flame_buffer: PackedFloat32Array = PackedFloat32Array()
var _smoke_buffer: PackedFloat32Array = PackedFloat32Array()
## Cells burning when the buffers were last written.
var _burning: int = 0


## Starts reading the world's fire, drawing whatever already burns.
func setup(world: World) -> void:
	_world = world
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_flame_cells.clear()
	_smoke_cells.clear()
	_burning = 0
	_flame_buffer = _new_buffer(FLAME_LIMIT)
	_smoke_buffer = _new_buffer(SMOKE_LIMIT)
	_flames = _make_layer("Flames", FLAME_LIMIT, FLAME_SHADER, _flame_buffer)
	_smoke = _make_layer("Smoke", SMOKE_LIMIT, SMOKE_SHADER, _smoke_buffer)
	var flame_material: ShaderMaterial = _flames.material_override as ShaderMaterial
	flame_material.set_shader_parameter("size", FLAME_SIZE)
	if _world.fire != null:
		_rebuild(_world.fire)


## Picks up the tick just simulated. Call it once after each World.step(),
## which clears the fire's list of changed cells.
func after_step() -> void:
	var fire: Fire = _world.fire
	if fire == null:
		return
	# fire.changed is cleared at the start of every step, so a cell lit
	# between steps (World.ignite from outside one) would never show up in
	# it. A different number of burning cells catches that case.
	if fire.changed.is_empty() and fire.burn_end.size() == _burning:
		return
	_rebuild(fire)


## Flames drawn.
func flame_count() -> int:
	return _flame_cells.size()


## Smoke columns drawn.
func smoke_count() -> int:
	return _smoke_cells.size()


## Where flame n (0 .. flame_count() - 1) stands, in meters: on the ground at
## its cell's height, up to JITTER from the cell's sample point on x and z.
func flame_position(n: int) -> Vector3:
	return _position_in(_flame_buffer, n)


## Where smoke column n starts, in meters, like flame_position().
func smoke_position(n: int) -> Vector3:
	return _position_in(_smoke_buffer, n)


## The sample index (j * size_x + i) flame n burns on.
func flame_cell(n: int) -> int:
	return _flame_cells[n]


## The sample index smoke column n rises from.
func smoke_cell(n: int) -> int:
	return _smoke_cells[n]


## The cells to draw flames on: the burning ones (sample indices, in any
## order), ascending, and at most limit of them, so a fire too big for the
## buffer loses the same cells every tick.
static func flame_cells(burning: Array, limit: int) -> PackedInt32Array:
	var cells: PackedInt32Array = PackedInt32Array(burning)
	cells.sort()
	if cells.size() > limit:
		cells.resize(maxi(limit, 0))
	return cells


## Of the cells drawn with flames (ascending), those that also smoke: where
## (i + j) % 3 == 0 for the cell's sample (i, j), at most limit of them.
static func smoke_cells(cells: PackedInt32Array, size_x: int, limit: int) -> PackedInt32Array:
	var smoking: PackedInt32Array = PackedInt32Array()
	for k: int in cells:
		if smoking.size() >= limit:
			break
		var at: Vector2i = cell_of(k, size_x)
		if (at.x + at.y) % 3 == 0:
			smoking.append(k)
	return smoking


## The sample (i, j) of a sample index, for a terrain size_x samples wide.
static func cell_of(k: int, size_x: int) -> Vector2i:
	var i: int = k % size_x
	@warning_ignore("integer_division") # Exact: k - i is a whole number of rows.
	var j: int = (k - i) / size_x
	return Vector2i(i, j)


## Four values in 0..1 that depend only on the sample index and the salt:
## x and z jitter, flicker phase, and scale. Different cells get unrelated
## values, which is all that keeps a fire from looking like a grid.
static func variation(k: int, salt: int) -> Vector4:
	# A 32-bit integer mixer (Thomas Mueller's), masked to 32 bits since
	# GDScript integers are 64. Its constant is small enough that no product
	# overflows 64 bits.
	var h: int = (k ^ salt) & 0xFFFFFFFF
	h = (((h >> 16) ^ h) * 0x45D9F3B) & 0xFFFFFFFF
	h = (((h >> 16) ^ h) * 0x45D9F3B) & 0xFFFFFFFF
	h = (h >> 16) ^ h
	return Vector4(
		float(h & 0xFF), float((h >> 8) & 0xFF), float((h >> 16) & 0xFF), float((h >> 24) & 0xFF)
	) / 255.0


func _process(_delta: float) -> void:
	if _world == null:
		return
	# The smoke leans with the wind, which only the view reads.
	var weather: Weather = _world.weather
	var wind: Vector2 = Vector2(weather.wind_x, weather.wind_z) / float(World.UNITS_PER_METER)
	(_smoke.material_override as ShaderMaterial).set_shader_parameter("wind", wind)


# Rewrites both buffers from the burning cells.
func _rebuild(fire: Fire) -> void:
	_burning = fire.burn_end.size()
	_flame_cells = flame_cells(fire.burn_end.keys(), FLAME_LIMIT)
	_smoke_cells = smoke_cells(_flame_cells, fire.terrain.size_x, SMOKE_LIMIT)
	_write(_flame_buffer, _flame_cells, fire.terrain, FLAME_SALT)
	_write(_smoke_buffer, _smoke_cells, fire.terrain, SMOKE_SALT)
	_flames.multimesh.buffer = _flame_buffer
	_flames.multimesh.visible_instance_count = _flame_cells.size()
	_smoke.multimesh.buffer = _smoke_buffer
	_smoke.multimesh.visible_instance_count = _smoke_cells.size()


# Writes one instance per cell: the ground point (jittered on x and z, at the
# sample's height), and the flicker phase and scale from the cell's hash.
func _write(
	buffer: PackedFloat32Array, cells: PackedInt32Array, terrain: Terrain, salt: int
) -> void:
	var mm: float = float(World.UNITS_PER_METER)
	var cell_m: float = terrain.cell_size / mm
	for n: int in cells.size():
		var at: Vector2i = cell_of(cells[n], terrain.size_x)
		var roll: Vector4 = variation(cells[n], salt)
		var offset: int = n * INSTANCE_FLOATS
		buffer[offset + 3] = at.x * cell_m + (roll.x - 0.5) * 2.0 * JITTER
		buffer[offset + 7] = terrain.sample_height(at.x, at.y) / mm
		buffer[offset + 11] = at.y * cell_m + (roll.y - 0.5) * 2.0 * JITTER
		buffer[offset + 12] = roll.z
		buffer[offset + 13] = 1.0 + (roll.w - 0.5) * 2.0 * SCALE_JITTER


func _position_in(buffer: PackedFloat32Array, n: int) -> Vector3:
	var offset: int = n * INSTANCE_FLOATS
	return Vector3(buffer[offset + 3], buffer[offset + 7], buffer[offset + 11])


# A buffer for count instances with identity transforms at the origin, and
# custom data zero: only each instance's origin and custom data get written.
static func _new_buffer(count: int) -> PackedFloat32Array:
	var buffer: PackedFloat32Array = PackedFloat32Array()
	buffer.resize(count * INSTANCE_FLOATS)
	for n: int in count:
		var offset: int = n * INSTANCE_FLOATS
		buffer[offset] = 1.0
		buffer[offset + 5] = 1.0
		buffer[offset + 10] = 1.0
		# A real scale until the instance is used, so no zero-size quad.
		buffer[offset + 13] = 1.0
	return buffer


func _make_layer(
	layer_name: String, limit: int, shader: Shader, buffer: PackedFloat32Array
) -> MultiMeshInstance3D:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# Both are set while there are no instances: they can't change after.
	multimesh.use_custom_data = true
	multimesh.mesh = quad
	multimesh.instance_count = limit
	multimesh.buffer = buffer
	multimesh.visible_instance_count = 0
	if _world.terrain != null:
		# Fire can be anywhere on the map, and smoke climbs; don't cull by the
		# bounds of whichever instances were written first.
		var mm: float = float(World.UNITS_PER_METER)
		multimesh.custom_aabb = AABB(
			Vector3(-10.0, -1000.0, -10.0),
			Vector3(_world.terrain.extent_x() / mm + 20.0, 3000.0, _world.terrain.extent_z() / mm + 20.0)
		)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = shader
	var layer: MultiMeshInstance3D = MultiMeshInstance3D.new()
	layer.name = layer_name
	layer.multimesh = multimesh
	layer.material_override = material
	layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(layer)
	return layer
