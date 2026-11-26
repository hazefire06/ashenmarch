extends SceneTree
## Writes the ground scatter's set (data/world/scatter.tres) from the imported
## Stylized Nature MegaKit models in assets/world/models/nature/: one
## ScatterModel per glTF there, with its native bounds and the offset that
## puts the middle of its base on the origin. Run after `make world-assets`:
##
##     godot --headless --path . -s scripts/art/build_scatter_set.gd
##
## The placer (view/scatter/scatter_placer.gd) names every model it uses; the
## set's test checks each is here.

const FOLDER: String = "res://assets/world/models/nature/"


func _initialize() -> void:
	var files: PackedStringArray = DirAccess.get_files_at(FOLDER)
	var set: ScatterSet = ScatterSet.new()
	var names: PackedStringArray = PackedStringArray()
	for file: String in files:
		if file.get_extension() == "gltf":
			names.append(file)
	names.sort()
	for file: String in names:
		var path: String = FOLDER + file
		var scene: PackedScene = load(path) as PackedScene
		if scene == null:
			push_error("build_scatter_set: %s is not imported; run make world-assets" % path)
			quit(1)
			return
		var root: Node3D = scene.instantiate() as Node3D
		var bounds: AABB = _bounds(root, root)
		root.free()
		var model: ScatterModel = ScatterModel.new()
		model.name = StringName(file.get_basename().to_lower())
		model.scene = scene
		model.size_m = Vector3(snappedf(bounds.size.x, 0.001), snappedf(bounds.size.y, 0.001), snappedf(bounds.size.z, 0.001))
		model.offset = -Vector3(
			snappedf(bounds.get_center().x, 0.001), snappedf(bounds.position.y, 0.001), snappedf(bounds.get_center().z, 0.001)
		)
		set.models.append(model)
		print("%s: size_m %s" % [model.name, model.size_m])
	if set.models.is_empty():
		push_error("build_scatter_set: no models in %s; run make world-assets" % FOLDER)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ScatterSet.PATH.get_base_dir()))
	if ResourceSaver.save(set, ScatterSet.PATH) != OK:
		push_error("build_scatter_set: saving %s failed" % ScatterSet.PATH)
		quit(1)
		return
	print("build_scatter_set: wrote %s (%d models)" % [ScatterSet.PATH, set.models.size()])
	quit(0)


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
