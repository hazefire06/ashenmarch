extends GutTest
## StructuresView: one model per recorded structure (a grey box where the kit
## has no piece), each surface drawn with the model shader, which carries the
## mission's grade, the weather and the fire on the structure's samples.

const RIVERSIDE: String = "res://maps/riverside/riverside.tres"
const THE_FORD: String = "res://maps/the_ford/the_ford.tres"
const MODEL_SHADER: Shader = preload("res://view/structures/world_model.gdshader")


class Loaded:
	var terrain: Terrain
	var structures: MapStructures


func _load(path: String) -> Loaded:
	var info: MapInfo = load(path) as MapInfo
	var loaded: Loaded = Loaded.new()
	loaded.terrain = Terrain.load_map(info)
	loaded.structures = MapStructures.load_beside(info.heightmap_path)
	return loaded


func _view(loaded: Loaded, kit: WorldKit = WorldKit.new()) -> StructuresView:
	var view: StructuresView = StructuresView.new()
	add_child_autofree(view)
	view.build(loaded.structures, loaded.terrain, kit)
	return view


## Every material on every mesh under node: overrides, surface overrides and
## the meshes' own.
static func _materials(node: Node) -> Array[Material]:
	var found: Array[Material] = []
	if node is GeometryInstance3D and (node as GeometryInstance3D).material_override != null:
		found.append((node as GeometryInstance3D).material_override)
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		for i: int in mi.get_surface_override_material_count():
			if mi.get_surface_override_material(i) != null:
				found.append(mi.get_surface_override_material(i))
	if node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh.mesh != null:
		var mesh: Mesh = (node as MultiMeshInstance3D).multimesh.mesh
		for i: int in mesh.get_surface_count():
			if mesh.surface_get_material(i) != null:
				found.append(mesh.surface_get_material(i))
	for child: Node in node.get_children():
		found.append_array(_materials(child))
	return found


## A one-house kit piece: a scene with two meshes under a pivot, each with its
## own StandardMaterial3D.
static func _house_piece() -> KitPiece:
	var root: Node3D = Node3D.new()
	var pivot: Node3D = Node3D.new()
	root.add_child(pivot)
	pivot.owner = root
	for color: Color in [Color.RED, Color.BLUE]:
		var mesh_instance: MeshInstance3D = MeshInstance3D.new()
		var box: BoxMesh = BoxMesh.new()
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.albedo_color = color
		box.material = material
		mesh_instance.mesh = box
		pivot.add_child(mesh_instance)
		mesh_instance.owner = root
	var scene: PackedScene = PackedScene.new()
	scene.pack(root)
	root.free()
	var piece: KitPiece = KitPiece.new()
	piece.scene = scene
	piece.size_m = Vector3(1, 1, 1)
	return piece


func test_one_model_per_structure_with_an_empty_kit() -> void:
	for path: String in [RIVERSIDE, THE_FORD]:
		var loaded: Loaded = _load(path)
		var view: StructuresView = _view(loaded)
		assert_eq(view.get_child_count(), loaded.structures.records.size(), path)
		for child: Node in view.get_children():
			var mesh: Mesh = null
			if child is MeshInstance3D:
				mesh = (child as MeshInstance3D).mesh
			elif child is MultiMeshInstance3D:
				mesh = (child as MultiMeshInstance3D).multimesh.mesh
			assert_true(mesh is BoxMesh, "%s %s is a box" % [path, child.name])


func test_a_placeholder_house_fills_its_footprint() -> void:
	var loaded: Loaded = _load(RIVERSIDE)
	var view: StructuresView = _view(loaded)
	var record: StructureRecord = loaded.structures.records[0]
	var house: MeshInstance3D = view.get_child(0) as MeshInstance3D
	var box: AABB = house.transform * house.mesh.get_aabb()
	var rect: Rect2 = StructurePlacer.footprint_rect(record, loaded.terrain)
	assert_almost_eq(box.position.x, rect.position.x, 0.01)
	assert_almost_eq(box.end.z, rect.end.y, 0.01)
	assert_almost_eq(box.position.y, record.base_m, 0.01)
	assert_almost_eq(box.end.y, record.base_m + record.height_m, 0.01)


func test_a_placeholder_wall_is_one_multimesh_of_its_pieces() -> void:
	var loaded: Loaded = _load(THE_FORD)
	var view: StructuresView = _view(loaded)
	var wall: MultiMeshInstance3D = view.get_child(0) as MultiMeshInstance3D
	assert_not_null(wall, "The Ford's first record is its palisade")
	assert_gt(wall.multimesh.instance_count, 50)


func test_a_kit_piece_is_instanced_with_the_model_shader_on_every_surface() -> void:
	var loaded: Loaded = _load(RIVERSIDE)
	var kit: WorldKit = WorldKit.new()
	kit.houses = [_house_piece()]
	var view: StructuresView = _view(loaded, kit)
	assert_eq(view.get_child_count(), 8)
	var colors: Array[Color] = []
	var materials: Array[Material] = _materials(view.get_child(0))
	assert_eq(materials.size(), 2, "both surfaces")
	for material: Material in materials:
		assert_true(material is ShaderMaterial and (material as ShaderMaterial).shader == MODEL_SHADER)
		colors.append((material as ShaderMaterial).get_shader_parameter(&"albedo_color"))
	assert_has(colors, Color.RED, "built from the kit's own material")
	assert_has(colors, Color.BLUE)


func test_a_kit_wall_is_one_multimesh_per_piece_mesh_with_a_gate_per_gap() -> void:
	var loaded: Loaded = _load(THE_FORD)
	var kit: WorldKit = WorldKit.new()
	kit.wall = _house_piece()
	kit.gate = _house_piece()
	var view: StructuresView = _view(loaded, kit)
	var wall: Node = view.get_child(0)
	var multimeshes: Array[MultiMeshInstance3D] = []
	var gates: int = 0
	for child: Node in wall.get_children():
		if child is MultiMeshInstance3D:
			multimeshes.append(child as MultiMeshInstance3D)
		else:
			gates += 1
	assert_eq(multimeshes.size(), 2, "one per mesh in the piece")
	assert_eq(gates, 1, "The Ford's one gate")
	var placed: int = StructurePlacer.wall_transforms(loaded.structures.records[0], kit.wall, loaded.terrain).size()
	for multimesh: MultiMeshInstance3D in multimeshes:
		assert_eq(multimesh.multimesh.instance_count, placed)
	var materials: Array[Material] = _materials(wall)
	assert_eq(materials.size(), 4, "two surfaces each in the sections and the gate")
	for material: Material in materials:
		assert_true(material is ShaderMaterial and (material as ShaderMaterial).shader == MODEL_SHADER)


func test_a_house_glows_while_its_footprint_burns_then_stays_charred() -> void:
	var loaded: Loaded = _load(RIVERSIDE)
	var view: StructuresView = _view(loaded)
	var fire: Fire = Fire.new(loaded.terrain)
	var record: StructureRecord = loaded.structures.records[2]
	view.update_fire(fire, loaded.terrain)
	assert_eq(view.fire_amount(2), Vector2.ZERO, "unburnt: a fire that never burned has no grid")
	fire.state.resize(loaded.terrain.size_x * loaded.terrain.size_z)
	for n: int in record.samples.size() / 2:
		fire.state[record.samples[n]] = Fire.Cell.BURNING
		fire.changed.append(record.samples[n])
	view.update_fire(fire, loaded.terrain)
	assert_almost_eq(view.fire_amount(2).x, 0.5, 0.05, "half its footprint burns")
	assert_eq(view.fire_amount(1), Vector2.ZERO, "its neighbour doesn't")
	var material: ShaderMaterial = _materials(view.get_child(2))[0] as ShaderMaterial
	assert_gt(material.get_shader_parameter(&"burning"), 0.0, "the shader glows")
	fire.changed.clear()
	for k: int in record.samples:
		fire.state[k] = Fire.Cell.SCORCHED
		fire.changed.append(k)
	view.update_fire(fire, loaded.terrain)
	assert_eq(view.fire_amount(2).x, 0.0, "burnt out")
	assert_gt(view.fire_amount(2).y, 0.0, "charred")
	assert_eq(material.get_shader_parameter(&"burning"), 0.0)
	assert_eq(material.get_shader_parameter(&"charred"), 1.0)


# The sim lists every cell it changes in Fire.changed (cleared each step), so
# a tick with no changes and nothing burning can't change any structure's
# share: update_fire skips its scan of every footprint then.
func test_a_quiet_fire_is_not_rescanned() -> void:
	var loaded: Loaded = _load(RIVERSIDE)
	var view: StructuresView = _view(loaded)
	var fire: Fire = Fire.new(loaded.terrain)
	fire.state.resize(loaded.terrain.size_x * loaded.terrain.size_z)
	view.update_fire(fire, loaded.terrain)
	var record: StructureRecord = loaded.structures.records[2]
	for k: int in record.samples:
		fire.state[k] = Fire.Cell.SCORCHED
	view.update_fire(fire, loaded.terrain)
	assert_eq(view.fire_amount(2), Vector2.ZERO, "no change listed and nothing burning: not rescanned")
	fire.changed.append(record.samples[0])
	view.update_fire(fire, loaded.terrain)
	assert_eq(view.fire_amount(2), Vector2(0.0, 1.0), "a listed change rescans")


func test_the_first_fire_update_after_a_build_always_scans() -> void:
	var loaded: Loaded = _load(RIVERSIDE)
	var fire: Fire = Fire.new(loaded.terrain)
	fire.state.resize(loaded.terrain.size_x * loaded.terrain.size_z)
	var record: StructureRecord = loaded.structures.records[2]
	for k: int in record.samples:
		fire.state[k] = Fire.Cell.SCORCHED
	var view: StructuresView = _view(loaded)
	view.update_fire(fire, loaded.terrain)
	assert_eq(view.fire_amount(2), Vector2(0.0, 1.0), "a view built after the fire still shows the char")


func test_the_grade_reaches_every_model_material() -> void:
	var loaded: Loaded = _load(THE_FORD)
	var kit: WorldKit = WorldKit.new()
	kit.houses = [_house_piece()]
	kit.wall = _house_piece()
	kit.gate = _house_piece()
	var view: StructuresView = _view(loaded, kit)
	view.set_grade(Color(0.8, 0.6, 0.5), 0.4)
	var weather: Weather = Weather.new()
	weather.wetness_ppm = 500_000
	weather.snow_cover_ppm = 250_000
	view.set_weather(weather)
	var materials: Array[Material] = _materials(view)
	assert_gt(materials.size(), 5, "a wall and five houses")
	for material: Material in materials:
		var shader_material: ShaderMaterial = material as ShaderMaterial
		assert_eq(shader_material.get_shader_parameter(&"grade_tint"), Color(0.8, 0.6, 0.5))
		assert_eq(shader_material.get_shader_parameter(&"grade_desaturation"), 0.4)
		assert_almost_eq(shader_material.get_shader_parameter(&"wetness"), weather.wetness() / 1000.0, 0.0001)
		assert_almost_eq(shader_material.get_shader_parameter(&"snow_cover"), weather.snow_cover() / 1000.0, 0.0001)
	assert_gt(weather.wetness(), 0, "the weather is not dry")
	view.build(loaded.structures, loaded.terrain, kit)
	for material: Material in _materials(view):
		assert_eq((material as ShaderMaterial).get_shader_parameter(&"grade_desaturation"), 0.4, "a rebuild keeps the grade")


func test_the_model_shader_declares_its_uniforms() -> void:
	var names: Array[String] = []
	for uniform: Dictionary in MODEL_SHADER.get_shader_uniform_list():
		names.append(uniform["name"])
	for wanted: String in [
		"albedo_texture", "albedo_color", "grade_tint", "grade_desaturation",
		"wetness", "snow_cover", "burning", "charred",
	]:
		assert_has(names, wanted, "set_shader_parameter would silently ignore a missing uniform")


func test_the_shared_kit_is_empty_without_its_file() -> void:
	var kit: WorldKit = WorldKit.shared()
	assert_not_null(kit)
	if not ResourceLoader.exists(WorldKit.PATH):
		assert_true(kit.houses.is_empty())
		assert_null(kit.wall)
		assert_null(kit.mill)
