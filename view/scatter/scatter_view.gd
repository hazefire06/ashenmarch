class_name ScatterView
extends Node3D
## Draws the ground scatter (A5, view only): what ScatterPlacer lays out for a
## map, round the focus, the ground point the camera looks at (set_focus;
## _process follows the viewport's camera). Each kind reaches out to its
## FADE_END_M from the focus, shrinking into the ground over the last
## FADE_MARGIN_M, so the cost is the same at every zoom and the scatter is
## where the player looks. Units walk through all of it; the sim never sees it.
##
## One MultiMeshInstance3D per model mesh, so a model is one draw call. Its
## items are kept in BUCKET_M squares, each a ready-made slice of instance
## buffer, and only the buckets within the model's reach of the focus are
## submitted, rebuilt when the focus has moved REFRESH_M: items far from the
## focus are never sent to the GPU at all.
##
## Every surface is drawn with the scatter shaders, one material per kit
## surface and kind. set_grade() and set_weather() reach them all and survive
## build(); the fire comes from TerrainView's fire texture, read per item in
## the shader. rebuild_region() (after an explosion scars the ground) moves the
## items there back onto the new ground.

## Solid models, and leaf and flower cards cut out by alpha. Two shaders, so
## only the cards can discard (a discard costs early depth testing on tile
## GPUs); both include scatter.gdshaderinc.
const OPAQUE_SHADER: Shader = preload("res://view/scatter/scatter_opaque.gdshader")
const CUTOUT_SHADER: Shader = preload("res://view/scatter/scatter_cutout.gdshader")
## Side of the squares items are kept in. A bucket is submitted when any of it
## is within reach, so at most a bucket's diagonal of items past the fade is
## sent, already shrunk to nothing.
const BUCKET_M: float = 16.0
## Per ScatterPlacer.Kind (grass, plant, bush, pebble, reed, reed head): metres
## along the
## ground from the focus at which items have shrunk away; the last
## FADE_MARGIN_M of it they shrink. The frame-rate knobs (make bench).
const FADE_END_M: Array[float] = [65.0, 50.0, 70.0, 60.0, 70.0, 70.0]
const FADE_MARGIN_M: float = 20.0
## Nothing is drawn while the camera is further than this from the focus (the
## widest zooms, where tufts would be smaller than a pixel).
const CAMERA_CUTOFF_M: float = 200.0
## The shader's fade follows the focus once the look point has moved
## FOCUS_STEP_M; the submitted buckets once it has moved REFRESH_M (well
## inside FADE_MARGIN_M, so nothing pops at the edge).
const FOCUS_STEP_M: float = 1.0
const REFRESH_M: float = 4.0
## Floats per instance in a MultiMesh buffer: a 3 x 4 transform by rows, then
## the custom color.
const STRIDE: int = 16
## Per kind: sway (scatter.gdshaderinc's wind), how far the lighting normal
## bends up, what fire does (its burn_mode) and whether it casts a shadow.
const WIND: Array[float] = [0.05, 0.03, 0.008, 0.0, 0.035, 0.0]
const NORMAL_UP: Array[float] = [0.6, 0.5, 0.65, 0.0, 0.4, 0.3]
const BURN_MODE: Array[int] = [1, 1, 2, 0, 1, 1]
const SHADOWS: Array[bool] = [false, false, false, false, false, false]
## Per kind: how the kit's bright colours are brought toward the ground's
## (scatter.gdshaderinc's kit_tint and kit_desaturation).
## Reeds are a darker olive than the grass round them, their seed heads a
## dark brown.
const KIT_TINT: Array[Color] = [
	Color(0.52, 0.6, 0.38), Color(0.62, 0.68, 0.5), Color(0.95, 0.95, 0.85), Color(0.9, 0.9, 0.88),
	Color(0.55, 0.58, 0.32), Color(0.42, 0.26, 0.14),
]
const KIT_DESATURATION: Array[float] = [0.4, 0.45, 0.35, 0.2, 0.25, 0.6]

var _materials: Array[ShaderMaterial] = []
## Per model mesh (one MultiMeshInstance3D each): "multimesh", "node", "kind",
## "local" (the mesh's transform in the model), "placements" (every item of
## the model, world space, before local), "grounds" (each item's
## Terrain.Ground), "buckets" (Vector2i -> PackedInt32Array of item indices)
## and "slices" (Vector2i -> PackedFloat32Array, those items' buffer).
var _groups: Array[Dictionary] = []
var _terrain: Terrain
var _view_heights: Dictionary[int, int] = {}
var _heights: PackedInt32Array = PackedInt32Array()
var _count: int = 0
var _focus: Vector3 = Vector3(INF, 0.0, INF)
var _submitted_at: Vector3 = Vector3(INF, 0.0, INF)
var _grade_tint: Color = Color.WHITE
var _grade_desaturation: float = 0.0
var _recolor: PackedColorArray = _no_recolor()
var _wetness: float = 0.0
var _snow_cover: float = 0.0


## Replaces any scatter with the layout for this map. map_name seeds it
## (ScatterPlacer.seed_for), so a map always gets the same scatter.
## fire_texture is TerrainView.fire_texture() (null: nothing burns). Nothing
## is submitted until the first set_focus(). trails (TerrainView.trail_mask(),
## or null) keep the scatter off the worn ground.
func build(
	terrain: Terrain, structures: MapStructures, water_m: PackedFloat32Array, map_name: String,
	fire_texture: Texture2D = null, scatter_set: ScatterSet = ScatterSet.shared(),
	density_scale: float = ScatterPlacer.default_density_scale(), trails: TrailMask = null
) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_materials = []
	_groups = []
	_count = 0
	_focus = Vector3(INF, 0.0, INF)
	_submitted_at = Vector3(INF, 0.0, INF)
	_terrain = terrain
	_view_heights = {}
	if structures != null:
		_view_heights = structures.view_heights(terrain)
	_heights = ScatterPlacer.view_height_array(terrain, _view_heights)
	var layout: ScatterLayout = ScatterPlacer.place(
		terrain, _view_heights, water_m, structures, scatter_set.native_sizes(),
		ScatterPlacer.seed_for(map_name), density_scale, trails
	)
	_count = layout.size()
	if layout.size() == 0:
		return
	var cache: Dictionary[String, ShaderMaterial] = {}
	var by_model: Array[PackedInt32Array] = []
	by_model.resize(layout.names.size())
	for n: int in layout.size():
		by_model[layout.models[n]].append(n)
	for m: int in layout.names.size():
		var name: StringName = layout.names[m]
		var kind: int = ScatterPlacer.kind_of(name)
		var placements: Array[Transform3D] = []
		var grounds: PackedByteArray = PackedByteArray()
		for n: int in by_model[m]:
			placements.append(layout.transforms[n])
			grounds.append(layout.grounds[n])
		if placements.is_empty():
			continue
		for part: Array in _parts(scatter_set.find(ScatterPlacer.model_of(name)), kind, terrain, fire_texture, cache):
			var multimesh: MultiMesh = MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_custom_data = true
			multimesh.mesh = part[0]
			var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
			instance.name = "Scatter_%s" % name
			instance.multimesh = multimesh
			instance.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON if SHADOWS[kind] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			add_child(instance)
			var group: Dictionary = {
				"multimesh": multimesh, "node": instance, "kind": kind, "local": part[1],
				"placements": placements, "grounds": grounds, "buckets": {}, "slices": {}, "submitted": PackedInt32Array(),
			}
			for n: int in placements.size():
				var key: Vector2i = _bucket_of(placements[n].origin)
				if not group["buckets"].has(key):
					group["buckets"][key] = PackedInt32Array()
				group["buckets"][key].append(n)
			for key: Vector2i in group["buckets"]:
				group["slices"][key] = _slice(group, group["buckets"][key])
			_groups.append(group)


## Follows the viewport's camera: its look point on the ground becomes the
## focus once it has moved FOCUS_STEP_M; past CAMERA_CUTOFF_M from it nothing
## is drawn.
func _process(_delta: float) -> void:
	if _groups.is_empty() or not is_inside_tree():
		return
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var look: Vector3 = look_point(camera.global_transform)
	var near: bool = camera.global_position.distance_to(look) <= CAMERA_CUTOFF_M
	if near != visible:
		visible = near
	if near and Vector2(look.x - _focus.x, look.z - _focus.z).length() >= FOCUS_STEP_M:
		set_focus(look)


## Draws the scatter round focus (world space; its y is unused): each kind
## out to its FADE_END_M along the ground. The buckets within reach are
## submitted again once the focus has moved REFRESH_M since they last were.
func set_focus(focus: Vector3) -> void:
	_focus = focus
	for material: ShaderMaterial in _materials:
		material.set_shader_parameter("fade_centre", focus)
	if Vector2(focus.x - _submitted_at.x, focus.z - _submitted_at.z).length() < REFRESH_M:
		return
	_submitted_at = focus
	var at: Vector2 = Vector2(focus.x, focus.z)
	for group: Dictionary in _groups:
		var reach: float = FADE_END_M[group["kind"]]
		var first: Vector2i = _bucket_of(Vector3(at.x - reach, 0.0, at.y - reach))
		var last: Vector2i = _bucket_of(Vector3(at.x + reach, 0.0, at.y + reach))
		var buffer: PackedFloat32Array = PackedFloat32Array()
		var submitted: PackedInt32Array = PackedInt32Array()
		var slices: Dictionary = group["slices"]
		for bz: int in range(first.y, last.y + 1):
			for bx: int in range(first.x, last.x + 1):
				var key: Vector2i = Vector2i(bx, bz)
				if not slices.has(key):
					continue
				var nearest: Vector2 = Vector2(
					clampf(at.x, bx * BUCKET_M, (bx + 1) * BUCKET_M), clampf(at.y, bz * BUCKET_M, (bz + 1) * BUCKET_M)
				)
				if nearest.distance_to(at) >= reach:
					continue
				buffer.append_array(slices[key])
				submitted.append_array(group["buckets"][key])
		var multimesh: MultiMesh = group["multimesh"]
		multimesh.instance_count = submitted.size()
		if not submitted.is_empty():
			multimesh.buffer = buffer
		group["submitted"] = submitted
		(group["node"] as Node3D).visible = not submitted.is_empty()


## The focus set_focus() last had, for tests.
func focus() -> Vector3:
	return _focus


## Where a camera at view looks at the ground: along its forward ray to the
## drawn ground (a few steps of following the ground's height), or straight
## below it when it looks up.
func look_point(view: Transform3D) -> Vector3:
	var forward: Vector3 = -view.basis.z
	var below: Vector3 = view.origin
	if _terrain == null:
		return below
	var ground: float = ScatterPlacer.ground_height_m(_terrain, _heights, below.x, below.z)
	if forward.y > -0.05:
		return Vector3(below.x, ground, below.z)
	var hit: Vector3 = below
	for step: int in 4:
		var t: float = (view.origin.y - ground) / -forward.y
		hit = view.origin + forward * maxf(t, 0.0)
		ground = ScatterPlacer.ground_height_m(_terrain, _heights, hit.x, hit.z)
	return hit


## Items placed, for tests and the budget report.
func instance_count() -> int:
	return _count


## Where each item stands on the ground (the middle of its model's base),
## world space, one array per model mesh in child order, for tests (the
## headless renderer keeps no multimesh data).
func drawn_origins() -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	for group: Dictionary in _groups:
		var origins: PackedVector3Array = PackedVector3Array()
		for placed: Transform3D in group["placements"]:
			origins.append(placed.origin)
		result.append(origins)
	return result


## Where each submitted item stands, world space, one array per model mesh in
## child order, for tests: what the GPU is given since the last set_focus().
func submitted_origins() -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	for group: Dictionary in _groups:
		var origins: PackedVector3Array = PackedVector3Array()
		var placements: Array[Transform3D] = group["placements"]
		for n: int in group["submitted"]:
			origins.append(placements[n].origin)
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
## terrain now has, and submits again. TerrainView.region_rebuilt calls it.
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
	var first: Vector2i = _bucket_of(Vector3(area.position.x, 0.0, area.position.y))
	var last: Vector2i = _bucket_of(Vector3(area.end.x, 0.0, area.end.y))
	for group: Dictionary in _groups:
		var placements: Array[Transform3D] = group["placements"]
		for bz: int in range(first.y, last.y + 1):
			for bx: int in range(first.x, last.x + 1):
				var key: Vector2i = Vector2i(bx, bz)
				if not group["buckets"].has(key):
					continue
				var moved: bool = false
				for n: int in group["buckets"][key]:
					var at: Vector3 = placements[n].origin
					if not area.has_point(Vector2(at.x, at.z)):
						continue
					var placed: Transform3D = placements[n]
					placed.origin.y = ScatterPlacer.ground_height_m(terrain, _heights, at.x, at.z)
					placements[n] = placed
					moved = true
				if moved:
					group["slices"][key] = _slice(group, group["buckets"][key])
	if _focus.x != INF:
		_submitted_at = Vector3(INF, 0.0, INF)
		set_focus(_focus)


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
	material.shader = OPAQUE_SHADER
	if source is BaseMaterial3D:
		var base: BaseMaterial3D = source as BaseMaterial3D
		material.set_shader_parameter("albedo_texture", base.albedo_texture)
		material.set_shader_parameter("albedo_color", base.albedo_color)
		if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			material.shader = CUTOUT_SHADER
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


## The bucket a world position falls in.
static func _bucket_of(at: Vector3) -> Vector2i:
	return Vector2i(floori(at.x / BUCKET_M), floori(at.z / BUCKET_M))


## The instance buffer of group's items at indices: each placement times the
## mesh's local transform, by rows, then its ground in the custom color's R.
static func _slice(group: Dictionary, indices: PackedInt32Array) -> PackedFloat32Array:
	var placements: Array[Transform3D] = group["placements"]
	var grounds: PackedByteArray = group["grounds"]
	var local: Transform3D = group["local"]
	var buffer: PackedFloat32Array = PackedFloat32Array()
	buffer.resize(indices.size() * STRIDE)
	var o: int = 0
	for n: int in indices:
		var t: Transform3D = placements[n] * local
		buffer[o] = t.basis.x.x
		buffer[o + 1] = t.basis.y.x
		buffer[o + 2] = t.basis.z.x
		buffer[o + 3] = t.origin.x
		buffer[o + 4] = t.basis.x.y
		buffer[o + 5] = t.basis.y.y
		buffer[o + 6] = t.basis.z.y
		buffer[o + 7] = t.origin.y
		buffer[o + 8] = t.basis.x.z
		buffer[o + 9] = t.basis.y.z
		buffer[o + 10] = t.basis.z.z
		buffer[o + 11] = t.origin.z
		buffer[o + 12] = grounds[n] / 255.0
		o += STRIDE
	return buffer


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
