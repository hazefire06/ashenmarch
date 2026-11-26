class_name ScatterView
extends Node3D
## Draws the ground scatter (A5, view only): what ScatterPlacer lays out for a
## map, as one MultiMeshInstance3D per model per CHUNK_M square, so the camera
## culls whole chunks, and each chunk stops drawing past its kind's fade range
## (the shader shrinks items into the ground just before). Units walk through
## all of it; the sim never sees it.
##
## Every surface is drawn with scatter.gdshader, one material per kit surface
## and kind, shared by every chunk. set_grade() and set_weather() reach them
## all and survive build(); the fire comes from TerrainView's fire texture,
## read per item in the shader. rebuild_region() (after an explosion scars the
## ground) moves the items there back onto the new ground.

const SCATTER_SHADER: Shader = preload("res://view/scatter/scatter.gdshader")
const CHUNK_M: float = 48.0
## Per ScatterPlacer.Kind (grass, plant, bush, pebble): metres from the camera
## at which items have shrunk away; the last FADE_MARGIN_M of it they shrink.
const FADE_END_M: Array[float] = [115.0, 130.0, 190.0, 160.0]
const FADE_MARGIN_M: float = 25.0
## Per kind: sway (scatter.gdshader's wind), how far the lighting normal
## bends up, what fire does (its burn_mode) and whether it casts a shadow.
const WIND: Array[float] = [0.05, 0.03, 0.008, 0.0]
const NORMAL_UP: Array[float] = [0.6, 0.5, 0.65, 0.0]
const BURN_MODE: Array[int] = [1, 1, 2, 0]
const SHADOWS: Array[bool] = [false, false, true, false]
## Per kind: how the kit's bright colours are brought toward the ground's
## (scatter.gdshader's kit_tint and kit_desaturation).
const KIT_TINT: Array[Color] = [
	Color(0.66, 0.7, 0.5), Color(0.72, 0.76, 0.6), Color(0.95, 0.95, 0.85), Color(0.9, 0.9, 0.88),
]
const KIT_DESATURATION: Array[float] = [0.4, 0.45, 0.35, 0.2]

var _materials: Array[ShaderMaterial] = []
## Per MultiMeshInstance3D: its multimesh, the items' placements (world
## space, before the model's own transform) and that transform (local).
var _groups: Array[Dictionary] = []
var _terrain: Terrain
var _view_heights: Dictionary[int, int] = {}
var _heights: PackedInt32Array = PackedInt32Array()
var _count: int = 0
var _grade_tint: Color = Color.WHITE
var _grade_desaturation: float = 0.0
var _recolor: PackedColorArray = _no_recolor()
var _wetness: float = 0.0
var _snow_cover: float = 0.0


## Replaces any scatter with the layout for this map. map_name seeds it
## (ScatterPlacer.seed_for), so a map always gets the same scatter.
## fire_texture is TerrainView.fire_texture() (null: nothing burns).
func build(
	terrain: Terrain, structures: MapStructures, water_m: PackedFloat32Array, map_name: String,
	fire_texture: Texture2D = null, scatter_set: ScatterSet = ScatterSet.shared(),
	density_scale: float = ScatterPlacer.default_density_scale()
) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_materials = []
	_groups = []
	_count = 0
	_terrain = terrain
	_view_heights = {}
	if structures != null:
		_view_heights = structures.view_heights(terrain)
	_heights = ScatterPlacer.view_height_array(terrain, _view_heights)
	var layout: ScatterLayout = ScatterPlacer.place(
		terrain, _view_heights, water_m, structures, scatter_set.native_heights(),
		ScatterPlacer.seed_for(map_name), density_scale
	)
	if layout.size() == 0:
		return
	var cache: Dictionary[String, ShaderMaterial] = {}
	# Per model in layout.names: [[mesh, local transform], ...].
	var parts: Array[Array] = []
	for name: StringName in layout.names:
		parts.append(_parts(scatter_set.find(name), ScatterPlacer.KINDS[name], terrain, fire_texture, cache))
	var by_chunk: Dictionary[Vector3i, PackedInt32Array] = {}
	for n: int in layout.size():
		var at: Vector3 = layout.transforms[n].origin
		var key: Vector3i = Vector3i(floori(at.x / CHUNK_M), floori(at.z / CHUNK_M), layout.models[n])
		if not by_chunk.has(key):
			by_chunk[key] = PackedInt32Array()
		by_chunk[key].append(n)
	var keys: Array[Vector3i] = by_chunk.keys()
	keys.sort()
	for key: Vector3i in keys:
		var kind: int = ScatterPlacer.KINDS[layout.names[key.z]]
		var centre: Vector3 = Vector3((key.x + 0.5) * CHUNK_M, 0.0, (key.y + 0.5) * CHUNK_M)
		var items: PackedInt32Array = by_chunk[key]
		var placements: Array[Transform3D] = []
		var grounds: PackedByteArray = PackedByteArray()
		for n: int in items:
			placements.append(layout.transforms[n])
			grounds.append(layout.grounds[n])
		for part: Array in parts[key.z]:
			var instance: MultiMeshInstance3D = _chunk(part[0], part[1], placements, grounds, centre)
			instance.name = "Scatter_%d_%d_%s" % [key.x, key.y, layout.names[key.z]]
			instance.visibility_range_end = FADE_END_M[kind] + CHUNK_M * 0.75
			instance.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON if SHADOWS[kind] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			add_child(instance)
			_groups.append({"multimesh": instance.multimesh, "placements": placements, "local": part[1], "centre": centre})
		_count += items.size()


## Items placed, for tests and the budget report.
func instance_count() -> int:
	return _count


## Where each drawn item stands on the ground (the middle of its model's
## base), world space, per chunk instance in child order, for tests (the
## headless renderer keeps no multimesh data).
func drawn_origins() -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	for group: Dictionary in _groups:
		var origins: PackedVector3Array = PackedVector3Array()
		for placed: Transform3D in group["placements"]:
			origins.append(placed.origin)
		result.append(origins)
	return result


## Every material the scatter draws with, for tests.
func materials() -> Array[ShaderMaterial]:
	return _materials


## Grades every item for the mission's look, as TerrainView.set_grade() does
## the ground: tint multiplies (white changes nothing), desaturation 0..1
## drains toward gray, recolor is one color per Terrain.Ground blended by its
## alpha (empty for none).
func set_grade(tint: Color, desaturation: float, recolor: Array[Color] = []) -> void:
	_grade_tint = tint
	_grade_desaturation = desaturation
	_recolor = PackedColorArray(recolor) if recolor.size() == Terrain.GROUND_COUNT else _no_recolor()
	for material: ShaderMaterial in _materials:
		_apply_grade(material)


## Passes how wet and snow-covered the world is on to every item, when it
## changes.
func set_weather(weather: Weather) -> void:
	var wetness: float = weather.wetness() / 1000.0
	var snow_cover: float = weather.snow_cover() / 1000.0
	if wetness == _wetness and snow_cover == _snow_cover:
		return
	_wetness = wetness
	_snow_cover = snow_cover
	for material: ShaderMaterial in _materials:
		_apply_weather(material)


## Puts the items standing in cells (a rectangle of samples, what
## Terrain.scar() returns, plus a sample's margin) back on the ground the
## terrain now has. TerrainView.region_rebuilt calls it.
func rebuild_region(terrain: Terrain, cells: Rect2i) -> void:
	if not cells.has_area() or terrain != _terrain or _groups.is_empty():
		return
	var dirty: Rect2i = cells.grow(1).intersection(Rect2i(0, 0, terrain.size_x, terrain.size_z))
	for j: int in range(dirty.position.y, dirty.end.y):
		for i: int in range(dirty.position.x, dirty.end.x):
			var k: int = j * terrain.size_x + i
			_heights[k] = _view_heights.get(k, terrain.heights[k])
	var cell_m: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var area: Rect2 = Rect2(Vector2(dirty.position) * cell_m, Vector2(dirty.size) * cell_m)
	for group: Dictionary in _groups:
		var centre: Vector3 = group["centre"]
		var chunk: Rect2 = Rect2(centre.x - CHUNK_M * 0.5, centre.z - CHUNK_M * 0.5, CHUNK_M, CHUNK_M)
		if not chunk.grow(cell_m).intersects(area):
			continue
		var multimesh: MultiMesh = group["multimesh"]
		var placements: Array[Transform3D] = group["placements"]
		var local: Transform3D = group["local"]
		for n: int in placements.size():
			var at: Vector3 = placements[n].origin
			if not area.has_point(Vector2(at.x, at.z)):
				continue
			var placed: Transform3D = placements[n]
			placed.origin.y = ScatterPlacer.ground_height_m(terrain, _heights, at.x, at.z)
			placements[n] = placed
			multimesh.set_instance_transform(n, Transform3D(Basis.IDENTITY, -centre) * placements[n] * local)


## [mesh, local transform] for each mesh of model, its surfaces drawn with
## the scatter shader for kind. Empty for a missing model.
func _parts(
	model: ScatterModel, kind: int, terrain: Terrain, fire_texture: Texture2D, cache: Dictionary[String, ShaderMaterial]
) -> Array:
	var result: Array = []
	if model == null or model.scene == null:
		return result
	var root: Node3D = model.scene.instantiate() as Node3D
	for found: Node in [root] + root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var mesh: Mesh = mesh_instance.mesh.duplicate() as Mesh
		for i: int in mesh.get_surface_count():
			var material: ShaderMaterial = _material_for(mesh_instance.get_active_material(i), kind, terrain, fire_texture, cache)
			if mesh is ArrayMesh:
				(mesh as ArrayMesh).surface_set_material(i, material)
		var local: Transform3D = Transform3D(Basis.IDENTITY, model.offset) * _transform_in(mesh_instance, root)
		result.append([mesh, local])
	root.free()
	return result


func _material_for(
	source: Material, kind: int, terrain: Terrain, fire_texture: Texture2D, cache: Dictionary[String, ShaderMaterial]
) -> ShaderMaterial:
	var key: String = "%d:%d" % [0 if source == null else source.get_instance_id(), kind]
	if cache.has(key):
		return cache[key]
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = SCATTER_SHADER
	material.set_shader_parameter("alpha_cutoff", 0.0)
	if source is BaseMaterial3D:
		var base: BaseMaterial3D = source as BaseMaterial3D
		material.set_shader_parameter("albedo_texture", base.albedo_texture)
		material.set_shader_parameter("albedo_color", base.albedo_color)
		if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			material.set_shader_parameter("alpha_cutoff", base.alpha_scissor_threshold)
	if fire_texture != null:
		material.set_shader_parameter("fire_state", fire_texture)
	material.set_shader_parameter("cell_size", terrain.cell_size / float(World.UNITS_PER_METER))
	material.set_shader_parameter("sample_count", Vector2(terrain.size_x, terrain.size_z))
	material.set_shader_parameter("kit_tint", KIT_TINT[kind])
	material.set_shader_parameter("kit_desaturation", KIT_DESATURATION[kind])
	material.set_shader_parameter("burn_mode", BURN_MODE[kind])
	material.set_shader_parameter("wind", WIND[kind])
	material.set_shader_parameter("normal_up", NORMAL_UP[kind])
	material.set_shader_parameter("fade_end", FADE_END_M[kind])
	material.set_shader_parameter("fade_margin", FADE_MARGIN_M)
	_apply_grade(material)
	_apply_weather(material)
	cache[key] = material
	_materials.append(material)
	return material


## A MultiMeshInstance3D at centre drawing mesh once per placement (times
## local), each with its ground in the custom data's R.
static func _chunk(
	mesh: Mesh, local: Transform3D, placements: Array[Transform3D], grounds: PackedByteArray, centre: Vector3
) -> MultiMeshInstance3D:
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = placements.size()
	var to_chunk: Transform3D = Transform3D(Basis.IDENTITY, -centre)
	for n: int in placements.size():
		multimesh.set_instance_transform(n, to_chunk * placements[n] * local)
		multimesh.set_instance_custom_data(n, Color(grounds[n] / 255.0, 0.0, 0.0, 0.0))
	var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.position = centre
	return instance


func _apply_grade(material: ShaderMaterial) -> void:
	material.set_shader_parameter("grade_tint", _grade_tint)
	material.set_shader_parameter("grade_desaturation", _grade_desaturation)
	material.set_shader_parameter("ground_recolor", _recolor)


func _apply_weather(material: ShaderMaterial) -> void:
	material.set_shader_parameter("wetness", _wetness)
	material.set_shader_parameter("snow_cover", _snow_cover)


static func _no_recolor() -> PackedColorArray:
	var none: PackedColorArray = PackedColorArray()
	none.resize(Terrain.GROUND_COUNT)
	none.fill(Color(0.0, 0.0, 0.0, 0.0))
	return none


## node's transform relative to root, an ancestor (or root itself).
static func _transform_in(node: Node3D, root: Node3D) -> Transform3D:
	var t: Transform3D = Transform3D.IDENTITY
	var at: Node3D = node
	while at != root:
		t = at.transform * t
		at = at.get_parent() as Node3D
	return t
