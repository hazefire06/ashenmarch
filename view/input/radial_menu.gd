class_name RadialMenu
extends Control
## A wheel of choices around the middle of the screen, opened while a pad's
## shoulder button is held (PadController): the stick points at one, and
## letting go chooses it. Pointing nowhere (the stick near the middle) chooses
## nothing. Drawn in code; it never takes input itself.

const RADIUS: float = 150.0
const INNER: float = 46.0
## The stick must be pushed this far to point at a choice.
const POINT_DEADZONE: float = 0.5
const BACK: Color = Color(0.05, 0.05, 0.06, 0.78)
const EDGE: Color = Color(0.92, 0.9, 0.82, 0.55)
const HIGHLIGHT: Color = Color(1.0, 0.92, 0.55, 0.45)
const TEXT: Color = Color(0.95, 0.95, 0.92)

## The choices' labels, clockwise from the top.
var labels: PackedStringArray = PackedStringArray()
## The choice pointed at, or -1.
var selected: int = -1
## A line under the wheel (what the other stick does, say).
var hint: String = ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visible = false


## Shows the wheel with these choices, none pointed at.
func open(choices: PackedStringArray, hint_text: String = "") -> void:
	labels = choices
	hint = hint_text
	selected = -1
	visible = true
	queue_redraw()


## Hides the wheel and returns the choice pointed at (-1 for none).
func close() -> int:
	visible = false
	return selected


## Points the wheel the way the stick is pushed (x right, y down, as a pad
## reports it).
func point(stick: Vector2) -> void:
	var before: int = selected
	selected = choice_for(stick, labels.size())
	if selected != before:
		queue_redraw()


## Which of `count` choices, clockwise from the top, the stick points at; -1
## if it isn't pushed far enough.
static func choice_for(stick: Vector2, count: int) -> int:
	if count <= 0 or stick.length() < POINT_DEADZONE:
		return -1
	# Angle clockwise from up, 0..TAU.
	var angle: float = fposmod(atan2(stick.x, -stick.y), TAU)
	var slice: float = TAU / count
	return int(fposmod(angle + slice * 0.5, TAU) / slice) % count


func _draw() -> void:
	if labels.is_empty():
		return
	var center: Vector2 = size * 0.5
	draw_circle(center, RADIUS, BACK)
	var count: int = labels.size()
	var slice: float = TAU / count
	var font: Font = get_theme_default_font()
	for i: int in count:
		var mid: float = i * slice
		if i == selected:
			var arc: PackedVector2Array = PackedVector2Array([center])
			for step: int in 13:
				var a: float = mid - slice * 0.5 + slice * step / 12.0
				arc.append(center + Vector2(sin(a), -cos(a)) * RADIUS)
			draw_colored_polygon(arc, HIGHLIGHT)
		var edge: float = mid - slice * 0.5
		draw_line(center + Vector2(sin(edge), -cos(edge)) * INNER, center + Vector2(sin(edge), -cos(edge)) * RADIUS, EDGE, 1.0)
		var at: Vector2 = center + Vector2(sin(mid), -cos(mid)) * (INNER + RADIUS) * 0.5
		var text_size: Vector2 = font.get_string_size(labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
		draw_string(font, at - Vector2(text_size.x * 0.5, -5.0), labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT)
	draw_arc(center, RADIUS, 0.0, TAU, 48, EDGE, 1.5)
	draw_circle(center, INNER, BACK)
	if hint != "":
		var hint_size: Vector2 = font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		draw_string(font, center + Vector2(-hint_size.x * 0.5, RADIUS + 22.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TEXT)
