extends GutTest
## ProjectilesView: one node per live projectile, looking like its type (a
## thin box along the flight for an arrow, a sphere with a blinking spark for
## a grenade, a labeled box for a charge), interpolated between tick
## positions, and a ring buffer of arrows stuck in the ground. Worlds are
## real: projectiles are spawned into a World with the shipped catalog, and
## stuck arrows come from the events the sim really reports.

const M: int = 1000

var _catalog: UnitCatalog
var _world: World
var _view: ProjectilesView


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(60, 60), _catalog)
	_view = ProjectilesView.new()
	add_child_autofree(_view)
	_view.setup(_world)


# Spawns a projectile of this type id at rest at (x, z) meters, on the ground.
func _spawn_at_rest(type_id: StringName, x: int, z: int) -> Projectile:
	var index: int = _catalog.projectile_index_of(type_id)
	var radius: int = _catalog.projectile_types[index].radius
	var p: Projectile = _world.spawn_projectile(
		index, FlightState.at_mm(x * M, radius, z * M, 0, 0, 0), 0
	)
	p.motion = Projectile.Motion.RESTING
	return p


# Spawns an arrow 4 m up and sends it toward +x and down, with um/tick
# velocity (vx, vy, 0).
func _shoot_arrow(type_id: StringName, vx: int, vy: int, start_x: int = 20) -> Projectile:
	var index: int = _catalog.projectile_index_of(type_id)
	return _world.spawn_projectile(index, FlightState.at_mm(start_x * M, 4 * M, 20 * M, vx, vy, 0), 0)


func _body_of(node: Node3D) -> MeshInstance3D:
	return node.get_node("Body") as MeshInstance3D


func _spark_of(node: Node3D) -> MeshInstance3D:
	return node.get_node_or_null("Spark") as MeshInstance3D


# --- pure helpers ---


func test_spark_blinks_while_the_fuse_burns() -> void:
	assert_false(ProjectilesView.spark_lit(0, false), "no fuse, no spark")
	assert_false(ProjectilesView.spark_lit(60, true), "a dud never sparks")
	var lit: int = 0
	var dark: int = 0
	for fuse: int in range(105, 30, -1):
		if ProjectilesView.spark_lit(fuse, false):
			lit += 1
		else:
			dark += 1
	assert_gt(lit, 20, "on for part of the time")
	assert_gt(dark, 20, "and off for part")
	assert_eq(ProjectilesView.spark_lit(101, false), ProjectilesView.spark_lit(96, false), "slowly: 6-tick phases")
	assert_ne(ProjectilesView.spark_lit(96, false), ProjectilesView.spark_lit(95, false))
	assert_ne(ProjectilesView.spark_lit(30, false), ProjectilesView.spark_lit(27, false), "3-tick phases for the last second")


func test_aim_basis_points_minus_z_along_the_direction() -> void:
	for direction: Vector3 in [
		Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(3.0, -4.0, 5.0), Vector3(-0.2, 1.0, 0.1)
	]:
		var basis: Basis = ProjectilesView.aim_basis(direction)
		assert_almost_eq((-basis.z).dot(direction.normalized()), 1.0, 0.0001, "%s" % direction)
		assert_true(basis.is_orthonormal(), "no skew for %s" % direction)


func test_aim_basis_survives_straight_up_and_down_and_zero() -> void:
	for direction: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3(0.0, -5.0, 0.0)]:
		var basis: Basis = ProjectilesView.aim_basis(direction)
		assert_true(basis.is_finite(), "%s" % direction)
		assert_almost_eq((-basis.z).dot(direction.normalized()), 1.0, 0.0001)
	assert_eq(ProjectilesView.aim_basis(Vector3.ZERO), Basis.IDENTITY)


# --- live projectiles ---


func test_an_arrow_is_a_thin_box_with_its_tip_at_the_position_along_its_flight() -> void:
	var arrow: Projectile = _shoot_arrow(&"arrow", 300_000, -200_000)
	_view.after_step()
	var node: Node3D = _view.node_of(arrow.id)
	assert_not_null(node)
	assert_eq(_view.projectile_count(), 1)
	var body: MeshInstance3D = _body_of(node)
	var box: BoxMesh = body.mesh as BoxMesh
	assert_not_null(box)
	var length: float = _catalog.find_projectile(&"arrow").length / float(M)
	assert_eq(box.size, Vector3(0.03, 0.03, length))
	assert_almost_eq(body.position.z, length * 0.5, 0.0001, "tip at the node's origin, tail behind")
	var velocity: Vector3 = Vector3(arrow.flight.vx, arrow.flight.vy, arrow.flight.vz).normalized()
	assert_almost_eq((-node.basis.z).dot(velocity), 1.0, 0.0001, "points along the flight")
	var material: StandardMaterial3D = body.material_override as StandardMaterial3D
	assert_eq(material.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_eq(material.albedo_color, _catalog.find_projectile(&"arrow").placeholder_color)


func test_a_flying_arrow_turns_as_it_falls() -> void:
	var arrow: Projectile = _shoot_arrow(&"arrow", 600_000, 300_000)
	_view.after_step()
	var node: Node3D = _view.node_of(arrow.id)
	var rising: float = (-node.basis.z).y
	for tick: int in 12:
		_world.step()
		_view.after_step()
	assert_lt((-node.basis.z).y, rising - 0.05, "nose drops over the arc")


func test_a_fire_arrow_takes_its_own_color() -> void:
	var arrow: Projectile = _shoot_arrow(&"fire_arrow", 300_000, 0)
	_view.after_step()
	var material: StandardMaterial3D = _body_of(_view.node_of(arrow.id)).material_override as StandardMaterial3D
	assert_eq(material.albedo_color, _catalog.find_projectile(&"fire_arrow").placeholder_color)
	assert_ne(material.albedo_color, _catalog.find_projectile(&"arrow").placeholder_color)


func test_a_grenade_is_a_sphere_with_a_spark_that_blinks() -> void:
	var grenade: Projectile = _spawn_at_rest(&"grenade", 30, 30)
	grenade.fuse_left = 96
	_view.after_step()
	var node: Node3D = _view.node_of(grenade.id)
	var body: MeshInstance3D = _body_of(node)
	var ball: SphereMesh = body.mesh as SphereMesh
	assert_not_null(ball)
	assert_gte(ball.radius, _catalog.find_projectile(&"grenade").radius / float(M), "at least its radius")
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, _catalog.find_projectile(&"grenade").placeholder_color)
	var spark: MeshInstance3D = _spark_of(node)
	assert_not_null(spark)
	assert_eq((spark.material_override as StandardMaterial3D).shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	var seen: Dictionary[bool, bool] = {}
	for fuse: int in range(96, 60, -1):
		grenade.fuse_left = fuse
		_view.after_step()
		assert_eq(spark.visible, ProjectilesView.spark_lit(fuse, false))
		seen[spark.visible] = true
	assert_eq(seen.size(), 2, "lit and dark both happened")


func test_a_dud_is_darker_and_does_not_spark() -> void:
	var grenade: Projectile = _spawn_at_rest(&"grenade", 30, 30)
	grenade.fuse_left = 96
	_view.after_step()
	var node: Node3D = _view.node_of(grenade.id)
	var live_color: Color = (_body_of(node).material_override as StandardMaterial3D).albedo_color
	grenade.dud = true
	grenade.fuse_left = 0
	_view.after_step()
	var dud_color: Color = (_body_of(node).material_override as StandardMaterial3D).albedo_color
	assert_lt(dud_color.get_luminance(), live_color.get_luminance(), "darker")
	assert_false(_spark_of(node).visible)


func test_a_satchel_is_a_box_with_a_charge_label() -> void:
	var satchel: Projectile = _spawn_at_rest(&"satchel", 30, 30)
	_view.after_step()
	var node: Node3D = _view.node_of(satchel.id)
	var body: MeshInstance3D = _body_of(node)
	assert_true(body.mesh is BoxMesh)
	var radius: float = _catalog.find_projectile(&"satchel").radius / float(M)
	assert_eq((body.mesh as BoxMesh).size, Vector3.ONE * radius * 2.0)
	assert_eq((body.material_override as StandardMaterial3D).albedo_color, _catalog.find_projectile(&"satchel").placeholder_color)
	var label: Label3D = node.get_node("Label") as Label3D
	assert_not_null(label)
	assert_eq(label.text, "Charge")
	assert_eq(label.billboard, BaseMaterial3D.BILLBOARD_ENABLED)
	assert_eq(label.visibility_range_end, ProjectilesView.LABEL_RANGE, "hidden far away, like unit names")
	assert_null(_spark_of(node), "no fuse, no spark")


func test_nodes_follow_the_projectiles_and_go_when_they_do() -> void:
	var a: Projectile = _spawn_at_rest(&"satchel", 30, 30)
	var b: Projectile = _spawn_at_rest(&"satchel", 32, 30)
	_view.after_step()
	assert_eq(_view.projectile_count(), 2)
	_world.despawn_entity(a.id)
	_view.after_step()
	assert_eq(_view.projectile_count(), 1)
	assert_null(_view.node_of(a.id))
	assert_not_null(_view.node_of(b.id))
	_world.despawn_entity(b.id)
	_view.after_step()
	assert_eq(_view.projectile_count(), 0)


func test_a_new_projectile_starts_where_it_is_and_then_trails_the_sim_by_a_tick() -> void:
	# Drawn between its last two tick positions by the physics interpolation
	# fraction, like UnitsView.
	var index: int = _catalog.projectile_index_of(&"grenade")
	var p: Projectile = _world.spawn_projectile(index, FlightState.at_mm(20 * M, 5 * M, 20 * M, 200_000, 0, 0), 0)
	var spawn: Vector3 = Vector3(p.x, p.y, p.z) / float(M)
	_view.after_step()
	_view._process(0.0)
	assert_eq(_view.node_of(p.id).position, spawn, "no lurch from the origin on the first frame")
	_world.step()
	_view.after_step()
	var first: Vector3 = Vector3(p.x, p.y, p.z) / float(M)
	assert_gt(first.x, spawn.x, "it moved")
	var alpha: float = Engine.get_physics_interpolation_fraction()
	_view._process(0.0)
	assert_almost_eq(_view.node_of(p.id).position, spawn.lerp(first, alpha), Vector3.ONE * 0.0001)
	_world.step()
	_view.after_step()
	var second: Vector3 = Vector3(p.x, p.y, p.z) / float(M)
	alpha = Engine.get_physics_interpolation_fraction()
	_view._process(0.0)
	assert_almost_eq(_view.node_of(p.id).position, first.lerp(second, alpha), Vector3.ONE * 0.0001)


# --- stuck arrows ---


func _fly_until_stuck() -> void:
	for tick: int in 200:
		_world.step()
		_view.after_step()
		if _view.stuck_arrow_count() > 0 or _world.projectiles.is_empty():
			return


func test_an_arrow_that_lands_sticks_in_the_ground_and_the_sim_forgets_it() -> void:
	_shoot_arrow(&"arrow", 300_000, -100_000)
	_fly_until_stuck()
	assert_eq(_view.stuck_arrow_count(), 1)
	assert_eq(_world.projectiles.size(), 0, "the sim dropped it")
	assert_eq(_view.projectile_count(), 0, "and so did the flying nodes")


func test_a_stuck_arrow_stands_along_its_flight_with_a_quarter_buried() -> void:
	var tip: Vector3 = Vector3(10.0, 2.0, 5.0)
	var direction: Vector3 = Vector3(3.0, -1.0, 2.0)
	var length: float = 0.8
	var transform: Transform3D = ProjectilesView.stuck_transform(tip, direction, length)
	var forward: Vector3 = direction.normalized()
	assert_almost_eq((-transform.basis.z.normalized()).dot(forward), 1.0, 0.0001, "along the flight")
	assert_almost_eq(transform.basis.z.length(), length, 0.0001, "a one-meter box scaled to the arrow's length")
	assert_almost_eq(transform.basis.x.length(), 1.0, 0.0001, "and not thickened")
	# The box is centered, so its ends are half a length either side of the origin.
	var far_end: Vector3 = transform.origin + forward * length * 0.5
	var near_end: Vector3 = transform.origin - forward * length * 0.5
	assert_almost_eq(far_end.distance_to(tip), length * ProjectilesView.STUCK_SINK, 0.0001, "the tip is sunk a quarter")
	assert_almost_eq(far_end.dot(forward), tip.dot(forward) + length * 0.25, 0.0001, "further along the flight")
	assert_almost_eq(near_end.distance_to(tip), length * 0.75, 0.0001, "three quarters stand out")


func test_stuck_transform_handles_straight_down_and_zero() -> void:
	for direction: Vector3 in [Vector3.DOWN, Vector3(0.0, -3.0, 0.0), Vector3.ZERO]:
		var transform: Transform3D = ProjectilesView.stuck_transform(Vector3(1.0, 2.0, 3.0), direction, 0.8)
		assert_true(transform.origin.is_finite(), "%s" % direction)
		assert_true(transform.basis.is_finite())
		assert_lt((-transform.basis.z.normalized()).y, -0.99, "points down")
		# Buried tip 0.2 m below the ground point, box centered 0.4 m above it.
		assert_almost_eq(transform.origin.y, 2.0 - 0.2 + 0.4, 0.0001, "%s" % direction)


func test_the_world_reports_where_the_arrow_stuck() -> void:
	# The view draws what the event says, so the event must say what the
	# view assumes: the flight direction, and a point on the ground.
	_shoot_arrow(&"arrow", 300_000, -100_000)
	var event: ProjectileEvent = null
	for tick: int in 200:
		_world.step()
		_view.after_step()
		for e: ProjectileEvent in _world.projectile_events:
			if e.kind == ProjectileEvent.Kind.STICK:
				event = e
		if event != null:
			break
	assert_not_null(event, "it stuck")
	assert_gt(event.dir_x, 0)
	assert_lt(event.dir_y, 0)
	assert_almost_eq(float(event.y), float(_world.terrain.height_at(event.x, event.z)), 200.0, "on the ground")


func test_an_arrow_landing_in_water_is_not_kept() -> void:
	var rows: Array[String] = []
	for j: int in 60:
		rows.append("1".repeat(60))
	_world = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	_view.setup(_world)
	_shoot_arrow(&"arrow", 300_000, -100_000)
	var stuck_in_water: bool = false
	for tick: int in 200:
		_world.step()
		_view.after_step()
		for e: ProjectileEvent in _world.projectile_events:
			if e.kind == ProjectileEvent.Kind.STICK:
				stuck_in_water = e.depth > 0
		if _world.projectiles.is_empty():
			break
	assert_true(stuck_in_water, "the sim reported the water depth")
	assert_eq(_view.stuck_arrow_count(), 0)


func test_stuck_arrows_are_a_ring_buffer_that_reuses_the_oldest() -> void:
	var index: int = _catalog.projectile_index_of(&"arrow")
	var stuck: MultiMesh = (_view.get_node("StuckArrows") as MultiMeshInstance3D).multimesh
	assert_eq(stuck.instance_count, ProjectilesView.STUCK_ARROW_LIMIT)
	assert_eq(ProjectilesView.STUCK_ARROW_LIMIT, 1500)
	for n: int in ProjectilesView.STUCK_ARROW_LIMIT + 100:
		var event: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.STICK, n * 10, 0, 5 * M)
		event.type_index = index
		event.dir_x = 1
		event.dir_y = -1
		_view._add_stuck_arrow(event)
		if n == ProjectilesView.STUCK_ARROW_LIMIT - 1:
			assert_eq(_view.stuck_arrow_count(), ProjectilesView.STUCK_ARROW_LIMIT, "full")
	assert_eq(_view.stuck_arrow_count(), ProjectilesView.STUCK_ARROW_LIMIT, "never more")
	assert_eq(stuck.visible_instance_count, ProjectilesView.STUCK_ARROW_LIMIT)
	# The 100 newest replaced slots 0..99, oldest first, so the next to go is
	# slot 100. (The slots can't be read back from a headless MultiMesh, so
	# this looks at the cursor.)
	assert_eq(_view._stuck_next, 100)
