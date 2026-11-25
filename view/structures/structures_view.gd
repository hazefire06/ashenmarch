class_name StructuresView
extends Node3D
## Draws a model on each structure a map recorded (MapStructures), fitted to
## its blocked samples by StructurePlacer: a kit house or the mill on each
## house footprint, wall sections along each wall with a gatehouse in each
## gap. A structure the kit has no piece for is a grey box of its size, so
## maps draw before the kit exists. One child per structure, in record order.
##
## Every surface is drawn with world_model.gdshader, built from the kit
## material it replaces. Each structure has its own materials, so its fire is
## its own: update_fire() passes on the share of its samples burning and burnt
## out. set_grade() and set_weather() reach every model and survive build().

const MODEL_SHADER: Shader = preload("res://view/structures/world_model.gdshader")
const PLACEHOLDER_COLOR: Color = Color(0.55, 0.55, 0.55)
## Lifts a box centred on its origin onto its base, as KitPiece's are.
const ON_BASE: Transform3D = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.5, 0.0))

var _records: Array[StructureRecord] = []
## Per structure, its materials, and the last fire share passed on to them:
## x burning, y burnt out.
var _record_materials: Array[Array] = []
var _fire_amounts: PackedVector2Array = PackedVector2Array()
var _materials: Array[ShaderMaterial] = []
## What the placeholders are drawn as and with: a unit box standing on its
## origin, and a grey material for it and for kit surfaces with none.
var _box: BoxMesh = BoxMesh.new()
var _box_piece: KitPiece = KitPiece.new()
var _grey: StandardMaterial3D = StandardMaterial3D.new()
var _grade_tint: Color = Color.WHITE
var _grade_desaturation: float = 0.0
var _wetness: float = 0.0
var _snow_cover: float = 0.0


func _init() -> void:
	_box.size = Vector3.ONE
	_box_piece.size_m = Vector3.ONE
	_grey.albedo_color = PLACEHOLDER_COLOR


## Replaces any models with one per record of structures (none for null).
func build(structures: MapStructures, terrain: Terrain, kit: WorldKit = WorldKit.shared()) -> void:
	for child: Node in get_children():
		# Out of the tree now, so a rebuild in the same frame can reuse the names.
		remove_child(child)
		child.queue_free()
	_records = []
	_record_materials = []
	_fire_amounts = PackedVector2Array()
	_materials = []
	if structures == null:
		return
	for n: int in structures.records.size():
		var record: StructureRecord = structures.records[n]
		# Shared by the structure's repeated surfaces, never across structures.
		var cache: Dictionary[Material, ShaderMaterial] = {}
		var model: Node3D = _wall(record, terrain, kit, cache) if record.kind == &"wall" else _house(record, terrain, kit, cache)
		model.name = "Structure_%d" % n
		add_child(model)
		_records.append(record)
		_record_materials.append(cache.values())
		_fire_amounts.append(Vector2.ZERO)


## Grades every model for the mission's look, as TerrainView.set_grade() does
## the ground: tint multiplies (white changes nothing), desaturation 0..1
## drains toward gray (0 changes nothing).
func set_grade(tint: Color, desaturation: float) -> void:
	_grade_tint = tint
	_grade_desaturation = desaturation
	for material: ShaderMaterial in _materials:
		_apply_grade(material)


## Passes how wet and snow-covered the world is on to every model.
func set_weather(weather: Weather) -> void:
	_wetness = weather.wetness() / 1000.0
	_snow_cover = weather.snow_cover() / 1000.0
	for material: ShaderMaterial in _materials:
		_apply_weather(material)


## Brings each structure's glow and char up to date with the fire on its
## samples. Call it after each World.step(). A fire that has never burned has
## no grid yet, and burns nothing.
func update_fire(fire: Fire, terrain: Terrain) -> void:
	if fire == null:
		return
	var has_grid: bool = fire.state.size() == terrain.size_x * terrain.size_z
	for n: int in _records.size():
		var samples: PackedInt32Array = _records[n].samples
		var counts: Vector2 = Vector2.ZERO
		if has_grid:
			for k: int in samples:
				var cell: int = fire.state[k]
				if cell == Fire.Cell.BURNING:
					counts.x += 1.0
				elif cell == Fire.Cell.SCORCHED:
					counts.y += 1.0
		var amount: Vector2 = counts / maxf(1.0, samples.size())
		if amount == _fire_amounts[n]:
			continue
		_fire_amounts[n] = amount
		for material: ShaderMaterial in _record_materials[n]:
			material.set_shader_parameter("burning", amount.x)
			material.set_shader_parameter("charred", amount.y)


## For tests: the share of structure index's samples burning (x) and burnt
## out (y), as last passed to its materials.
func fire_amount(index: int) -> Vector2:
	return _fire_amounts[index]


func _house(record: StructureRecord, terrain: Terrain, kit: WorldKit, cache: Dictionary[Material, ShaderMaterial]) -> Node3D:
	var piece: KitPiece = kit.mill if record.model == &"mill" else StructurePlacer.house_piece(record, kit.houses, terrain)
	if piece == null or piece.scene == null:
		var box: MeshInstance3D = MeshInstance3D.new()
		box.mesh = _box
		box.transform = StructurePlacer.house_transform(record, _box_piece, terrain) * ON_BASE
		box.material_override = _shader_for(_grey, cache)
		return box
	var model: Node3D = piece.scene.instantiate() as Node3D
	model.transform = StructurePlacer.house_transform(record, piece, terrain)
	_shade(model, cache)
	return model


## A wall's sections are instanced, one MultiMeshInstance3D per mesh in the
## wall piece; its gatehouses (one per gap) are whole scenes.
func _wall(record: StructureRecord, terrain: Terrain, kit: WorldKit, cache: Dictionary[Material, ShaderMaterial]) -> Node3D:
	if kit.wall == null or kit.wall.scene == null:
		var transforms: Array[Transform3D] = []
		for t: Transform3D in StructurePlacer.wall_transforms(record, _box_piece, terrain):
			transforms.append(t * ON_BASE)
		var boxes: MultiMeshInstance3D = _multimesh(_box, transforms)
		boxes.material_override = _shader_for(_grey, cache)
		return boxes
	var wall: Node3D = Node3D.new()
	var placed: Array[Transform3D] = StructurePlacer.wall_transforms(record, kit.wall, terrain)
	var section: Node3D = kit.wall.scene.instantiate() as Node3D
	for found: Node in section.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = found as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var mesh: Mesh = mesh_instance.mesh.duplicate() as Mesh
		for i: int in mesh.get_surface_count():
			_set_surface_material(mesh, i, _shader_for(mesh_instance.get_active_material(i), cache))
		var local: Transform3D = _transform_in(mesh_instance, section)
		var transforms: Array[Transform3D] = []
		for t: Transform3D in placed:
			transforms.append(t * local)
		wall.add_child(_multimesh(mesh, transforms))
	section.free()
	if kit.gate != null and kit.gate.scene != null:
		for t: Transform3D in StructurePlacer.gate_transforms(record, kit.gate, terrain):
			var gate: Node3D = kit.gate.scene.instantiate() as Node3D
			gate.transform = t
			_shade(gate, cache)
			wall.add_child(gate)
	return wall


## Draws every surface of every mesh in model with the model shader.
func _shade(model: Node3D, cache: Dictionary[Material, ShaderMaterial]) -> void:
	for found: Node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = found as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for i: int in mesh_instance.mesh.get_surface_count():
			mesh_instance.set_surface_override_material(i, _shader_for(mesh_instance.get_active_material(i), cache))
		mesh_instance.material_override = null


## The model material for a kit surface's own (grey for none), made once per
## structure and source.
func _shader_for(source: Material, cache: Dictionary[Material, ShaderMaterial]) -> ShaderMaterial:
	var key: Material = _grey if source == null else source
	if cache.has(key):
		return cache[key]
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = MODEL_SHADER
	if key is BaseMaterial3D:
		material.set_shader_parameter("albedo_texture", (key as BaseMaterial3D).albedo_texture)
		material.set_shader_parameter("albedo_color", (key as BaseMaterial3D).albedo_color)
	material.set_shader_parameter("burning", 0.0)
	material.set_shader_parameter("charred", 0.0)
	_apply_grade(material)
	_apply_weather(material)
	cache[key] = material
	_materials.append(material)
	return material


func _apply_grade(material: ShaderMaterial) -> void:
	material.set_shader_parameter("grade_tint", _grade_tint)
	material.set_shader_parameter("grade_desaturation", _grade_desaturation)


func _apply_weather(material: ShaderMaterial) -> void:
	material.set_shader_parameter("wetness", _wetness)
	material.set_shader_parameter("snow_cover", _snow_cover)


static func _multimesh(mesh: Mesh, transforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for n: int in transforms.size():
		multimesh.set_instance_transform(n, transforms[n])
	var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	return instance


static func _set_surface_material(mesh: Mesh, surface: int, material: Material) -> void:
	if mesh is ArrayMesh:
		(mesh as ArrayMesh).surface_set_material(surface, material)
	elif mesh is PrimitiveMesh:
		(mesh as PrimitiveMesh).material = material


## node's transform relative to root, an ancestor.
static func _transform_in(node: Node3D, root: Node3D) -> Transform3D:
	var t: Transform3D = Transform3D.IDENTITY
	var at: Node3D = node
	while at != root:
		t = at.transform * t
		at = at.get_parent() as Node3D
	return t
