extends GutTest
## The shipped kit (data/world/kit.tres) on the committed maps: the walls of
## every house and of the mill, not just their roofs, stand within half a metre
## of the footprint's edge, so units stop against a wall rather than short of
## it under the eaves (the A5 spec's first anti-goal).

const MAPS: Array[String] = [
	"res://maps/riverside/riverside.tres",
	"res://maps/the_ford/the_ford.tres",
	"res://maps/old_mill/old_mill.tres",
]
const FIT_M: float = 0.5
## The materials a kit building's walls are made of (the roof is MI_RoundTiles
## and the timber, MI_WoodTrim, is shared by walls and roof).
const WALL_MATERIALS: Array[String] = ["MI_Plaster", "MI_UnevenBrick", "MI_Brick"]


## The bounds of piece's wall surfaces in its scene's space, or an empty AABB
## if it has none.
static func _wall_bounds(piece: KitPiece) -> AABB:
	var root: Node3D = piece.scene.instantiate() as Node3D
	var total: AABB = AABB()
	var first: bool = true
	for found: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = found as MeshInstance3D
		var to_root: Transform3D = Transform3D.IDENTITY
		var at: Node3D = mesh_instance
		while at != root:
			to_root = at.transform * to_root
			at = at.get_parent() as Node3D
		for i: int in mesh_instance.mesh.get_surface_count():
			var material: Material = mesh_instance.get_active_material(i)
			if material == null or not WALL_MATERIALS.has(material.resource_name):
				continue
			var vertices: PackedVector3Array = mesh_instance.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
			for v: Vector3 in vertices:
				var p: Vector3 = to_root * v
				if first:
					total = AABB(p, Vector3.ZERO)
					first = false
				else:
					total = total.expand(p)
	root.free()
	return total


func test_the_kit_has_houses_and_a_mill() -> void:
	var kit: WorldKit = WorldKit.shared()
	assert_eq(kit.houses.size(), 5)
	assert_not_null(kit.mill)


func test_every_buildings_walls_stand_within_half_a_metre_of_its_footprint() -> void:
	var kit: WorldKit = WorldKit.shared()
	var bounds: Dictionary[KitPiece, AABB] = {}
	var checked: int = 0
	for path: String in MAPS:
		var info: MapInfo = load(path) as MapInfo
		var terrain: Terrain = Terrain.load_map(info)
		var structures: MapStructures = MapStructures.load_beside(info.heightmap_path)
		for record: StructureRecord in structures.records:
			if record.kind != &"house":
				continue
			var piece: KitPiece = kit.mill if record.model == &"mill" else StructurePlacer.house_piece(record, kit.houses, terrain)
			if not bounds.has(piece):
				bounds[piece] = _wall_bounds(piece)
			assert_true(bounds[piece].size.x > 0.0, "%s has wall surfaces" % piece.scene.resource_path)
			var rect: Rect2 = StructurePlacer.footprint_rect(record, terrain)
			var box: AABB = StructurePlacer.house_transform(record, piece, terrain) * bounds[piece]
			var at: String = "%s %s at %s (%s)" % [path.get_file(), record.kind, record.center_m, piece.scene.resource_path.get_file()]
			assert_almost_eq(box.position.x, rect.position.x, FIT_M, at + " west wall")
			assert_almost_eq(box.end.x, rect.end.x, FIT_M, at + " east wall")
			assert_almost_eq(box.position.z, rect.position.y, FIT_M, at + " north wall")
			assert_almost_eq(box.end.z, rect.end.y, FIT_M, at + " south wall")
			checked += 1
	assert_eq(checked, 14, "8 + 5 houses and the mill")
