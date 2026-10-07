class_name SkirmishMenu
extends MenuScreen
## The skirmish setup and army builder, one screen.
## - Left: what is played, as radio rows: the map, the mode, the time limit, the
##   budget, the side, which start the player takes (A or B) and the enemy's
##   army (Random, or one of the templates for the other side).
## - Right: the player's army. A row for every unit type the player's side can
##   buy (name, role, hp, cost, a - and + around the count, the points it
##   costs), the points left and the unit count against Army.MAX_UNITS, a Fill
##   button for each of the side's templates, and Clear.
## - Start is on only for an army that validates (Army.validate): at least one
##   unit, no more than MAX_UNITS, inside the budget. + isn't stopped at the
##   budget: it goes red and the screen says why Start is off, because a smaller
##   budget picked later keeps the army too.
## Choosing the other side puts the Balanced army of that side in place of the
## one being built (the old one is of the wrong side); changing the budget keeps
## the counts. The enemy's army is not built here: Start hands the App the
## player's half of a SkirmishSetup and the enemy choice (a template id, or
## "random"), and the App fills the enemy's army and picks the seed.
##
## It reads nothing itself: the App hands it the catalogs and what was
## remembered (GameSettings.skirmish_choice), and takes back current_choice()
## to remember. A remembered value that no longer fits (a map that is gone, a
## budget that is no longer offered, an army of the wrong side or too dear) is
## ignored on its own, the rest kept.

## Start was pressed: the player's half of the setup (armies[1] is null; the
## App makes it) and the enemy choice, a template id or RANDOM_AI.
signal start_pressed(setup: SkirmishSetup, ai_choice: StringName)
## Back or Esc.
signal back_pressed

## The enemy choice that leaves the template to the App's dice.
const RANDOM_AI: StringName = &"random"
## By SkirmishRules.Mode, and a line saying what each scores.
const MODE_NAMES: PackedStringArray = ["Body Count", "King of the Hill", "Capture the Flags"]
const MODE_NOTES: PackedStringArray = [
	"Most enemy units killed when time runs out.",
	"The longest time alone on the central hill when time runs out.",
	"The most flags owned when time runs out.",
]
## By UnitType.Faction and UnitType.Role.
const SIDE_NAMES: PackedStringArray = ["Light", "Dark"]
const ROLE_NAMES: PackedStringArray = ["Melee", "Ranged", "Support"]
const SPAWN_NAMES: PackedStringArray = ["A", "B"]
const ELIMINATION_NOTE: String = "A side with no units left loses at once, in every mode."
## The army grid's columns: unit, role, hp, cost, -, count, +, points.
const COLUMN_NAMES: Array[String] = ["Unit", "Role", "HP", "Cost", "", "Count", "", "Total"]
const COLUMNS: int = 8
## A radio button's least width, the width of a row's heading, and a count's.
const RADIO_WIDTH: float = 80.0
const HEADING_WIDTH: float = 100.0
const COUNT_WIDTH: float = 32.0
const STEP_WIDTH: float = 38.0

var _skirmish: SkirmishCatalog
var _catalog: UnitCatalog
var _map_id: StringName = &""
var _mode: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
var _minutes: int = 0
var _budget: int = 0
var _side: UnitType.Faction = UnitType.Faction.LIGHT
var _spawn: int = 0
var _ai_choice: StringName = RANDOM_AI
var _army: Army

var _map_buttons: Array[Button] = []
var _mode_buttons: Array[Button] = []
var _time_buttons: Array[Button] = []
var _budget_buttons: Array[Button] = []
var _side_buttons: Array[Button] = []
var _spawn_buttons: Array[Button] = []
var _ai_buttons: Array[Button] = []
var _ai_row: HFlowContainer
var _mode_note: Label
var _builder: VBoxContainer
var _buyable: Array[UnitType] = []
var _plus: Dictionary[StringName, Button] = {}
var _minus: Dictionary[StringName, Button] = {}
var _counts: Dictionary[StringName, Label] = {}
var _subtotals: Dictionary[StringName, Label] = {}
var _fills: Array[Button] = []
var _points: Label
var _units: Label
var _hint: Label
var _start: Button


## Builds the screen. `remembered` is GameSettings.skirmish_choice (or the
## last setup's choice): any key may be missing or stale.
func setup(skirmish: SkirmishCatalog, catalog: UnitCatalog, remembered: Dictionary = {}) -> void:
	_skirmish = skirmish
	_catalog = catalog
	_apply_remembered(remembered)
	_build()
	if is_inside_tree():
		_focus_default()


## Everything chosen, in the form GameSettings remembers (keys as
## GameSettings.SKIRMISH_INT_KEYS and SKIRMISH_STRING_KEYS): the map and enemy
## choice by id, the army as text, the rest as whole numbers.
func current_choice() -> Dictionary:
	return _pack(_map_id, _mode, _minutes, _budget, _side, _spawn, _ai_choice, _army, _catalog)


## A copy of the army being built.
func army() -> Army:
	return _army.copy()


## Points left of the budget; negative when over.
func points_left() -> int:
	return _budget - _army.cost(_catalog)


## True if Start would go ahead: a map and an army that validates.
func can_start() -> bool:
	return _skirmish.skirmish_map(_map_id) != null and _army.validate(_catalog, _budget).is_empty()


## The choice a finished setup stands for, in the form current_choice gives and
## GameSettings remembers: how the App remembers the setup it launched, and
## what Change army opens the screen on. `ai_choice` is what the player picked
## for the enemy (a template id or RANDOM_AI), not the template it resolved to.
static func choice_of(
	played: SkirmishSetup, ai_choice: StringName, catalog: UnitCatalog
) -> Dictionary:
	@warning_ignore("integer_division")
	var minutes: int = played.rules.time_limit_ticks / (60 * World.TICK_RATE)
	return _pack(
		played.map.id, played.rules.mode, minutes, played.budget, played.player_faction(),
		played.player_spawn, ai_choice, played.armies[0], catalog
	)


## An army as text, "shieldman:10,longbow:4": the catalog's order, so the same
## army is always the same text. A type the catalog doesn't know is written
## too (last, by id), so reading it back refuses the army rather than
## dropping the unit.
static func army_to_text(army_to_write: Army, catalog: UnitCatalog) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var written: Dictionary[StringName, bool] = {}
	for type: UnitType in catalog.types:
		if army_to_write.count_of(type.id) > 0:
			parts.append("%s:%d" % [type.id, army_to_write.count_of(type.id)])
			written[type.id] = true
	var rest: Array[String] = []
	for type_id: StringName in army_to_write.counts:
		if not written.has(type_id):
			rest.append("%s:%d" % [type_id, army_to_write.counts[type_id]])
	rest.sort()
	parts.append_array(PackedStringArray(rest))
	return ",".join(parts)


## An army from that text, on `side`; null if the text isn't of that form (a
## count that isn't a positive whole number, a type given twice). Whether the
## types exist, are the side's and fit a budget is Army.validate's to say.
static func army_from_text(text: String, side: UnitType.Faction) -> Army:
	var parsed: Army = Army.new(side)
	if text.strip_edges().is_empty():
		return parsed
	for part: String in text.split(","):
		var bits: PackedStringArray = part.strip_edges().split(":")
		if bits.size() != 2 or bits[0].is_empty() or not bits[1].is_valid_int():
			return null
		var type_id: StringName = StringName(bits[0])
		var n: int = bits[1].to_int()
		if n <= 0 or parsed.counts.has(type_id):
			return null
		parsed.set_count(type_id, n)
	return parsed


## The name of a mode.
static func mode_name(mode: SkirmishRules.Mode) -> String:
	if mode < 0 or mode >= MODE_NAMES.size():
		return "Mode %d" % mode
	return MODE_NAMES[mode]


## The name of a side ("Light", "Dark").
static func side_name(side: int) -> String:
	if side < 0 or side >= SIDE_NAMES.size():
		return "Side %d" % side
	return SIDE_NAMES[side]


func _focus_default() -> void:
	if _start == null:
		return
	if not _start.disabled:
		_focus(_start)
	elif not _fills.is_empty():
		_focus(_fills[0])


func _cancel() -> bool:
	back_pressed.emit()
	return true


# --- what was remembered ---------------------------------------------------------


# Sets every choice from the remembered values where they still fit, else from
# the catalog's defaults.
func _apply_remembered(remembered: Dictionary) -> void:
	_map_id = _skirmish.maps[0].id if not _skirmish.maps.is_empty() and _skirmish.maps[0] != null else &""
	var map_id: StringName = StringName(_text_of(remembered, "map"))
	if _skirmish.skirmish_map(map_id) != null:
		_map_id = map_id
	var mode: int = _number_of(remembered, "mode", SkirmishRules.Mode.BODY_COUNT)
	_mode = (mode if mode >= 0 and mode < SkirmishRules.Mode.size() else SkirmishRules.Mode.BODY_COUNT) as SkirmishRules.Mode
	var minutes: int = _number_of(remembered, "minutes", _skirmish.default_time_limit_minutes)
	_minutes = minutes if _skirmish.time_limits_minutes.has(minutes) else _skirmish.default_time_limit_minutes
	var budget: int = _number_of(remembered, "budget", _skirmish.default_budget)
	_budget = budget if _skirmish.budgets.has(budget) else _skirmish.default_budget
	var side: int = _number_of(remembered, "side", UnitType.Faction.LIGHT)
	_side = (side if side >= 0 and side < UnitType.Faction.size() else UnitType.Faction.LIGHT) as UnitType.Faction
	var spawn: int = _number_of(remembered, "start", 0)
	_spawn = spawn if spawn == 0 or spawn == 1 else 0
	_ai_choice = RANDOM_AI
	var ai_choice: StringName = StringName(_text_of(remembered, "ai_choice"))
	if _is_enemy_choice(ai_choice):
		_ai_choice = ai_choice
	_army = null
	if _number_of(remembered, "army_side", -1) == _side:
		var remembered_army: Army = army_from_text(_text_of(remembered, "army"), _side)
		if remembered_army != null and remembered_army.validate(_catalog, _budget).is_empty():
			_army = remembered_army
	if _army == null:
		_army = _balanced_army(_side)


static func _number_of(values: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = values.get(key)
	return value if value is int else fallback


static func _text_of(values: Dictionary, key: String) -> String:
	var value: Variant = values.get(key)
	return value if value is String else ""


# The Balanced army of a side at the budget: <side>_balanced, or the side's
# first template if a catalog has no such id, or nothing.
func _balanced_army(side: UnitType.Faction) -> Army:
	var chosen: ArmyTemplate = _skirmish.template(StringName("%s_balanced" % side_name(side).to_lower()))
	if chosen == null or chosen.faction != side:
		var offered: Array[ArmyTemplate] = _skirmish.templates_for(side)
		chosen = offered[0] if not offered.is_empty() else null
	return chosen.fill(_budget, _catalog) if chosen != null else Army.new(side)


# True for Random, or a template of the side the enemy is on.
func _is_enemy_choice(choice: StringName) -> bool:
	if choice == RANDOM_AI:
		return true
	var found: ArmyTemplate = _skirmish.template(choice)
	return found != null and found.faction == _enemy_side()


func _enemy_side() -> UnitType.Faction:
	return (1 - _side) as UnitType.Faction


static func _pack(
	map_id: StringName, mode: SkirmishRules.Mode, minutes: int, budget: int, side: UnitType.Faction,
	spawn: int, ai_choice: StringName, army_in: Army, catalog: UnitCatalog
) -> Dictionary:
	return {
		"map": String(map_id),
		"mode": int(mode),
		"minutes": minutes,
		"budget": budget,
		"side": int(side),
		"start": spawn,
		"ai_choice": String(ai_choice),
		"army": army_to_text(army_in, catalog),
		"army_side": int(army_in.faction),
	}


# --- building the screen ---------------------------------------------------------


func _build() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 32)
	add_child(margin)
	var page: VBoxContainer = VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	margin.add_child(page)
	page.add_child(MenuKit.title("Skirmish"))
	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	_build_choices(body)
	_build_army_column(body)
	var footer: HBoxContainer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	page.add_child(footer)
	var back: Button = MenuKit.button("Back", "Back", 160.0)
	back.pressed.connect(func() -> void: back_pressed.emit())
	footer.add_child(back)
	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_start = MenuKit.button("Start", "Start skirmish", 220.0)
	_start.pressed.connect(_on_start_pressed)
	footer.add_child(_start)
	_rebuild_army()
	_refresh()


# The left column: a heading and a row of toggle buttons for each choice.
func _build_choices(body: HBoxContainer) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	scroll.size_flags_stretch_ratio = 1.0
	body.add_child(scroll)
	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	scroll.add_child(column)

	var map_names: PackedStringArray = PackedStringArray()
	var map_labels: PackedStringArray = PackedStringArray()
	var map_at: int = -1
	for i: int in _skirmish.maps.size():
		map_names.append("Map_%s" % _skirmish.maps[i].id)
		map_labels.append(_skirmish.maps[i].display_name)
		if _skirmish.maps[i].id == _map_id:
			map_at = i
	_map_buttons = _radio_row(column, "Map", map_names, map_labels, map_at, _pick_map)

	var mode_names: PackedStringArray = PackedStringArray()
	for i: int in SkirmishRules.Mode.size():
		mode_names.append("Mode%d" % i)
	_mode_buttons = _radio_row(column, "Mode", mode_names, MODE_NAMES, _mode, _pick_mode)
	_mode_note = MenuKit.paragraph(MODE_NOTES[_mode], 14, MenuKit.MUTED_COLOR)
	_mode_note.name = "ModeNote"
	column.add_child(_mode_note)

	var time_names: PackedStringArray = PackedStringArray()
	var time_labels: PackedStringArray = PackedStringArray()
	for minutes: int in _skirmish.time_limits_minutes:
		time_names.append("Time%d" % minutes)
		time_labels.append("%d min" % minutes)
	_time_buttons = _radio_row(
		column, "Time limit", time_names, time_labels,
		Array(_skirmish.time_limits_minutes).find(_minutes), _pick_time
	)

	var budget_names: PackedStringArray = PackedStringArray()
	var budget_labels: PackedStringArray = PackedStringArray()
	for points: int in _skirmish.budgets:
		budget_names.append("Budget%d" % points)
		budget_labels.append("%d" % points)
	_budget_buttons = _radio_row(
		column, "Budget", budget_names, budget_labels,
		Array(_skirmish.budgets).find(_budget), _pick_budget
	)

	_side_buttons = _radio_row(column, "Play as", ["Side0", "Side1"], SIDE_NAMES, _side, _pick_side)
	_spawn_buttons = _radio_row(column, "Start", ["Spawn0", "Spawn1"], SPAWN_NAMES, _spawn, _pick_spawn)
	_ai_row = _choice_line(column, "Enemy army")
	_rebuild_enemy_choices()
	var elimination: Label = MenuKit.paragraph(ELIMINATION_NOTE, 14, MenuKit.MUTED_COLOR)
	elimination.name = "EliminationNote"
	column.add_child(elimination)


# The right column: the army builder, rebuilt whenever the side changes.
func _build_army_column(body: HBoxContainer) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	scroll.size_flags_stretch_ratio = 1.0
	body.add_child(scroll)
	_builder = VBoxContainer.new()
	_builder.name = "Builder"
	_builder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_builder.add_theme_constant_override("separation", 10)
	scroll.add_child(_builder)


# The army grid, the totals and the Fill buttons for the side being played.
func _rebuild_army() -> void:
	MenuKit.clear(_builder)
	_plus.clear()
	_minus.clear()
	_counts.clear()
	_subtotals.clear()
	_fills.clear()
	_buyable.clear()
	for type: UnitType in _catalog.types:
		if type.faction == _side and type.cost > 0:
			_buyable.append(type)
	var heading: Label = MenuKit.label(
		"Your army: %s" % side_name(_side), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	heading.name = "ArmyHeading"
	_builder.add_child(heading)
	var grid: GridContainer = GridContainer.new()
	grid.name = "ArmyGrid"
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	_builder.add_child(grid)
	for i: int in COLUMN_NAMES.size():
		var header: Label = MenuKit.label(COLUMN_NAMES[i], 14, MenuKit.MUTED_COLOR)
		if i == COLUMN_NAMES.size() - 1:
			header.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		elif COLUMN_NAMES[i] == "Count":
			header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		grid.add_child(header)
	for type: UnitType in _buyable:
		_add_unit_row(grid, type)
	_points = MenuKit.label("", MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR)
	_points.name = "PointsLeft"
	_builder.add_child(_points)
	_units = MenuKit.label("")
	_units.name = "UnitCount"
	_builder.add_child(_units)
	_hint = MenuKit.paragraph("", 14, MenuKit.WARN_COLOR)
	_hint.name = "StartHint"
	_builder.add_child(_hint)
	var fills: HFlowContainer = _new_row()
	fills.name = "FillRow"
	_builder.add_child(fills)
	for template: ArmyTemplate in _skirmish.templates_for(_side):
		var fill: Button = MenuKit.button("Fill_%s" % template.id, "Fill: %s" % template.display_name, 150.0)
		fill.pressed.connect(_fill_from.bind(template))
		fills.add_child(fill)
		_fills.append(fill)
	var clear: Button = MenuKit.button("Clear", "Clear", 100.0)
	clear.pressed.connect(_clear_army)
	fills.add_child(clear)


# One unit type's row: name, role, hp, cost, - count +, and its points.
func _add_unit_row(grid: GridContainer, type: UnitType) -> void:
	var id: StringName = type.id
	grid.add_child(MenuKit.label(type.display_name, MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
	grid.add_child(MenuKit.label(ROLE_NAMES[type.role]))
	grid.add_child(MenuKit.label(str(type.max_hp)))
	grid.add_child(MenuKit.label(str(type.cost)))
	var minus: Button = MenuKit.button("Minus_%s" % id, "-", STEP_WIDTH)
	minus.pressed.connect(_step.bind(id, -1))
	grid.add_child(minus)
	_minus[id] = minus
	var count: Label = MenuKit.label("0", MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR)
	count.name = "Count_%s" % id
	count.custom_minimum_size.x = COUNT_WIDTH
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grid.add_child(count)
	_counts[id] = count
	var plus: Button = MenuKit.button("Plus_%s" % id, "+", STEP_WIDTH)
	plus.pressed.connect(_step.bind(id, 1))
	grid.add_child(plus)
	_plus[id] = plus
	var subtotal: Label = MenuKit.label("0")
	subtotal.name = "Subtotal_%s" % id
	subtotal.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	grid.add_child(subtotal)
	_subtotals[id] = subtotal


# --- radio rows ------------------------------------------------------------------


static func _new_row() -> HFlowContainer:
	var row: HFlowContainer = HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	return row


# A heading with a row that wraps beside it: returns the row, for buttons.
func _choice_line(column: VBoxContainer, heading: String) -> HFlowContainer:
	var line: HBoxContainer = HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	column.add_child(line)
	var name_label: Label = MenuKit.label(heading, 14, MenuKit.MUTED_COLOR)
	name_label.custom_minimum_size.x = HEADING_WIDTH
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(name_label)
	var row: HFlowContainer = _new_row()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(row)
	return row


# A heading and a row of toggle buttons, `selected` on; each press calls
# on_pick(index). The press, not the toggle, is what counts: the pick sets
# every button of the row (_select_in), so one tapped twice stays on and a
# test's emitted press looks like a click.
func _radio_row(
	column: VBoxContainer, heading: String, node_names: PackedStringArray, texts: PackedStringArray,
	selected: int, on_pick: Callable
) -> Array[Button]:
	return _fill_radio_row(_choice_line(column, heading), node_names, texts, selected, on_pick)


func _fill_radio_row(
	row: HFlowContainer, node_names: PackedStringArray, texts: PackedStringArray, selected: int,
	on_pick: Callable
) -> Array[Button]:
	var buttons: Array[Button] = []
	for i: int in texts.size():
		var b: Button = MenuKit.button(node_names[i], texts[i], RADIO_WIDTH)
		b.toggle_mode = true
		b.set_pressed_no_signal(i == selected)
		MenuKit.style_selected(b)
		_match_margins(b)
		b.pressed.connect(on_pick.bind(i))
		row.add_child(b)
		buttons.append(b)
	return buttons


# MenuKit.style_selected pads a button more than the default look does, and a
# button's minimum size is not worked out again when it is pressed, so a selected
# button in a full row clipped its own text. Give the selected look the margins
# of the unselected one: the row then neither jumps nor clips.
static func _match_margins(button: Button) -> void:
	var normal: StyleBox = button.get_theme_stylebox("normal")
	for style_name: String in ["pressed", "hover_pressed"]:
		var style: StyleBox = button.get_theme_stylebox(style_name)
		for side: int in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			style.set_content_margin(side as Side, normal.get_margin(side as Side))


static func _select_in(buttons: Array[Button], index: int) -> void:
	for i: int in buttons.size():
		buttons[i].set_pressed_no_signal(i == index)


# The enemy's choices follow the side: Random, and the templates of the other
# side.
func _rebuild_enemy_choices() -> void:
	MenuKit.clear(_ai_row)
	var node_names: PackedStringArray = PackedStringArray(["Ai_random"])
	var texts: PackedStringArray = PackedStringArray(["Random"])
	var selected: int = 0
	for template: ArmyTemplate in _skirmish.templates_for(_enemy_side()):
		node_names.append("Ai_%s" % template.id)
		texts.append(template.display_name)
		if template.id == _ai_choice:
			selected = texts.size() - 1
	_ai_buttons = _fill_radio_row(_ai_row, node_names, texts, selected, _pick_enemy)


# --- what the buttons do ---------------------------------------------------------


func _pick_map(index: int) -> void:
	_map_id = _skirmish.maps[index].id
	_select_in(_map_buttons, index)


func _pick_mode(index: int) -> void:
	_mode = index as SkirmishRules.Mode
	_mode_note.text = MODE_NOTES[index]
	_select_in(_mode_buttons, index)


func _pick_time(index: int) -> void:
	_minutes = _skirmish.time_limits_minutes[index]
	_select_in(_time_buttons, index)


# The counts stay: a budget too small for them only turns Start off.
func _pick_budget(index: int) -> void:
	_budget = _skirmish.budgets[index]
	_select_in(_budget_buttons, index)
	_refresh()


# The other side is a different army and a different enemy: the Balanced army
# of the new side, and Random, since the old choice was one of the new side's
# own templates.
func _pick_side(index: int) -> void:
	_select_in(_side_buttons, index)
	if index == _side:
		return
	_side = index as UnitType.Faction
	_ai_choice = RANDOM_AI
	_army = _balanced_army(_side)
	_rebuild_enemy_choices()
	_rebuild_army()
	_refresh()


func _pick_spawn(index: int) -> void:
	_spawn = index
	_select_in(_spawn_buttons, index)


func _pick_enemy(index: int) -> void:
	var offered: Array[ArmyTemplate] = _skirmish.templates_for(_enemy_side())
	_ai_choice = RANDOM_AI if index == 0 else offered[index - 1].id
	_select_in(_ai_buttons, index)


# + or - on one unit type. Nothing stops + at the budget (the points go red);
# - stops at none.
func _step(type_id: StringName, delta: int) -> void:
	_army.set_count(type_id, _army.count_of(type_id) + delta)
	_refresh()
	# A - that has just run out is greyed, which would leave the keyboard on a
	# dead button: move to the + beside it.
	if _minus[type_id].disabled and _minus[type_id].has_focus():
		_plus[type_id].grab_focus()


func _fill_from(template: ArmyTemplate) -> void:
	_army = template.fill(_budget, _catalog)
	_refresh()


func _clear_army() -> void:
	_army = Army.new(_side)
	_refresh()


func _on_start_pressed() -> void:
	# A press emitted from code ignores `disabled`; the screen doesn't.
	if not can_start():
		return
	var made: SkirmishSetup = SkirmishSetup.new()
	made.map = _skirmish.skirmish_map(_map_id)
	made.rules = SkirmishRules.for_map(made.map, _mode, _minutes, _side)
	made.budget = _budget
	made.player_spawn = _spawn
	made.armies = [_army.copy(), null]
	start_pressed.emit(made, _ai_choice)


# Brings every number on the right in line with the army: counts, points,
# unit total, why Start is off, and Start itself.
func _refresh() -> void:
	for type: UnitType in _buyable:
		var n: int = _army.count_of(type.id)
		_counts[type.id].text = str(n)
		_subtotals[type.id].text = str(n * type.cost)
		_minus[type.id].disabled = n == 0
	var left: int = points_left()
	_points.text = "Points left: %d" % left
	_points.add_theme_color_override("font_color", MenuKit.BAD_COLOR if left < 0 else MenuKit.TEXT_COLOR)
	var total: int = _army.size()
	_units.text = "Units: %d / %d" % [total, Army.MAX_UNITS]
	_units.add_theme_color_override(
		"font_color", MenuKit.BAD_COLOR if total > Army.MAX_UNITS else MenuKit.BODY_COLOR
	)
	var problems: PackedStringArray = _army.validate(_catalog, _budget)
	if _skirmish.skirmish_map(_map_id) == null:
		problems.append("there is no map to play on")
	_hint.text = "" if problems.is_empty() else problems[0].substr(0, 1).to_upper() + problems[0].substr(1) + "."
	_start.disabled = not problems.is_empty()
