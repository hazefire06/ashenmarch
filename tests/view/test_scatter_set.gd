extends GutTest
## The shipped scatter set (data/world/scatter.tres): every model the placer
## names is there, imported, with a mesh and sensible bounds.


func test_the_set_has_every_model_the_placer_uses() -> void:
	var set: ScatterSet = ScatterSet.shared()
	assert_eq(set.models.size(), ScatterPlacer.KINDS.size(), "one model per name the placer knows")
	for name: StringName in ScatterPlacer.KINDS:
		var model: ScatterModel = set.find(name)
		assert_not_null(model, "%s is in the set" % name)
		if model == null:
			continue
		assert_not_null(model.scene, "%s has its scene" % name)
		assert_gt(model.size_m.y, 0.05, "%s has a height" % name)
		var root: Node = model.scene.instantiate()
		assert_gt(root.find_children("*", "MeshInstance3D", true, false).size() + int(root is MeshInstance3D), 0, "%s has a mesh" % name)
		root.free()


func test_every_palette_entry_names_a_known_model() -> void:
	for palette: Array in ScatterPlacer.PALETTES:
		for entry: Array in palette:
			assert_true(ScatterPlacer.KINDS.has(entry[0]), "%s has a kind" % entry[0])


func test_native_sizes_cover_the_set() -> void:
	var sizes: Dictionary[StringName, Vector3] = ScatterSet.shared().native_sizes()
	assert_eq(sizes.size(), ScatterPlacer.KINDS.size())
	assert_almost_eq(sizes[&"pebble_round_1"].y, 0.095, 0.01)
	assert_almost_eq(sizes[&"bush_common_flowers"].x, 1.915, 0.01)
