class_name AiDebugView
extends Node3D
## F5 debug overlay for the enemy AI, hidden until toggled. While shown it
## redraws after every step:
## - a camera-facing label over each group that has living members, at their
##   centroid: "name: BEHAVIOR";
## - lines laid on the ground (unshaded, drawn over everything): a PATROL's
##   waypoints as a loop or a polyline, the circle a GUARD chases within and
##   the one that springs an AMBUSH, around the group's anchor, the part of a
##   FLANK's route still to walk and a line to the unit it is circling, the
##   part of an ESCORT's route still to walk (nothing once it has arrived), and
##   every AREA_ENTERED trigger's circle, gray until it fires and green after.
## Reads the World; never writes it. Lines are floats in meters: this is view
## code, so the sim's integer rules don't apply.

## Segments in every circle. 32 reads as round at the radii the missions use.
const CIRCLE_SEGMENTS: int = 32
## Longest piece a straight line is cut into, in meters, so a long route
## follows the hills instead of cutting through them.
const STEP_LENGTH: float = 4.0
## Meters the lines sit above the ground, so they don't z-fight with it.
const LINE_LIFT: float = 0.3
## Meters a label floats above the ground at the group's centroid.
const LABEL_LIFT: float = 3.0
## Label3D size. The label keeps one apparent size at any camera distance
## (fixed_size), about 2% of the screen height at this pixel_size.
const LABEL_PIXEL_SIZE: float = 0.0009
const LABEL_FONT_SIZE: int = 40
const LABEL_OUTLINE_SIZE: int = 10
const PATROL_COLOR: Color = Color(0.3, 0.9, 1.0)
const GUARD_COLOR: Color = Color(1.0, 0.65, 0.2)
const AMBUSH_COLOR: Color = Color(1.0, 0.3, 0.3)
const FLANK_COLOR: Color = Color(1.0, 0.4, 0.9)
const HUNT_COLOR: Color = Color(1.0, 0.95, 0.4)
const IDLE_COLOR: Color = Color(0.8, 0.8, 0.8)
const RETREAT_COLOR: Color = Color(0.5, 0.6, 1.0)
const ESCORT_COLOR: Color = Color(0.65, 1.0, 0.8)
const TRIGGER_IDLE_COLOR: Color = Color(0.6, 0.6, 0.6)
const TRIGGER_FIRED_COLOR: Color = Color(0.35, 1.0, 0.4)

var _world: World
var _mesh: ImmediateMesh
var _lines: MeshInstance3D
var _labels: Array[Label3D] = []
# The last redraw's line ends, two per line, and one color per end.
var _points: PackedVector3Array = PackedVector3Array()
var _colors: PackedColorArray = PackedColorArray()


func _ready() -> void:
	InputBindings.install()
	visible = false
	_mesh = ImmediateMesh.new()
	_lines = MeshInstance3D.new()
	_lines.mesh = _mesh
	_lines.material_override = _line_material()
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)


## The world whose groups and triggers are drawn.
func setup(world: World) -> void:
	_world = world


## Shows the overlay if hidden, hides it if shown. Showing draws it at once.
func toggle() -> void:
	visible = not visible
	if visible:
		redraw()


## Redraws the overlay for the tick just simulated. MainView calls it after
## each World.step(); it does nothing while the overlay is hidden.
func after_step() -> void:
	if visible:
		redraw()


## Rebuilds the labels and the lines from the world as it is now.
func redraw() -> void:
	if _world == null or _mesh == null:
		return
	_points = PackedVector3Array()
	_colors = PackedColorArray()
	var shown: int = 0
	for group: AiGroup in _world.ai.groups:
		var units: Array[Unit] = group.living(_world)
		if units.is_empty():
			continue
		var color: Color = behavior_color(group.behavior)
		var centroid: Vector2i = AiOrders.centroid(units)
		_show_label(shown, group_label(group), centroid, color)
		shown += 1
		_draw_group(group, centroid, color)
	for i: int in range(shown, _labels.size()):
		_labels[i].visible = false
	_draw_triggers()
	_mesh.clear_surfaces()
	if _points.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i: int in _points.size():
		_mesh.surface_set_color(_colors[i])
		_mesh.surface_add_vertex(_points[i])
	_mesh.surface_end()


## The text of every label on show, in group order.
func label_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for label: Label3D in _labels:
		if label.visible:
			out.append(label.text)
	return out


## Where the index-th label on show floats (meters), counting from the first.
func label_position(index: int) -> Vector3:
	return _labels[index].position


## How many lines the last redraw drew.
func line_count() -> int:
	return _points.size() >> 1


## The color of every line end the last redraw drew, two per line.
func line_colors() -> PackedColorArray:
	return _colors


## "name: BEHAVIOR", what a group's label says.
static func group_label(group: AiGroup) -> String:
	return "%s: %s" % [group.spec.name, AiGroupSpec.Behavior.find_key(group.behavior)]


## CIRCLE_SEGMENTS points evenly round a circle, the first due east of the
## center; the circle closes from the last point back to the first.
static func circle(center: Vector2, radius: float, segments: int = CIRCLE_SEGMENTS) -> PackedVector2Array:
	var points: PackedVector2Array = PackedVector2Array()
	for i: int in segments:
		var angle: float = TAU * i / segments
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


## Gray for a trigger that has not fired, green for one that has.
static func trigger_color(fired: bool) -> Color:
	return TRIGGER_FIRED_COLOR if fired else TRIGGER_IDLE_COLOR


## The color a group's label and lines are drawn in, by what it is doing.
static func behavior_color(behavior: AiGroupSpec.Behavior) -> Color:
	match behavior:
		AiGroupSpec.Behavior.PATROL:
			return PATROL_COLOR
		AiGroupSpec.Behavior.GUARD:
			return GUARD_COLOR
		AiGroupSpec.Behavior.AMBUSH:
			return AMBUSH_COLOR
		AiGroupSpec.Behavior.FLANK:
			return FLANK_COLOR
		AiGroupSpec.Behavior.HUNT:
			return HUNT_COLOR
		AiGroupSpec.Behavior.RETREAT:
			return RETREAT_COLOR
		AiGroupSpec.Behavior.ESCORT:
			return ESCORT_COLOR
	return IDLE_COLOR


# Nodes receive unhandled input while hidden, which is how F5 shows it again.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(InputBindings.TOGGLE_AI_DEBUG):
		toggle()
		get_viewport().set_input_as_handled()


# The shapes that say what a group is up to. A patrol only shows its route
# while it is patrolling: once it has turned to hunting, the route is history.
func _draw_group(group: AiGroup, centroid: Vector2i, color: Color) -> void:
	var anchor: Vector2 = _meters(Vector2i(group.anchor_x, group.anchor_z))
	match group.behavior:
		AiGroupSpec.Behavior.PATROL:
			_draw_patrol(group.spec, color)
		AiGroupSpec.Behavior.GUARD:
			var radius: int = group.spec.guard_radius
			if radius <= 0:
				radius = AiBehaviors.DEFAULT_GUARD_RADIUS
			_add_ring(anchor, radius / float(World.UNITS_PER_METER), color)
		AiGroupSpec.Behavior.AMBUSH:
			_add_ring(anchor, group.spec.alert_radius / float(World.UNITS_PER_METER), color)
		AiGroupSpec.Behavior.FLANK:
			_draw_flank(group, centroid, color)
		AiGroupSpec.Behavior.ESCORT:
			_draw_escort(group, centroid, color)


# The waypoints joined in order, and for a LOOP the last joined back to the
# first. Two waypoints are one line either way.
func _draw_patrol(spec: AiGroupSpec, color: Color) -> void:
	var count: int = spec.waypoints.size() >> 1
	for i: int in count - 1:
		_add_line(_waypoint(spec, i), _waypoint(spec, i + 1), color)
	if spec.patrol_mode == AiGroupSpec.PatrolMode.LOOP and count > 2:
		_add_line(_waypoint(spec, count - 1), _waypoint(spec, 0), color)


# From the group to the next route point and on to the end; and to the unit it
# is circling, dimmer.
func _draw_flank(group: AiGroup, centroid: Vector2i, color: Color) -> void:
	var from: Vector2 = _meters(centroid)
	for i: int in range(group.route_index, group.route.size() >> 1):
		var to: Vector2 = _meters(Vector2i(group.route[2 * i], group.route[2 * i + 1]))
		_add_line(from, to, color)
		from = to
	var focus: Unit = _world.get_unit(group.focus_id) if group.focus_id != 0 else null
	if focus != null and focus.is_alive():
		_add_line(_meters(centroid), _meters(Vector2i(focus.x, focus.z)), color.darkened(0.4))


# From the group to the waypoint it is walking to and on to the last: what is
# left of the route, which shrinks as it goes. Once it has arrived (phase 2) the
# members hold and there is nothing left to draw.
func _draw_escort(group: AiGroup, centroid: Vector2i, color: Color) -> void:
	if group.phase == 2:
		return
	var from: Vector2 = _meters(centroid)
	for i: int in range(group.waypoint_index, group.spec.waypoints.size() >> 1):
		var to: Vector2 = _waypoint(group.spec, i)
		_add_line(from, to, color)
		from = to


func _draw_triggers() -> void:
	if _world.mission == null:
		return
	var triggers: Array[TriggerSpec] = _world.mission.mission_script.triggers
	for i: int in triggers.size():
		var area: PackedInt32Array = triggers[i].area
		if triggers[i].condition != TriggerSpec.Condition.AREA_ENTERED or area.size() != 3:
			continue
		var fired: bool = _world.mission.fired_tick[i] >= 0
		_add_ring(_meters(Vector2i(area[0], area[1])), area[2] / float(World.UNITS_PER_METER), trigger_color(fired))


func _add_ring(center: Vector2, radius: float, color: Color) -> void:
	var points: PackedVector2Array = circle(center, radius)
	for i: int in points.size():
		_add_segment(points[i], points[(i + 1) % points.size()], color)


# A straight line, cut into pieces of at most STEP_LENGTH.
func _add_line(from: Vector2, to: Vector2, color: Color) -> void:
	var pieces: int = maxi(1, ceili(from.distance_to(to) / STEP_LENGTH))
	var start: Vector2 = from
	for i: int in range(1, pieces + 1):
		var end: Vector2 = from.lerp(to, float(i) / pieces)
		_add_segment(start, end, color)
		start = end


func _add_segment(from: Vector2, to: Vector2, color: Color) -> void:
	_points.append(_on_ground(from, LINE_LIFT))
	_points.append(_on_ground(to, LINE_LIFT))
	_colors.append(color)
	_colors.append(color)


func _show_label(index: int, text: String, at: Vector2i, color: Color) -> void:
	while _labels.size() <= index:
		_labels.append(_make_label())
	var label: Label3D = _labels[index]
	if label.text != text:
		label.text = text
	label.modulate = color
	label.position = _on_ground(_meters(at), LABEL_LIFT)
	label.visible = true


func _make_label() -> Label3D:
	var label: Label3D = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = LABEL_PIXEL_SIZE
	label.font_size = LABEL_FONT_SIZE
	label.outline_size = LABEL_OUTLINE_SIZE
	label.no_depth_test = true
	label.render_priority = 1
	add_child(label)
	return label


func _waypoint(spec: AiGroupSpec, index: int) -> Vector2:
	return _meters(Vector2i(spec.waypoints[2 * index], spec.waypoints[2 * index + 1]))


# The point `lift` meters above the ground at (x, z) meters, on the world's
# own terrain (explosions scar it).
func _on_ground(at: Vector2, lift: float) -> Vector3:
	var height: int = _world.terrain.height_at(
		roundi(at.x * World.UNITS_PER_METER), roundi(at.y * World.UNITS_PER_METER)
	)
	return Vector3(at.x, height / float(World.UNITS_PER_METER) + lift, at.y)


static func _meters(milli: Vector2i) -> Vector2:
	return Vector2(milli) / float(World.UNITS_PER_METER)


# Unshaded, vertex-colored, and drawn over the terrain and the units: the
# lines are the point, so nothing may hide them. Alpha blending puts them in
# the transparent pass, after everything opaque.
static func _line_material() -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	return material
