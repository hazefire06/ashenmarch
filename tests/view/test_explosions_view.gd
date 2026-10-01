extends GutTest
## ExplosionsView: what blasts, fizzles, and fire arrows leave behind. A blast
## that digs a crater re-meshes the terrain and refreshes the gibs' ground
## where the sim scarred it, then lays a dark disc on the new ground; a blast
## in the air only flashes; a fizzle puffs; a fire lit leaves an orange
## scorch. Worlds are real, and the events come from the sim.

const M: int = 1000

var _catalog: UnitCatalog
var _world: World
var _terrain_view: TerrainView
var _gibs: Gibs
var _view: ExplosionsView


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(80, 80), _catalog)
	_make_views()


func _make_views() -> void:
	_terrain_view = TerrainView.new()
	add_child_autofree(_terrain_view)
	# From the World's own terrain, which is the one that gets scarred.
	_terrain_view.build(_world.terrain)
	_gibs = Gibs.new()
	add_child_autofree(_gibs)
	_gibs.setup(_world.terrain)
	_view = ExplosionsView.new()
	add_child_autofree(_view)
	_view.setup(_world, _terrain_view, _gibs)


# A satchel at rest on the ground at (x, z) meters, set off now.
func _satchel_at(x: int, z: int) -> Projectile:
	var index: int = _catalog.projectile_index_of(&"satchel")
	var radius: int = _catalog.projectile_types[index].radius
	var p: Projectile = _world.spawn_projectile(
		index, FlightState.at_mm(x * M, _world.terrain.height_at(x * M, z * M) + radius, z * M, 0, 0, 0), 0
	)
	p.motion = Projectile.Motion.RESTING
	return p


func _step() -> void:
	_world.step()
	_view.after_step()


func _marks() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child: Node in _view.get_node("Marks").get_children():
		out.append(child as MeshInstance3D)
	return out


func _center_y(mark: MeshInstance3D) -> float:
	var vertices: PackedVector3Array = mark.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	return vertices[0].y


func _ground_heights() -> PackedFloat32Array:
	var collider: CollisionShape3D = _gibs.get_node("Ground").get_child(0) as CollisionShape3D
	return (collider.shape as HeightMapShape3D).map_data


func _events(kind: ProjectileEvent.Kind) -> Array[ProjectileEvent]:
	var out: Array[ProjectileEvent] = []
	for e: ProjectileEvent in _world.projectile_events:
		if e.kind == kind:
			out.append(e)
	return out


func test_a_crater_remeshes_the_terrain_and_the_gibs_ground_and_lays_a_disc() -> void:
	var before: Mesh = (_terrain_view.get_node("Chunk_0_0") as MeshInstance3D).mesh
	var p: Projectile = _satchel_at(30, 30)
	_world.explosions.detonate(_world, p)
	_step()
	var explosions: Array[ProjectileEvent] = _events(ProjectileEvent.Kind.EXPLODE)
	assert_eq(explosions.size(), 1)
	assert_gt(explosions[0].crater, 0, "the satchel dug a crater")
	assert_true(explosions[0].cells.has_area())
	var scarred: int = _world.terrain.height_at(30 * M, 30 * M)
	assert_lt(scarred, 0, "the World's terrain has the bowl")
	assert_ne((_terrain_view.get_node("Chunk_0_0") as MeshInstance3D).mesh, before, "the chunk was re-meshed")
	assert_almost_eq(_ground_heights()[30 * 80 + 30], scarred / 1000.0, 0.0001, "the gibs' ground too")
	assert_eq(_view.mark_count(), 1)
	var mark: MeshInstance3D = _marks()[0]
	assert_almost_eq(_center_y(mark), scarred / 1000.0 + ExplosionsView.CRATER_LIFT, 0.0001, "the disc sits in the bowl")
	var material: StandardMaterial3D = mark.material_override as StandardMaterial3D
	assert_eq(material.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_true(material.vertex_color_use_as_albedo, "the rim fades by vertex alpha")
	assert_ne(material.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_lt(material.albedo_color.get_luminance(), 0.2, "dark earth")


func test_the_disc_covers_the_crater_and_a_little_more() -> void:
	var p: Projectile = _satchel_at(30, 30)
	_world.explosions.detonate(_world, p)
	_step()
	var vertices: PackedVector3Array = _marks()[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var farthest: float = 0.0
	for v: Vector3 in vertices:
		farthest = maxf(farthest, Vector2(v.x - 30.0, v.z - 30.0).length())
	var crater: float = _catalog.find_projectile(&"satchel").crater_radius / float(M)
	assert_almost_eq(farthest, crater * ExplosionsView.CRATER_DISC_SCALE, 0.01)


func test_a_blast_flashes_and_the_flash_frees_itself() -> void:
	var p: Projectile = _satchel_at(30, 30)
	_world.explosions.detonate(_world, p)
	_step()
	assert_eq(_view.effect_count(), 1)
	var flash: MeshInstance3D = _view.get_node("Effects").get_child(0) as MeshInstance3D
	var blast: float = _catalog.find_projectile(&"satchel").blast_radius / float(M)
	var start_diameter: float = blast * ExplosionsView.FLASH_RADIUS_SHARE * ExplosionsView.FLASH_START_SHARE * 2.0
	assert_almost_eq(flash.scale.x, start_diameter, 0.001, "starts small")
	var material: StandardMaterial3D = flash.material_override as StandardMaterial3D
	assert_eq(material.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	assert_ne(material.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_almost_eq(flash.position.x, 30.0, 0.05, "at the burst")
	var gone: bool = await wait_until(func() -> bool: return _view.effect_count() == 0, ExplosionsView.FLASH_TIME + 2.0)
	assert_true(gone, "freed after its time")
	assert_eq(_view.mark_count(), 1, "the crater stays")


func test_the_flash_grows_and_fades_while_it_lives() -> void:
	var p: Projectile = _satchel_at(30, 30)
	_world.explosions.detonate(_world, p)
	_step()
	var flash: MeshInstance3D = _view.get_node("Effects").get_child(0) as MeshInstance3D
	var material: StandardMaterial3D = flash.material_override as StandardMaterial3D
	var start_scale: float = flash.scale.x
	var start_alpha: float = material.albedo_color.a
	await wait_seconds(ExplosionsView.FLASH_TIME * 0.5)
	assert_gt(flash.scale.x, start_scale, "bigger")
	assert_lt(material.albedo_color.a, start_alpha, "fainter")
	var blast: float = _catalog.find_projectile(&"satchel").blast_radius / float(M)
	assert_lt(flash.scale.x, blast * ExplosionsView.FLASH_RADIUS_SHARE * 2.0, "not yet at its full size")


func test_a_blast_in_the_air_only_flashes() -> void:
	var before: Mesh = (_terrain_view.get_node("Chunk_0_0") as MeshInstance3D).mesh
	var index: int = _catalog.projectile_index_of(&"grenade")
	var grenade: Projectile = _world.spawn_projectile(index, FlightState.at_mm(30 * M, 12 * M, 30 * M, 0, 0, 0), 0)
	_world.explosions.detonate(_world, grenade)
	_step()
	var explosions: Array[ProjectileEvent] = _events(ProjectileEvent.Kind.EXPLODE)
	assert_eq(explosions.size(), 1)
	assert_eq(explosions[0].crater, 0, "too high to dig")
	assert_eq(_view.effect_count(), 1)
	assert_eq(_view.mark_count(), 0)
	assert_eq((_terrain_view.get_node("Chunk_0_0") as MeshInstance3D).mesh, before, "terrain untouched")


func test_a_fizzle_leaves_a_grey_puff_that_clears() -> void:
	var dud_grenade: ProjectileType = TestUnits.projectile(&"grenade", {"fizzle_permille": 1000})
	var types: Array[UnitType] = []
	var projectiles: Array[ProjectileType] = [dud_grenade]
	_world = World.new(1, TestTerrains.flat(80, 80), TestUnits.catalog(types, projectiles))
	_make_views()
	var grenade: Projectile = _world.spawn_projectile(0, FlightState.at_mm(30 * M, 60, 30 * M, 0, 0, 0), 0)
	grenade.motion = Projectile.Motion.RESTING
	grenade.fuse_left = 1
	_step()
	assert_eq(_events(ProjectileEvent.Kind.FIZZLE).size(), 1)
	assert_true(grenade.dud)
	assert_eq(_view.effect_count(), 1)
	assert_eq(_view.mark_count(), 0, "a puff, not a crater")
	var puff: MeshInstance3D = _view.get_node("Effects").get_child(0) as MeshInstance3D
	var color: Color = (puff.material_override as StandardMaterial3D).albedo_color
	assert_almost_eq(color.r, color.g, 0.05, "grey")
	assert_almost_eq(color.g, color.b, 0.05, "grey")
	var gone: bool = await wait_until(func() -> bool: return _view.effect_count() == 0, ExplosionsView.PUFF_TIME + 2.0)
	assert_true(gone)


func test_a_fire_mark_leaves_a_small_orange_scorch() -> void:
	_world.ignite(40 * M, 25 * M, 0)
	_view.after_step()
	assert_eq(_view.mark_count(), 1)
	assert_eq(_view.effect_count(), 0, "no flash for a fire arrow")
	var mark: MeshInstance3D = _marks()[0]
	var color: Color = (mark.material_override as StandardMaterial3D).albedo_color
	assert_gt(color.r, color.b + 0.4, "orange-red")
	var vertices: PackedVector3Array = mark.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var farthest: float = 0.0
	for v: Vector3 in vertices:
		farthest = maxf(farthest, Vector2(v.x - 40.0, v.z - 25.0).length())
	assert_almost_eq(farthest, ExplosionsView.SCORCH_RADIUS / float(M), 0.01, "small")
	assert_almost_eq(_center_y(mark), ExplosionsView.SCORCH_LIFT, 0.0001)


func test_a_later_crater_brings_an_earlier_disc_down_onto_the_new_ground() -> void:
	# Two satchels 1.5 m apart: the first blast catches the second, which goes
	# off a few ticks later and digs under the first crater.
	var first: Projectile = _satchel_at(30, 30)
	_satchel_at(31, 30)
	_world.explosions.detonate(_world, first)
	_step()
	assert_eq(_view.mark_count(), 1)
	var mark: MeshInstance3D = _marks()[0]
	var first_y: float = _center_y(mark)
	for tick: int in 2 * Explosions.CHAIN_DELAY_TICKS:
		_step()
	assert_eq(_view.mark_count(), 2, "the second crater")
	var disc: Vector3i = mark.get_meta(&"disc")
	var expected: float = _world.terrain.height_at(disc.x, disc.y) / 1000.0 + ExplosionsView.CRATER_LIFT
	assert_almost_eq(_center_y(mark), expected, 0.0001, "the first disc follows the ground as it is now")
	assert_lt(_center_y(mark), first_y - 0.05, "which is lower than when it was laid")


func test_without_views_to_refresh_a_crater_still_lays_its_disc() -> void:
	var bare: ExplosionsView = ExplosionsView.new()
	add_child_autofree(bare)
	bare.setup(_world, null, null)
	var p: Projectile = _satchel_at(30, 30)
	_world.explosions.detonate(_world, p)
	_world.step()
	bare.after_step()
	assert_eq(bare.mark_count(), 1)
