extends SceneTree
## Wraps each imported world-kit model in a scene whose origin is the middle of
## its base, as KitPiece and StructurePlacer assume, and writes the kit
## (data/world/kit.tres) with each piece's native bounds and door axis. Run
## after `make world-assets` and an import:
##
##     godot --headless --path . --import
##     godot --headless --path . -s scripts/art/build_world_kit.gd
##
## The models are assembled by scripts/art/assemble_world_kit.py, which puts
## every door on +z or +x (read from its recipes and checked on renders).

const MODELS: String = "res://assets/world/models/"
const KIT_DIR: String = "res://data/world/"
## The house pieces and the axis each one's door faces, x and z.
const HOUSES: Dictionary[String, Vector2i] = {
	"house_square": Vector2i(0, 1),
	"house_long_side": Vector2i(1, 0),
	"house_long_front": Vector2i(0, 1),
	"house_narrow_side": Vector2i(1, 0),
	"house_narrow_front": Vector2i(0, 1),
}


func _initialize() -> void:
	var kit: WorldKit = WorldKit.new()
	var failed: bool = false
	for name: String in HOUSES:
		var piece: KitPiece = _wrap(name, HOUSES[name])
		failed = failed or piece == null
		kit.houses.append(piece)
	kit.wall = _wrap("wall", Vector2i(0, 1))
	kit.gate = _wrap("gate", Vector2i(0, 1))
	kit.mill = _wrap("mill", Vector2i(0, 1))
	failed = failed or kit.wall == null or kit.gate == null or kit.mill == null
	if failed:
		push_error("build_world_kit: a model is missing; run make world-assets and godot --headless --path . --import first")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(KIT_DIR))
	var err: Error = ResourceSaver.save(kit, WorldKit.PATH)
	if err != OK:
		push_error("build_world_kit: saving %s failed (%d)" % [WorldKit.PATH, err])
		quit(1)
		return
	print("build_world_kit: wrote %s" % WorldKit.PATH)
	quit(0)


## Writes MODELS/<name>.tscn, the imported model under a root moved so its
## bounds' base centre is the origin, and returns its piece. Null if the
## model isn't imported.
func _wrap(name: String, door: Vector2i) -> KitPiece:
	var source_path: String = "%s%s/%s.gltf" % [MODELS, name, name]
	if not ResourceLoader.exists(source_path):
		push_error("build_world_kit: %s is not imported" % source_path)
		return null
	var source: PackedScene = load(source_path) as PackedScene
	var model: Node3D = source.instantiate() as Node3D
	var bounds: AABB = _bounds(model, model)
	var root: Node3D = Node3D.new()
	root.name = name.to_pascal_case()
	root.add_child(model)
	model.owner = root
	model.position = -Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	var packed: PackedScene = PackedScene.new()
	packed.pack(root)
	root.free()
	var path: String = "%s%s.tscn" % [MODELS, name]
	if ResourceSaver.save(packed, path) != OK:
		push_error("build_world_kit: saving %s failed" % path)
		return null
	var piece: KitPiece = KitPiece.new()
	piece.scene = load(path) as PackedScene
	piece.size_m = Vector3(snappedf(bounds.size.x, 0.001), snappedf(bounds.size.y, 0.001), snappedf(bounds.size.z, 0.001))
	piece.door = door
	print("%s: size_m %s, door %s" % [name, piece.size_m, door])
	return piece


## The combined bounds of every mesh under node, in root's space.
func _bounds(node: Node, root: Node3D) -> AABB:
	var total: AABB = AABB()
	var first: bool = true
	for found: Node in [node] + node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = found as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box: AABB = _transform_in(mesh_instance, root) * mesh_instance.mesh.get_aabb()
		total = box if first else total.merge(box)
		first = false
	return total


static func _transform_in(node: Node3D, root: Node3D) -> Transform3D:
	var t: Transform3D = Transform3D.IDENTITY
	var at: Node3D = node
	while at != root:
		t = at.transform * t
		at = at.get_parent() as Node3D
	return t
