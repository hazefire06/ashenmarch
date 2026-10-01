class_name ExplosionsView
extends Node3D
## What blasts and fire arrows leave behind, read from the World's projectile
## events after each step (MainView calls after_step()). Reads the World;
## never writes it.
## - A blast (EXPLODE) flashes: an unshaded, transparent sphere that grows and
##   fades in FLASH_TIME, then frees itself. If the blast dug a crater, the
##   terrain mesh and the gibs' ground collider are refreshed where the sim
##   scarred the heights, and a dark CraterMesh disc is laid on the new ground
##   for the rest of the mission.
## - A fuse that goes out (FIZZLE) leaves a small grey puff.
## - A fire arrow lighting the ground (IGNITE) leaves an orange-red scorch
##   disc.
##
## Explosions can overlap, and a later one digs under an earlier crater, so
## the discs near new scarring are rebuilt onto the changed ground.

## Seconds the flash grows and fades. It starts at FLASH_START_SHARE of its
## final size, which is FLASH_RADIUS_SHARE of the blast radius.
const FLASH_TIME: float = 0.4
const FLASH_START_SHARE: float = 0.2
const FLASH_RADIUS_SHARE: float = 0.6
const FLASH_COLOR: Color = Color(1.0, 0.72, 0.3, 0.85)
const PUFF_TIME: float = 0.8
const PUFF_START_RADIUS: float = 0.1
const PUFF_END_RADIUS: float = 0.5
## Meters a puff drifts upward.
const PUFF_RISE: float = 0.6
const PUFF_COLOR: Color = Color(0.62, 0.62, 0.62, 0.65)
## The crater disc covers this much more than the dug bowl, so its soft edge
## fades out beyond it.
const CRATER_DISC_SCALE: float = 1.25
const CRATER_COLOR: Color = Color(0.1, 0.07, 0.05, 0.85)
const CRATER_LIFT: float = 0.04
## Scorch marks sit a touch higher, so one inside a crater wins.
const SCORCH_RADIUS: int = 600
const SCORCH_COLOR: Color = Color(0.9, 0.3, 0.08, 0.8)
const SCORCH_LIFT: float = 0.06

var _world: World
var _terrain_view: TerrainView
var _gibs: Gibs
## Flashes and puffs still playing, and the craters and scorch marks that stay.
var _effects: Node3D
var _marks: Node3D
var _materials: Dictionary[Color, StandardMaterial3D] = {}


## terrain_view and gibs may be null, in which case the terrain mesh and the
## gibs' ground are left alone.
func setup(world: World, terrain_view: TerrainView, gibs: Gibs) -> void:
	_world = world
	_terrain_view = terrain_view
	_gibs = gibs
	_effects = Node3D.new()
	_effects.name = "Effects"
	add_child(_effects)
	_marks = Node3D.new()
	_marks.name = "Marks"
	add_child(_marks)


## Plays the tick's blasts, fizzles, and fires lit. Call it once after each
## World.step(), which clears the events it reads.
func after_step() -> void:
	for event: ProjectileEvent in _world.projectile_events:
		match event.kind:
			ProjectileEvent.Kind.EXPLODE:
				_on_explode(event)
			ProjectileEvent.Kind.FIZZLE:
				_puff(_point_of(event))
			ProjectileEvent.Kind.IGNITE:
				_add_mark(event.x, event.z, SCORCH_RADIUS, SCORCH_COLOR, SCORCH_LIFT)


## Flashes and puffs still playing.
func effect_count() -> int:
	return _effects.get_child_count()


## Craters and scorch marks on the ground.
func mark_count() -> int:
	return _marks.get_child_count()


func _on_explode(event: ProjectileEvent) -> void:
	_flash(_point_of(event), event.radius / float(World.UNITS_PER_METER))
	if event.crater <= 0:
		return
	# The ground changed first: re-mesh it, give the gibs the new ground, and
	# bring older discs down onto it, then lay this crater on the result.
	if event.cells.has_area():
		if _terrain_view != null:
			_terrain_view.rebuild_region(_world.terrain, event.cells)
		if _gibs != null:
			_gibs.update_heights_in(_world.terrain, event.cells)
		_refit_marks(event.cells)
	_add_mark(event.x, event.z, roundi(event.crater * CRATER_DISC_SCALE), CRATER_COLOR, CRATER_LIFT)


# A sphere that grows to FLASH_RADIUS_SHARE of the blast and fades out.
func _flash(at: Vector3, blast_radius: float) -> void:
	var end_radius: float = blast_radius * FLASH_RADIUS_SHARE
	_blob(at, end_radius * FLASH_START_SHARE, end_radius, FLASH_COLOR, FLASH_TIME, 0.0)


func _puff(at: Vector3) -> void:
	_blob(at, PUFF_START_RADIUS, PUFF_END_RADIUS, PUFF_COLOR, PUFF_TIME, PUFF_RISE)


# A transparent unshaded sphere at `at` that grows from start_radius to
# end_radius while rising by `rise` meters and fading to nothing over
# seconds, then frees itself.
func _blob(
	at: Vector3, start_radius: float, end_radius: float, color: Color, seconds: float, rise: float
) -> void:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radial_segments = 12
	sphere.rings = 6
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	var blob: MeshInstance3D = MeshInstance3D.new()
	blob.mesh = sphere
	blob.material_override = material
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The sphere is one meter across, so its scale is its radius times two.
	blob.scale = Vector3.ONE * start_radius * 2.0
	_effects.add_child(blob)
	blob.position = at
	var tween: Tween = create_tween().set_parallel(true)
	var growth: PropertyTweener = tween.tween_property(
		blob, "scale", Vector3.ONE * end_radius * 2.0, seconds
	)
	growth.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(material, "albedo_color:a", 0.0, seconds)
	if rise != 0.0:
		tween.tween_property(blob, "position:y", at.y + rise, seconds)
	tween.chain().tween_callback(blob.queue_free)


# Lays a disc of radius (milli-units) at (x, z) on the ground as it is now.
func _add_mark(x: int, z: int, radius: int, color: Color, lift: float) -> void:
	var mark: MeshInstance3D = MeshInstance3D.new()
	mark.mesh = CraterMesh.build(_world.terrain, x, z, radius, lift)
	mark.material_override = _mark_material(color)
	mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# What a rebuild needs to draw it again.
	mark.set_meta(&"disc", Vector3i(x, z, radius))
	mark.set_meta(&"lift", lift)
	_marks.add_child(mark)


# Rebuilds every disc whose ground overlaps cells (plus a sample of margin),
# the samples a new crater just lowered.
func _refit_marks(cells: Rect2i) -> void:
	var dirty: Rect2i = cells.grow(1)
	var cell: float = float(_world.terrain.cell_size)
	for mark: MeshInstance3D in _marks.get_children():
		var disc: Vector3i = mark.get_meta(&"disc")
		var first_i: int = floori((disc.x - disc.z) / cell)
		var first_j: int = floori((disc.y - disc.z) / cell)
		var last_i: int = ceili((disc.x + disc.z) / cell)
		var last_j: int = ceili((disc.y + disc.z) / cell)
		var covered: Rect2i = Rect2i(first_i, first_j, last_i - first_i + 1, last_j - first_j + 1)
		if covered.intersects(dirty):
			mark.mesh = CraterMesh.build(
				_world.terrain, disc.x, disc.y, disc.z, mark.get_meta(&"lift") as float
			)


# Discs are white vertex colors faded by alpha, tinted by the material.
func _mark_material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = _materials.get(color)
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.vertex_color_use_as_albedo = true
		material.albedo_color = color
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials[color] = material
	return material


static func _point_of(event: ProjectileEvent) -> Vector3:
	return Vector3(event.x, event.y, event.z) / float(World.UNITS_PER_METER)
