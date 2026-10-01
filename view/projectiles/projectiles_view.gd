class_name ProjectilesView
extends Node3D
## Draws every live sim projectile, and the arrows that have stuck in the
## ground. Reads the World; never writes it. MainView calls after_step() after
## each World.step().
##
## A live projectile is one node, drawn between its last two tick positions by
## the physics interpolation fraction, the same scheme as UnitsView. Its look
## follows its type's data, not its id:
## - an arrow (a sticking projectile) is a thin unshaded box, tip at the
##   projectile's position, turned along its flight;
## - a fused ball (a grenade) is a sphere in the type's color, with a bright
##   spark that blinks while the fuse burns. A dud is darker and has no spark;
## - a burst waiting to go off with no pickup (a Blightbag's) is a ball in
##   its color;
## - any other bouncing projectile is a small box in the type's color with a
##   label: "Charge" for one with a blast (a satchel), else the type's name
##   (a herb, a gas packet, a body part). Something carried rides in its
##   carrier's hand: the sim puts it there.
##
## object_at() picks a loose object someone could pick up, for right-click
## orders and the tooltip.
##
## The sim forgets an arrow once it sticks and only reports a STICK event, so
## the stuck ones are cosmetic: a ring buffer of STUCK_ARROW_LIMIT instances
## in one MultiMesh, oldest reused first. An arrow that lands in water
## (depth > 0) is not drawn.

## Thickness of an arrow, meters.
const ARROW_THICKNESS: float = 0.03
## Share of a stuck arrow's length buried in the ground.
const STUCK_SINK: float = 0.25
## Most stuck arrows kept; past this the oldest are replaced.
const STUCK_ARROW_LIMIT: int = 1500
## A sphere smaller than this (meters) would be invisible at RTS distances.
const MIN_BALL_RADIUS: float = 0.08
const SPARK_RADIUS: float = 0.05
const SPARK_COLOR: Color = Color(1.0, 0.92, 0.45)
## The spark blinks every this many ticks, and faster once the fuse has this
## many ticks left or fewer.
const BLINK_TICKS: int = 6
const BLINK_TICKS_FAST: int = 3
const FAST_BLINK_FUSE: int = 30
## How much darker a dud is drawn.
const DUD_DARKEN: float = 0.6
const CHARGE_LABEL: String = "Charge"
## The label is hidden beyond this many meters, like unit names.
const LABEL_RANGE: float = 35.0
## Pixels around a loose object's center that still count as pointing at it.
const PICK_RADIUS: float = 14.0

var _world: World
## One root node per live projectile, keyed by entity id, and the positions
## of its last two ticks.
var _nodes: Dictionary[int, Node3D] = {}
var _previous: Dictionary[int, Vector3] = {}
var _current: Dictionary[int, Vector3] = {}
## The node's body mesh (to recolor a dud) and, for a fused ball, its spark.
var _bodies: Dictionary[int, MeshInstance3D] = {}
var _sparks: Dictionary[int, MeshInstance3D] = {}
var _materials: Dictionary[Color, StandardMaterial3D] = {}
var _stuck: MultiMesh
## Next slot to write, and how many slots hold an arrow.
var _stuck_next: int = 0
var _stuck_count: int = 0


func setup(world: World) -> void:
	_world = world
	_build_stuck_arrows()
	after_step()


## Picks up the tick just simulated: new projectiles get nodes, gone ones
## lose them, every node's interpolation window moves forward a tick, and the
## tick's arrows that stuck join the ground. Call it once after each
## World.step(), which clears the events it reads.
func after_step() -> void:
	var seen: Dictionary[int, bool] = {}
	for p: Projectile in _world.projectiles:
		seen[p.id] = true
		var node: Node3D = _nodes.get(p.id)
		if node == null:
			node = _make_node(p)
		_previous[p.id] = _current[p.id]
		_current[p.id] = _position_of(p)
		_update_node(node, p)
	for projectile_id: int in _nodes.keys():
		if not seen.has(projectile_id):
			_nodes[projectile_id].queue_free()
			_nodes.erase(projectile_id)
			_bodies.erase(projectile_id)
			_sparks.erase(projectile_id)
			_previous.erase(projectile_id)
			_current.erase(projectile_id)
	for event: ProjectileEvent in _world.projectile_events:
		if event.kind == ProjectileEvent.Kind.STICK and event.depth == 0:
			_add_stuck_arrow(event)


## Projectiles currently drawn in flight, rolling, or resting.
func projectile_count() -> int:
	return _nodes.size()


## Stuck arrows currently drawn.
func stuck_arrow_count() -> int:
	return _stuck_count


## The node drawing the projectile with this id, or null.
func node_of(projectile_id: int) -> Node3D:
	return _nodes.get(projectile_id)


## Whether a fused ball's spark is lit when its fuse has fuse_left ticks to
## go. Dark for a dud and with no fuse burning, and blinking otherwise: slowly
## at first, faster for the last second.
static func spark_lit(fuse_left: int, dud: bool) -> bool:
	if dud or fuse_left <= 0:
		return false
	var period: int = BLINK_TICKS_FAST if fuse_left <= FAST_BLINK_FUSE else BLINK_TICKS
	return (fuse_left / period) % 2 == 0


## The transform of a unit-long box standing as a stuck arrow: turned along
## direction (any length; straight down for zero), scaled to length meters,
## and placed so the end of it that met the ground at `tip` ends up buried by
## STUCK_SINK of its length, the rest standing out of the ground.
static func stuck_transform(tip: Vector3, direction: Vector3, length: float) -> Transform3D:
	var forward: Vector3 = direction.normalized()
	if forward.is_zero_approx():
		forward = Vector3.DOWN
	var scaled: Basis = aim_basis(forward).scaled_local(Vector3(1.0, 1.0, length))
	# The box is centered: half a length back from the buried tip.
	var buried_tip: Vector3 = tip + forward * length * STUCK_SINK
	return Transform3D(scaled, buried_tip - forward * length * 0.5)


## A basis whose -z axis points along direction (any length), with y kept
## upward where it can be. Identity for a zero direction.
static func aim_basis(direction: Vector3) -> Basis:
	var forward: Vector3 = direction.normalized()
	if forward.is_zero_approx():
		return Basis.IDENTITY
	# Looking straight up or down leaves "up" undefined, so pick another.
	var up: Vector3 = Vector3.UP if absf(forward.y) < 0.99 else Vector3.RIGHT
	return Basis.looking_at(forward, up)


func _process(_delta: float) -> void:
	var alpha: float = Engine.get_physics_interpolation_fraction()
	for projectile_id: int in _nodes:
		_nodes[projectile_id].position = _previous[projectile_id].lerp(_current[projectile_id], alpha)


# Makes the node for a projectile that has just appeared. It starts standing
# still: both ends of its interpolation window are where it is now.
func _make_node(p: Projectile) -> Node3D:
	var t: ProjectileType = p.type
	var mm: float = float(World.UNITS_PER_METER)
	var root: Node3D = Node3D.new()
	root.name = "Projectile_%d" % p.id
	var body: MeshInstance3D = MeshInstance3D.new()
	body.name = "Body"
	if t.behavior == ProjectileType.Behavior.STICKS:
		var arrow: BoxMesh = BoxMesh.new()
		var length: float = t.length / mm
		arrow.size = Vector3(ARROW_THICKNESS, ARROW_THICKNESS, length)
		body.mesh = arrow
		# Boxes are centered; put the tip at the node's origin, the tail
		# behind it (+z, since the node looks along -z).
		body.position = Vector3(0.0, 0.0, length * 0.5)
	elif t.fuse_ticks > 0 or (t.pickup == ProjectileType.Pickup.NONE and t.bursts()):
		var radius: float = maxf(t.radius / mm, MIN_BALL_RADIUS)
		var ball: SphereMesh = SphereMesh.new()
		ball.radius = radius
		ball.height = radius * 2.0
		ball.radial_segments = 12
		ball.rings = 6
		body.mesh = ball
		if t.fuse_ticks > 0:
			var spark: MeshInstance3D = _make_spark(radius)
			root.add_child(spark)
			_sparks[p.id] = spark
	else:
		var box: BoxMesh = BoxMesh.new()
		box.size = Vector3.ONE * t.radius * 2.0 / mm
		body.mesh = box
		root.add_child(_make_charge_label(t.radius / mm, label_for(t)))
	body.material_override = _material(_color_of(p))
	root.add_child(body)
	add_child(root)
	_nodes[p.id] = root
	_bodies[p.id] = body
	_current[p.id] = _position_of(p)
	return root


# Turns an arrow along its flight, darkens a dud, and blinks a live spark.
func _update_node(node: Node3D, p: Projectile) -> void:
	if p.type.behavior == ProjectileType.Behavior.STICKS:
		node.basis = aim_basis(Vector3(p.flight.vx, p.flight.vy, p.flight.vz))
	_bodies[p.id].material_override = _material(_color_of(p))
	var spark: MeshInstance3D = _sparks.get(p.id)
	if spark != null:
		spark.visible = spark_lit(p.fuse_left, p.dud)


func _make_spark(ball_radius: float) -> MeshInstance3D:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = SPARK_RADIUS
	sphere.height = SPARK_RADIUS * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	var spark: MeshInstance3D = MeshInstance3D.new()
	spark.name = "Spark"
	spark.mesh = sphere
	spark.material_override = _material(SPARK_COLOR)
	# On top of the ball, where a fuse would be.
	spark.position = Vector3(0.0, ball_radius + SPARK_RADIUS * 0.5, 0.0)
	spark.visible = false
	return spark


## The label over a loose object of type t: "Charge" for anything with a
## blast, else its name.
static func label_for(t: ProjectileType) -> String:
	return CHARGE_LABEL if t.is_explosive() else t.display_name


## The id of the loose object under the screen point that could be picked up
## (lying still, with a pickup kind), the nearest the camera if several; -1
## if none.
func object_at(camera: Camera3D, at: Vector2) -> int:
	var best: int = -1
	var best_distance: float = INF
	for p: Projectile in _world.projectiles:
		if p.removed or p.motion != Projectile.Motion.RESTING or p.type.pickup == ProjectileType.Pickup.NONE:
			continue
		var node: Node3D = _nodes.get(p.id)
		if node == null or camera.is_position_behind(node.global_position):
			continue
		if camera.unproject_position(node.global_position).distance_to(at) > PICK_RADIUS:
			continue
		var d: float = camera.global_position.distance_to(node.global_position)
		if d < best_distance:
			best = p.id
			best_distance = d
	return best


func _make_charge_label(half_size: float, text: String) -> Label3D:
	var label: Label3D = Label3D.new()
	label.name = "Label"
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.006
	label.font_size = 32
	label.outline_size = 8
	label.no_depth_test = true
	label.position = Vector3(0.0, half_size + 0.25, 0.0)
	label.visibility_range_end = LABEL_RANGE
	return label


# The type's placeholder color, darker for a dud.
static func _color_of(p: Projectile) -> Color:
	var color: Color = p.type.placeholder_color
	return color.darkened(DUD_DARKEN) if p.dud else color


# One shared unshaded material per color.
func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = _materials.get(color)
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		_materials[color] = material
	return material


static func _position_of(p: Projectile) -> Vector3:
	return Vector3(p.x, p.y, p.z) / float(World.UNITS_PER_METER)


func _build_stuck_arrows() -> void:
	var unit_arrow: BoxMesh = BoxMesh.new()
	# One meter long; each instance scales it to its own arrow's length.
	unit_arrow.size = Vector3(ARROW_THICKNESS, ARROW_THICKNESS, 1.0)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Each instance carries its type's color.
	material.vertex_color_use_as_albedo = true
	_stuck = MultiMesh.new()
	_stuck.transform_format = MultiMesh.TRANSFORM_3D
	_stuck.use_colors = true
	_stuck.mesh = unit_arrow
	_stuck.instance_count = STUCK_ARROW_LIMIT
	_stuck.visible_instance_count = 0
	if _world.terrain != null:
		# Stuck arrows can be anywhere on the map; don't cull them by the
		# bounds of whichever instances were written first.
		var mm: float = float(World.UNITS_PER_METER)
		_stuck.custom_aabb = AABB(
			Vector3(-10.0, -1000.0, -10.0),
			Vector3(_world.terrain.extent_x() / mm + 20.0, 3000.0, _world.terrain.extent_z() / mm + 20.0)
		)
	var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	instance.name = "StuckArrows"
	instance.multimesh = _stuck
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


# Adds an arrow standing in the ground where the event says, reusing the
# oldest slot once the buffer is full.
func _add_stuck_arrow(event: ProjectileEvent) -> void:
	var mm: float = float(World.UNITS_PER_METER)
	var type: ProjectileType = _world.catalog.projectile_types[event.type_index]
	var tip: Vector3 = Vector3(event.x, event.y, event.z) / mm
	var direction: Vector3 = Vector3(event.dir_x, event.dir_y, event.dir_z)
	_stuck.set_instance_transform(_stuck_next, stuck_transform(tip, direction, type.length / mm))
	_stuck.set_instance_color(_stuck_next, type.placeholder_color)
	_stuck_next = (_stuck_next + 1) % STUCK_ARROW_LIMIT
	_stuck_count = mini(_stuck_count + 1, STUCK_ARROW_LIMIT)
	_stuck.visible_instance_count = _stuck_count
