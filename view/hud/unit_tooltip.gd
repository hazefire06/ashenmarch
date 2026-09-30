class_name UnitTooltip
extends PanelContainer
## Hover panel next to the cursor describing the unit under it, either side,
## living or dead: name and side, hit points and activity, kills, and the
## veterancy-adjusted melee numbers, and for archers and grenadiers their
## ammunition and special. Hidden when the cursor is over nothing or
## over another HUD control. It never takes mouse input, so it can't block a
## click. Reads the World; never writes it.

## Panel offset from the cursor, in pixels, and the gap kept to the window edge.
const CURSOR_OFFSET: Vector2 = Vector2(18.0, 22.0)
const SCREEN_MARGIN: float = 4.0
## Permille per percentage point.
const PERMILLE_PER_PERCENT: int = 10

var _controller: SelectionController
var _world: World
var _label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visible = false
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)


## The controller picks the unit under the cursor (SelectionController.unit_at).
func setup(controller: SelectionController, world: World) -> void:
	_controller = controller
	_world = world


## The tooltip text for a unit. A living unit gets:
##   Shieldman (Light)
##   HP 64/100 · Attacking
##   Kills 3
##   Accuracy 86% (+6 from kills)
##   Attack rate +16% · Speed +0%
## A unit with a ranged attack adds its ammunition, and its special if it has
## one:
##   Arrows: unlimited
##   Fire arrow: 1        (or "Fire arrow: nocked", "Satchels: 3")
## Its activity reads "Shooting" while it shoots and "Bombarding" while it
## holds a ground attack order. A dead unit gets just its name, "dead", and
## its kills. Percentages are rounded to the nearest point.
##
## catalog names the ammunition by its projectile's display name; without
## one, the projectile's id stands in.
static func describe(unit: Unit, catalog: UnitCatalog = null) -> String:
	var header: String = "%s (%s)" % [
		unit.type.display_name, UnitType.Faction.keys()[unit.faction].capitalize()
	]
	if not unit.is_alive():
		return "%s — dead\nKills %d" % [header, unit.kills]
	var accuracy: String = "Accuracy %d%%" % _percent(Veterancy.melee_accuracy(unit))
	if Veterancy.accuracy_bonus(unit) > 0:
		accuracy += " (+%d from kills)" % _percent(Veterancy.accuracy_bonus(unit))
	var lines: PackedStringArray = PackedStringArray([
		header,
		"HP %d/%d · %s" % [unit.hp, unit.type.max_hp, _activity(unit)],
		"Kills %d" % unit.kills,
		accuracy,
		"Attack rate +%d%% · Speed +%d%%" % [
			_percent(Veterancy.attack_rate_bonus(unit)), _percent(Veterancy.speed_bonus(unit))
		],
	])
	if unit.type.has_ranged():
		lines.append(_ammo_line(unit, catalog))
		if unit.type.special_ability != UnitType.Special.NONE:
			lines.append(_special_line(unit))
	return "\n".join(lines)


func _process(_delta: float) -> void:
	if _controller == null:
		return
	var unit: Unit = _hovered_unit()
	if unit == null:
		visible = false
		return
	var text: String = describe(unit, _world.catalog)
	if text != _label.text:
		_label.text = text
		# Shrink back to fit: a container never shrinks by itself.
		reset_size()
	_place(get_viewport().get_mouse_position())
	visible = true


# The unit under the mouse, or null if there is none or the mouse is over a
# HUD control (the control bar, the overhead map). Controls that ignore the
# mouse, like the selection layer and this panel, don't count.
func _hovered_unit() -> Unit:
	var viewport: Viewport = get_viewport()
	if viewport.gui_get_hovered_control() != null:
		return null
	var unit_id: int = _controller.unit_at(viewport.get_mouse_position(), false)
	return _world.get_unit(unit_id) if unit_id >= 0 else null


# Below and right of the cursor, pushed back inside the window at its edges.
func _place(mouse: Vector2) -> void:
	var limit: Vector2 = get_viewport_rect().size - size - Vector2.ONE * SCREEN_MARGIN
	position = (mouse + CURSOR_OFFSET).min(limit).max(Vector2.ONE * SCREEN_MARGIN)


# What the unit is doing: its state, except that a unit holding a ground
# attack order and not walking is bombarding.
static func _activity(unit: Unit) -> String:
	var bombarding: bool = unit.order == Unit.Order.GROUND_ATTACK and (
		unit.state == Unit.State.SHOOTING or unit.state == Unit.State.IDLE
	)
	return "Bombarding" if bombarding else Unit.State.keys()[unit.state].capitalize()


# "Arrows: unlimited" or "Arrows: 12": the projectile's display name, plural.
static func _ammo_line(unit: Unit, catalog: UnitCatalog) -> String:
	var ammo: String = "unlimited" if unit.ammo_left < 0 else str(unit.ammo_left)
	return "%ss: %s" % [_projectile_name(unit.type.ranged_projectile, catalog), ammo]


# "Satchels: 3", "Fire arrow: 1", or "Fire arrow: nocked" once readied.
static func _special_line(unit: Unit) -> String:
	if unit.type.special_ability == UnitType.Special.SATCHEL:
		return "Satchels: %d" % unit.special_left
	return "Fire arrow: %s" % ["nocked" if unit.fire_nocked else str(unit.special_left)]


static func _projectile_name(projectile_id: StringName, catalog: UnitCatalog) -> String:
	var type: ProjectileType = catalog.find_projectile(projectile_id) if catalog != null else null
	return type.display_name if type != null else String(projectile_id).capitalize()


static func _percent(permille: int) -> int:
	return FixedMath.div_round(permille, PERMILLE_PER_PERCENT)
