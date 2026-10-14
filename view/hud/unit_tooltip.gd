class_name UnitTooltip
extends PanelContainer
## Hover panel next to the cursor describing the unit under it, either side,
## living or dead (UnitInfo.lines: name and side, hit points and activity,
## kills, the veterancy-adjusted numbers, status effects, ammunition,
## special, and what it carries), or failing that the herb plant or loose
## object under it (UnitInfo.describe_thing). Hidden when the cursor is over
## nothing or over another HUD control. It never takes mouse input, so it
## can't block a click. It follows whichever pointer is in use, the mouse or
## the pad's cursor (Pointer). Reads the World; never writes it.

## Panel offset from the cursor, in pixels, and the gap kept to the window edge.
const CURSOR_OFFSET: Vector2 = Vector2(18.0, 22.0)
const SCREEN_MARGIN: float = 4.0

var _controller: SelectionController
var _world: World
var _camera: Camera3D
var _projectiles: ProjectilesView
var _plants: HerbPlantsView
var _label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visible = false
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)


## The controller picks the unit under the cursor (SelectionController.unit_at).
## With a camera, the projectiles and plants views pick the loose object or
## herb plant under it; any of those may be null.
func setup(
	controller: SelectionController, world: World, camera: Camera3D = null,
	projectiles: ProjectilesView = null, plants: HerbPlantsView = null
) -> void:
	_controller = controller
	_world = world
	_camera = camera
	_projectiles = projectiles
	_plants = plants


## The tooltip text for a unit (UnitInfo.lines). catalog names the
## ammunition by its projectile's display name; without one, the
## projectile's id stands in. world adds status effects and errands.
static func describe(unit: Unit, catalog: UnitCatalog = null, world: World = null) -> String:
	return "\n".join(UnitInfo.lines(unit, catalog, world))


func _process(_delta: float) -> void:
	if _controller == null:
		return
	var text: String = _hovered_text()
	if text.is_empty():
		visible = false
		return
	if text != _label.text:
		_label.text = text
		# Shrink back to fit: a container never shrinks by itself.
		reset_size()
	_place(Pointer.position_in(get_viewport()))
	visible = true


# What is under the mouse, described: a unit, else a herb plant or a loose
# object; empty if nothing or if the mouse is over a HUD control (the control
# bar, the overhead map). Controls that ignore the mouse, like the selection
# layer and this panel, don't count.
func _hovered_text() -> String:
	var viewport: Viewport = get_viewport()
	if not Pointer.using_pad() and viewport.gui_get_hovered_control() != null:
		return ""
	var at: Vector2 = Pointer.position_in(viewport)
	var unit_id: int = _controller.unit_at(at, false)
	if unit_id >= 0:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null:
			return describe(unit, _world.catalog, _world)
	if _camera == null:
		return ""
	var thing_id: int = _plants.plant_at(_camera, at) if _plants != null else -1
	if thing_id < 0 and _projectiles != null:
		thing_id = _projectiles.object_at(_camera, at)
	var thing: SimEntity = _world.get_entity(thing_id) if thing_id >= 0 else null
	return UnitInfo.describe_thing(thing) if thing != null else ""


# Below and right of the cursor, pushed back inside the window at its edges.
func _place(mouse: Vector2) -> void:
	var limit: Vector2 = get_viewport_rect().size - size - Vector2.ONE * SCREEN_MARGIN
	position = (mouse + CURSOR_OFFSET).min(limit).max(Vector2.ONE * SCREEN_MARGIN)
