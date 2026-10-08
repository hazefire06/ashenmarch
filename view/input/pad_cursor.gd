class_name PadCursor
extends Control
## The pad's cursor: a drawn arrowhead (not the system pointer, which the
## browser won't let a page move) at `at`, in viewport pixels. PadController
## moves it; it is shown only while the pad is in use (InputDevice), and then
## stands in for the mouse (Pointer). It never takes input.

const FILL: Color = Color(1.0, 0.95, 0.7, 1.0)
const OUTLINE: Color = Color(0.05, 0.05, 0.05, 0.95)
const SNAPPED_RING: Color = Color(0.45, 1.0, 0.45, 0.9)
## The arrowhead's length in pixels at an interface scale of 1.
const SIZE: float = 22.0

## Where it points, in viewport pixels.
var at: Vector2 = Vector2.ZERO:
	set(value):
		at = value
		queue_redraw()
## True while it rests on a unit (drawn with a ring).
var snapped: bool = false:
	set(value):
		snapped = value
		queue_redraw()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	z_index = 100


func _draw() -> void:
	var tip: Vector2 = at
	var points: PackedVector2Array = PackedVector2Array([
		tip, tip + Vector2(0.0, SIZE), tip + Vector2(SIZE * 0.3, SIZE * 0.75), tip + Vector2(SIZE * 0.72, SIZE * 0.72),
	])
	draw_colored_polygon(points, FILL)
	points.append(tip)
	draw_polyline(points, OUTLINE, 1.5, true)
	if snapped:
		draw_arc(tip, SIZE * 0.6, 0.0, TAU, 24, SNAPPED_RING, 2.0, true)
