class_name ObjectivePanel
extends PanelContainer
## The mission's objectives, in a panel at the top right: one line for each
## whose state isn't HIDDEN, in the mission's order.
## - "○ text" is active and still to do (cream);
## - "✓ text" is done (green);
## - "✗ text" is failed (red);
## - an optional objective, one the player can win without, ends in "(optional)".
## Hidden while the world has no mission or no objective is on show.
##
## MainView calls show_world after every step. The lines are rebuilt only when
## an OBJECTIVE_STATE event came with that step (or the first time), so a long
## mission isn't re-laying-out its labels 30 times a second. (The message line,
## the mission's SET_OBJECTIVE text, is MissionHud's.) Reads the World; never
## writes it, and never takes mouse input, so it can't block a click.

## Pixels from the top and right of the screen. The stats label owns the
## top-left corner, and the mission's message line runs along the top (MissionHud,
## down to about 100 px) and can be long, so the panel hangs below it.
const MARGIN_TOP: float = 108.0
const MARGIN_RIGHT: float = 12.0
const PANEL_WIDTH: float = 300.0
const FONT_SIZE: int = 18
const TITLE_FONT_SIZE: int = 14
const TITLE: String = "Objectives"
const ACTIVE_MARK: String = "○"
const DONE_MARK: String = "✓"
const FAILED_MARK: String = "✗"
const OPTIONAL_SUFFIX: String = " (optional)"
const ACTIVE_COLOR: Color = Color(1.0, 0.95, 0.7)
const DONE_COLOR: Color = Color(0.6, 1.0, 0.55)
const FAILED_COLOR: Color = Color(1.0, 0.4, 0.35)
const TITLE_COLOR: Color = Color(0.8, 0.8, 0.8)
const BACKDROP_COLOR: Color = Color(0.04, 0.04, 0.05, 0.6)
const OUTLINE_COLOR: Color = Color(0.05, 0.05, 0.05, 0.9)

var _rows: VBoxContainer
var _lines: Array[Label] = []
## False until the first show_world with a mission: that one always builds.
var _built: bool = false
## Which mission the lines were built for, so a new world rebuilds them.
var _shown_mission: MissionRuntime


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE)
	offset_left = -(PANEL_WIDTH + MARGIN_RIGHT)
	offset_right = -MARGIN_RIGHT
	offset_top = MARGIN_TOP
	var backdrop: StyleBoxFlat = StyleBoxFlat.new()
	backdrop.bg_color = BACKDROP_COLOR
	backdrop.set_content_margin_all(8.0)
	backdrop.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", backdrop)
	_rows = VBoxContainer.new()
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rows)
	var title: Label = Label.new()
	title.text = TITLE
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	_rows.add_child(title)


## Brings the panel up to date with the world as it is now. Rebuilds the lines
## the first time, for a different mission, and after any step that changed an
## objective's state; every other call only checks for that. Hides itself when
## the world has no mission or nothing to list.
func show_world(world: World) -> void:
	var mission: MissionRuntime = world.mission
	if mission == null:
		visible = false
		_built = false
		_shown_mission = null
		return
	if not _built or mission != _shown_mission or _state_changed(world):
		_rebuild(mission)
		_built = true
		_shown_mission = mission


## The text of every line on show, in order, with its mark and any suffix.
func line_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for line: Label in _lines:
		out.append(line.text)
	return out


## The color the index-th line on show is drawn in.
func line_color(index: int) -> Color:
	return _lines[index].get_theme_color("font_color")


## The text of objective i as the panel writes it for this state, or "" for a
## hidden one (which has no line).
static func line_text(
	text: String, state: MissionRuntime.ObjectiveState, optional: bool
) -> String:
	var mark: String = ""
	match state:
		MissionRuntime.ObjectiveState.ACTIVE:
			mark = ACTIVE_MARK
		MissionRuntime.ObjectiveState.DONE:
			mark = DONE_MARK
		MissionRuntime.ObjectiveState.FAILED:
			mark = FAILED_MARK
		_:
			return ""
	return "%s %s%s" % [mark, text, OPTIONAL_SUFFIX if optional else ""]


## The color a line in this state is drawn in.
static func state_color(state: MissionRuntime.ObjectiveState) -> Color:
	match state:
		MissionRuntime.ObjectiveState.DONE:
			return DONE_COLOR
		MissionRuntime.ObjectiveState.FAILED:
			return FAILED_COLOR
	return ACTIVE_COLOR


# True if the step just run changed an objective's state (the world clears its
# mission events at the start of each step, and MainView calls after every one).
func _state_changed(world: World) -> bool:
	for event: MissionEvent in world.mission_events:
		if event.kind == MissionEvent.Kind.OBJECTIVE_STATE:
			return true
	return false


func _rebuild(mission: MissionRuntime) -> void:
	for line: Label in _lines:
		_rows.remove_child(line)
		# Nothing of a label's own is running, so it can go at once.
		line.free()
	_lines.clear()
	for i: int in mission.objective_count():
		var state: MissionRuntime.ObjectiveState = mission.objective_state(i)
		var text: String = line_text(mission.objective_text(i), state, mission.objective_optional(i))
		if text.is_empty():
			continue
		var line: Label = Label.new()
		line.text = text
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.custom_minimum_size.x = PANEL_WIDTH - 16.0
		line.add_theme_font_size_override("font_size", FONT_SIZE)
		line.add_theme_color_override("font_color", state_color(state))
		line.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
		line.add_theme_constant_override("outline_size", 4)
		_rows.add_child(line)
		_lines.append(line)
	visible = not _lines.is_empty()
	# Shrink back to fit: a container never shrinks by itself.
	reset_size()
