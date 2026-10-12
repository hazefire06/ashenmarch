class_name UnitSprite
extends Node3D
## Placeholder look for one unit until the art pass: a flat-colored quad that
## always faces the camera, pivoting on its feet at this node's origin, the
## type's name above it, a tick on the ground showing which way it faces, a
## ring when selected, and a health bar when hurt or selected. A full
## billboard (rather than one turning only about the vertical axis) keeps the
## quad a clean upright rectangle on screen at the steep RTS camera pitch,
## where a vertical quad would look squashed and lean with perspective.
##
## A hit or block tints the quad for FLASH_TIME (a heal tints it green), and
## show_notice() floats a line of text over the unit for NOTICE_TIME. Status
## effects (set_statuses) tint the quad while they last and name themselves
## in a tag above the name: pale blue for paralysis, magenta for confusion,
## and a flickering orange for burning. A dead unit's quad stops
## billboarding and lies on the ground, head away from the killing blow, dimmed
## and unlabeled, and stays there. A gibbed body is not drawn at all; the gibs
## replace it.

const RING_COLOR: Color = Color(1.0, 0.92, 0.35)
const FACING_COLOR: Color = Color(0.08, 0.08, 0.08)
const DEAD_TINT: Color = Color(0.35, 0.35, 0.35)
const HIT_FLASH_COLOR: Color = Color(1.0, 0.96, 0.9)
const BLOCK_FLASH_COLOR: Color = Color(0.55, 0.66, 0.82)
const HEAL_FLASH_COLOR: Color = Color(0.45, 1.0, 0.5)
## Status tints and tag colors, and how far the body is pulled toward them.
const PARALYZED_COLOR: Color = Color(0.6, 0.8, 1.0)
const CONFUSED_COLOR: Color = Color(1.0, 0.35, 0.9)
const BURNING_COLOR: Color = Color(1.0, 0.5, 0.1)
const STATUS_TINT: float = 0.55
## Seconds per flicker of a burning unit's tint.
const BURN_FLICKER_TIME: float = 0.12
const PARALYZED_TEXT: String = "Paralyzed"
const CONFUSED_TEXT: String = "Confused"
const BURNING_TEXT: String = "Burning"
## Seconds a hit or block tint takes to fade out.
const FLASH_TIME: float = 0.12
## Seconds a notice ("Can't reach") stays over the unit.
const NOTICE_TIME: float = 1.0
const NOTICE_COLOR: Color = Color(1.0, 0.72, 0.3)
## Labels farther than this from the camera are hidden: zoomed out, a
## formation's worth of names would bury the units under text.
const LABEL_RANGE: float = 35.0
## Health bar size in meters, and its gap above the head.
const HP_BAR_WIDTH: float = 0.9
const HP_BAR_HEIGHT: float = 0.1
const HP_BAR_LIFT: float = 0.1
## Colors of the bar's empty part, and the fill's saturation and value. Its hue
## runs from red (empty) to green (full) through yellow.
const HP_EMPTY_COLOR: Color = Color(0.16, 0.05, 0.05)
const HP_FILL_SATURATION: float = 0.85
const HP_FILL_VALUE: float = 0.9
const HP_HUE_FULL: float = 0.33
## A body lying on the ground floats this far above it, so it doesn't z-fight
## the terrain.
const LYING_LIFT: float = 0.06
## Below this squared length a direction counts as zero.
const MIN_DIRECTION_SQUARED: float = 0.0001

var unit_id: int
var type_index: int
## Meters: quad height and half width, for screen-space picking.
var height: float
var half_width: float

var _color: Color
var _body_material: StandardMaterial3D
var _body: MeshInstance3D
var _label: Label3D
var _notice: Label3D
var _ring: MeshInstance3D
var _facing_pivot: Node3D
var _hp_bar: Node3D
var _hp_fill: MeshInstance3D
var _hp_fill_mesh: QuadMesh
var _hp_fill_material: StandardMaterial3D
var _hp_empty: MeshInstance3D
var _hp_empty_mesh: QuadMesh
var _hp: int = 1
var _max_hp: int = 1
var _selected: bool = false
var _health_shown: bool = false
var _dead: bool = false
var _gibbed: bool = false
## Ground direction (x, z) the unit faces, unit length.
var _facing: Vector2 = Vector2(0.0, -1.0)
var _flash_color: Color = HIT_FLASH_COLOR
var _flash_left: float = 0.0
var _notice_left: float = 0.0
var _paralyzed: bool = false
var _confused: bool = false
var _burning: bool = false
var _flicker: float = 0.0
var _status_tag: Label3D


func setup(unit: Unit) -> void:
	unit_id = unit.id
	type_index = unit.type_index
	var t: UnitType = unit.type
	var mm: float = float(World.UNITS_PER_METER)
	height = t.body_height / mm
	half_width = t.body_radius / mm + 0.05
	_color = t.placeholder_color
	name = "Unit_%d" % unit.id

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(half_width * 2.0, height)
	quad.center_offset = Vector3(0.0, height * 0.5, 0.0)
	_body_material = _unshaded(_color)
	_body_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_body_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_body = MeshInstance3D.new()
	_body.mesh = quad
	_body.material_override = _body_material
	add_child(_body)

	_label = _make_label(t.display_name, Color.WHITE)
	_label.position = Vector3(0.0, height + 0.3, 0.0)
	add_child(_label)

	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = half_width + 0.12
	torus.outer_radius = half_width + 0.24
	torus.rings = 24
	torus.ring_segments = 4
	var ring_material: StandardMaterial3D = _unshaded(RING_COLOR)
	# Drawn over the ground so slopes don't swallow half the ring.
	ring_material.no_depth_test = true
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = ring_material
	_ring.position.y = 0.05
	_ring.visible = false
	add_child(_ring)

	var tick: BoxMesh = BoxMesh.new()
	tick.size = Vector3(0.08, 0.04, 0.4)
	var tick_instance: MeshInstance3D = MeshInstance3D.new()
	tick_instance.mesh = tick
	tick_instance.material_override = _unshaded(FACING_COLOR)
	tick_instance.position = Vector3(0.0, 0.05, half_width + 0.25)
	_facing_pivot = Node3D.new()
	_facing_pivot.add_child(tick_instance)
	add_child(_facing_pivot)
	set_facing(unit.facing_x, unit.facing_z)

	_hp = unit.hp
	_max_hp = maxi(t.max_hp, 1)
	_build_hp_bar()
	_refresh_overlays()
	# Only a flash or a notice needs _process; each turns it on then.
	set_process(false)


func set_selected(selected: bool) -> void:
	_selected = selected
	_refresh_overlays()


## Shows the health bar even at full health (F10 held, Phase 11).
func set_health_shown(shown: bool) -> void:
	_health_shown = shown
	_refresh_overlays()


## Turns the ground tick toward (x, z), any length.
func set_facing(x: int, z: int) -> void:
	if x != 0 or z != 0:
		_facing = Vector2(x, z).normalized()
		_facing_pivot.rotation.y = atan2(float(x), float(z))


## Updates the health bar. It shows only while hurt or selected.
func set_hp(hp: int, max_hp: int) -> void:
	if hp == _hp and max_hp == _max_hp:
		return
	_hp = hp
	_max_hp = maxi(max_hp, 1)
	_update_hp_bar()
	_refresh_overlays()


## Tints the body briefly: white for a HIT, steel blue for a BLOCK, green for
## a HEAL. Other kinds, and a dead unit, do nothing.
func flash(kind: CombatEvent.Kind) -> void:
	if _dead:
		return
	if kind == CombatEvent.Kind.HIT:
		_flash_color = HIT_FLASH_COLOR
	elif kind == CombatEvent.Kind.BLOCK:
		_flash_color = BLOCK_FLASH_COLOR
	elif kind == CombatEvent.Kind.HEAL:
		_flash_color = HEAL_FLASH_COLOR
	else:
		return
	_flash_left = FLASH_TIME
	_apply_body_color()
	set_process(true)


## Floats text over the unit for NOTICE_TIME seconds, replacing any notice
## already showing.
func show_notice(text: String) -> void:
	if _notice == null:
		_notice = _make_label(text, NOTICE_COLOR)
		# Above the name label.
		_notice.position = Vector3(0.0, height + 0.7, 0.0)
		add_child(_notice)
	_notice.text = text
	_notice.visible = not _dead
	_notice_left = NOTICE_TIME
	set_process(true)


## The notice's text while it is showing, else an empty string.
func notice_text() -> String:
	return _notice.text if _notice != null and _notice.visible else ""


## Shows which status effects the unit is under: a tint on the body and a tag
## naming them. Repeating the current state does nothing.
func set_statuses(paralyzed: bool, confused: bool, burning: bool) -> void:
	if paralyzed == _paralyzed and confused == _confused and burning == _burning:
		return
	_paralyzed = paralyzed
	_confused = confused
	_burning = burning
	var names: PackedStringArray = PackedStringArray()
	if paralyzed:
		names.append(PARALYZED_TEXT)
	if confused:
		names.append(CONFUSED_TEXT)
	if burning:
		names.append(BURNING_TEXT)
	if names.is_empty():
		if _status_tag != null:
			_status_tag.visible = false
	else:
		if _status_tag == null:
			_status_tag = _make_label("", Color.WHITE)
			# Between the name and a notice.
			_status_tag.position = Vector3(0.0, height + 0.5, 0.0)
			_status_tag.font_size = 26
			add_child(_status_tag)
		_status_tag.text = " · ".join(names)
		_status_tag.modulate = _status_color()
		_status_tag.visible = not _dead
	_apply_body_color()
	if burning:
		set_process(true)


## The status tag's text while it shows, else an empty string.
func status_text() -> String:
	return _status_tag.text if _status_tag != null and _status_tag.visible else ""


## Lays the body on the ground, or stands it back up. blow_dir is the ground
## direction (x, z) of the killing blow: the body falls that way, head first.
## Zero falls backward from where the unit faced. ground_normal tilts the body
## to lie flat on a slope. Repeating the current state does nothing, so a body
## lies down once and stays put.
func set_dead(dead: bool, blow_dir: Vector2 = Vector2.ZERO, ground_normal: Vector3 = Vector3.UP) -> void:
	if dead == _dead:
		return
	_dead = dead
	_flash_left = 0.0
	if dead:
		_lay_down(blow_dir if not blow_dir.is_zero_approx() else -_facing, ground_normal)
	else:
		_body_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_body.transform = Transform3D.IDENTITY
	_apply_body_color()
	_refresh_overlays()


## Hides the body: it burst into gibs. Permanent.
func set_gibbed() -> void:
	_gibbed = true
	_body.visible = false


func is_dead() -> bool:
	return _dead


## False once there is nothing left to point at (gibbed).
func is_pickable() -> bool:
	return not _gibbed


## World-space corners of the body quad as it lies on the ground, for picking.
## Only meaningful while dead.
func lying_corners() -> PackedVector3Array:
	var to_world: Transform3D = global_transform * _body.transform
	return PackedVector3Array([
		to_world * Vector3(-half_width, 0.0, 0.0),
		to_world * Vector3(half_width, 0.0, 0.0),
		to_world * Vector3(half_width, height, 0.0),
		to_world * Vector3(-half_width, height, 0.0),
	])


func _process(delta: float) -> void:
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - delta, 0.0)
		_apply_body_color()
	if _notice_left > 0.0:
		_notice_left -= delta
		if _notice_left <= 0.0:
			_notice.visible = false
	var burning: bool = _burning and not _dead
	if burning:
		_flicker += delta
		_apply_body_color()
	if _flash_left <= 0.0 and _notice_left <= 0.0 and not burning:
		set_process(false)


# Body color: the type's, dimmed when dead, pulled toward a status tint (a
# burning one flickers), and blended toward the flash color while a flash
# fades.
func _apply_body_color() -> void:
	var base: Color = _color * DEAD_TINT if _dead else _color
	if not _dead and (_paralyzed or _confused or _burning):
		var tint: float = STATUS_TINT
		if _burning and not _paralyzed and not _confused:
			tint *= 0.6 + 0.4 * float(int(_flicker / BURN_FLICKER_TIME) % 2)
		base = base.lerp(_status_color(), tint)
	_body_material.albedo_color = base.lerp(_flash_color, _flash_left / FLASH_TIME)


# The most telling status: paralysis, then confusion, then burning.
func _status_color() -> Color:
	if _paralyzed:
		return PARALYZED_COLOR
	if _confused:
		return CONFUSED_COLOR
	return BURNING_COLOR


# Ring, label, facing tick, and health bar belong to a living unit.
func _refresh_overlays() -> void:
	var alive: bool = not _dead
	_ring.visible = alive and _selected
	_label.visible = alive
	if _notice != null and not alive:
		_notice.visible = false
	if _status_tag != null and not alive:
		_status_tag.visible = false
	_facing_pivot.visible = alive
	_hp_bar.visible = alive and (_selected or _health_shown or _hp < _max_hp)


# The quad's local frame is x across, y from feet to head, z its face. Lying
# down, z becomes the ground normal and y the fall direction; the body is
# centered where the unit stood.
func _lay_down(fall: Vector2, ground_normal: Vector3) -> void:
	var up: Vector3 = ground_normal.normalized()
	var head: Vector3 = Vector3(fall.x, 0.0, fall.y)
	head -= up * head.dot(up)
	if head.length_squared() < MIN_DIRECTION_SQUARED:
		head = up.cross(Vector3.RIGHT)
	head = head.normalized()
	_body_material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	_body.transform = Transform3D(
		Basis(head.cross(up), head, up), up * LYING_LIFT - head * (height * 0.5)
	)


# Two quads side by side: the fill on the left and the empty part on the
# right. They never overlap, so there is nothing to z-fight.
func _build_hp_bar() -> void:
	_hp_fill_mesh = QuadMesh.new()
	_hp_fill_material = _unshaded(Color.WHITE)
	_hp_fill_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_fill = MeshInstance3D.new()
	_hp_fill.mesh = _hp_fill_mesh
	_hp_fill.material_override = _hp_fill_material
	_hp_empty_mesh = QuadMesh.new()
	var empty_material: StandardMaterial3D = _unshaded(HP_EMPTY_COLOR)
	empty_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_empty = MeshInstance3D.new()
	_hp_empty.mesh = _hp_empty_mesh
	_hp_empty.material_override = empty_material
	_hp_bar = Node3D.new()
	_hp_bar.position = Vector3(0.0, height + HP_BAR_LIFT, 0.0)
	_hp_bar.visible = false
	_hp_bar.add_child(_hp_fill)
	_hp_bar.add_child(_hp_empty)
	add_child(_hp_bar)
	_update_hp_bar()


# Mesh offsets are in the billboard's own frame, so "left" stays screen-left
# however the camera turns.
func _update_hp_bar() -> void:
	var fraction: float = clampf(float(_hp) / float(_max_hp), 0.0, 1.0)
	var fill_width: float = HP_BAR_WIDTH * fraction
	var empty_width: float = HP_BAR_WIDTH - fill_width
	_hp_fill.visible = fill_width > 0.0
	_hp_empty.visible = empty_width > 0.0
	if _hp_fill.visible:
		_hp_fill_mesh.size = Vector2(fill_width, HP_BAR_HEIGHT)
		_hp_fill_mesh.center_offset = Vector3((fill_width - HP_BAR_WIDTH) * 0.5, 0.0, 0.0)
	if _hp_empty.visible:
		_hp_empty_mesh.size = Vector2(empty_width, HP_BAR_HEIGHT)
		_hp_empty_mesh.center_offset = Vector3(fill_width * 0.5, 0.0, 0.0)
	_hp_fill_material.albedo_color = Color.from_hsv(
		fraction * HP_HUE_FULL, HP_FILL_SATURATION, HP_FILL_VALUE
	)


# A camera-facing label, about 0.25 m tall so a name spans roughly one unit
# spacing, hidden beyond LABEL_RANGE.
static func _make_label(text: String, color: Color) -> Label3D:
	var label: Label3D = Label3D.new()
	label.text = text
	label.modulate = color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.008
	label.font_size = 32
	label.outline_size = 8
	label.no_depth_test = true
	label.visibility_range_end = LABEL_RANGE
	return label


static func _unshaded(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material
