extends GutTest
## MainView shows the world files beside a map: textured ground with the
## structures cut out of it, water, and a model on each structure, all graded
## by the mission's Atmosphere. A map with no world files (the sandbox's test
## terrains) builds with none of it.

var _physics_rate: int = 0


func before_all() -> void:
	_physics_rate = Engine.physics_ticks_per_second


func after_all() -> void:
	Engine.physics_ticks_per_second = _physics_rate
	ViewFixtures.cleanup()


func _mission(id: String) -> MissionLaunch:
	var def: MissionDef = load("res://data/missions/%s/mission.tres" % id) as MissionDef
	var state: CampaignState = CampaignState.new_campaign(1, 2)
	var plan: DeployPlan = state.plan_deploy(def, PackedInt32Array(), PackedStringArray(["Ada"]))
	return MissionLaunch.new(def, 2, 1, plan.command(0, def), true)


func _main(launch: MissionLaunch) -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = launch
	add_child_autofree(main)
	return main


func test_riverside_builds_water_and_eight_houses() -> void:
	var main: MainView = _main(_mission("riverside"))
	var structures: StructuresView = main.get("_structures_view") as StructuresView
	var water: WaterView = main.get("_water_view") as WaterView
	assert_not_null(structures)
	assert_not_null(water)
	assert_eq(structures.get_child_count(), 8, "eight houses")
	assert_gt(water.cell_count(), 0, "the creek is drawn")
	main._physics_process(1.0 / World.TICK_RATE)
	assert_not_null(main.world)


func test_a_map_without_world_files_still_builds() -> void:
	var main: MainView = _main(ViewFixtures.launch())
	var structures: StructuresView = main.get("_structures_view") as StructuresView
	var water: WaterView = main.get("_water_view") as WaterView
	assert_eq(structures.get_child_count(), 0, "no models")
	assert_eq(water.cell_count(), 0, "no water")
	main._physics_process(1.0 / World.TICK_RATE)
	assert_not_null(main.world)


func test_old_mills_grade_reaches_the_mill_and_the_water() -> void:
	var launch: MissionLaunch = _mission("old_mill")
	var look: Atmosphere = launch.mission.atmosphere
	var main: MainView = _main(launch)
	var structures: StructuresView = main.get("_structures_view") as StructuresView
	var water: WaterView = main.get("_water_view") as WaterView
	assert_gt(structures.get_child_count(), 0)
	assert_gt(water.cell_count(), 0)
	assert_eq(water.shader_parameter(&"water_grade"), look.water_tint)
	var checked: int = 0
	var stack: Array[Node] = [structures]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var geometry: GeometryInstance3D = node as GeometryInstance3D
		if geometry == null:
			continue
		var material: ShaderMaterial = geometry.material_override as ShaderMaterial
		if material == null and geometry is MeshInstance3D:
			material = (geometry as MeshInstance3D).get_active_material(0) as ShaderMaterial
		if material == null:
			continue
		assert_eq(material.get_shader_parameter(&"grade_tint"), look.terrain_tint)
		assert_eq(material.get_shader_parameter(&"grade_desaturation"), look.terrain_desaturation)
		checked += 1
	assert_gt(checked, 0, "at least one graded model material")
