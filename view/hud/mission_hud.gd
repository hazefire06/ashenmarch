class_name MissionHud
extends Control
## The mission at a glance: its message line (the text a SET_OBJECTIVE action
## last set: a hint, a new task) at the top centre of the screen, and once the
## mission is decided a Victory, Defeat or (a skirmish nobody won) Draw banner
## in the middle. The list of
## objectives and how each stands is the ObjectivePanel's. Hidden in a world
## with no mission. MainView calls show_world after every step; the labels only
## change when the text does. Reads the World; never writes it, and never takes
## mouse input, so it can't block a click.

## Pixels from the top of the screen to the objective. The stats label owns
## the top-left corner and its two lines run into the middle, so the
## objective sits below them.
const OBJECTIVE_TOP: float = 64.0
const OBJECTIVE_FONT_SIZE: int = 22
const BANNER_FONT_SIZE: int = 96
const OUTLINE_SIZE: int = 8
const OBJECTIVE_COLOR: Color = Color(1.0, 0.95, 0.7)
const VICTORY_COLOR: Color = Color(0.6, 1.0, 0.55)
const DEFEAT_COLOR: Color = Color(1.0, 0.4, 0.35)
const DRAW_COLOR: Color = MenuKit.WARN_COLOR
const OUTLINE_COLOR: Color = Color(0.05, 0.05, 0.05, 0.9)

var _objective: Label
var _banner: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	_objective = _make_label(OBJECTIVE_FONT_SIZE, OBJECTIVE_COLOR)
	_objective.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_objective.offset_top = OBJECTIVE_TOP
	_objective.offset_bottom = OBJECTIVE_TOP + OBJECTIVE_FONT_SIZE * 1.6
	_banner = _make_label(BANNER_FONT_SIZE, VICTORY_COLOR)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


## What the banner says for an outcome: "Victory", "Defeat", "Draw", or "" while
## the mission is still being decided.
static func banner_text(outcome: MissionRuntime.Outcome) -> String:
	match outcome:
		MissionRuntime.Outcome.WON:
			return "Victory"
		MissionRuntime.Outcome.LOST:
			return "Defeat"
		MissionRuntime.Outcome.DRAW:
			return "Draw"
	return ""


## The banner's color for an outcome: green for a win, red for a loss, amber for
## a draw.
static func banner_color(outcome: MissionRuntime.Outcome) -> Color:
	match outcome:
		MissionRuntime.Outcome.LOST:
			return DEFEAT_COLOR
		MissionRuntime.Outcome.DRAW:
			return DRAW_COLOR
	return VICTORY_COLOR


## Shows the world's mission as it is now: the objective, and the banner once
## there is an outcome. Hides itself when the world has no mission.
func show_world(world: World) -> void:
	var mission: MissionRuntime = world.mission
	visible = mission != null
	if mission == null:
		_set_text(_objective, "")
		_set_text(_banner, "")
		return
	_set_text(_objective, mission.objective)
	var banner: String = banner_text(mission.outcome)
	_set_text(_banner, banner)
	_banner.add_theme_color_override("font_color", banner_color(mission.outcome))


## The objective as drawn; empty when there is none to show.
func shown_objective() -> String:
	return _objective.text


## The banner as drawn; empty until the mission has an outcome.
func shown_banner() -> String:
	return _banner.text


## The color the banner is drawn in.
func shown_banner_color() -> Color:
	return _banner.get_theme_color("font_color")


func _make_label(font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	add_child(label)
	return label


# Only touches the label when the text changed, so a long mission isn't
# re-laying-out its text 30 times a second.
func _set_text(label: Label, text: String) -> void:
	if label.text != text:
		label.text = text
