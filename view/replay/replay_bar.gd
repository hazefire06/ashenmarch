class_name ReplayBar
extends PanelContainer
## The strip across the top of a replay being watched: play or pause, the
## speed (1, 2, 4 or 8 ticks per physics frame), watch again, leave, how far
## in it is, and a note when the playback has left the recording (a replay
## from a build whose rules differ) or reached its end. Says what was pressed;
## MainView does it. Its buttons take no focus, like the control bar's, so
## the battlefield's keys never press them.

signal pause_pressed
signal speed_chosen(speed: int)
signal restart_pressed
signal exit_pressed

const SPEEDS: PackedInt32Array = [1, 2, 4, 8]

var _pause: Button
var _speeds: Array[Button] = []
var _clock: Label
var _note: Label


func _init() -> void:
	name = "ReplayBar"
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	# Below the mission line and a skirmish's score line, which share the top.
	position.y = 76
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	row.add_child(MenuKit.label("Replay", MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
	_pause = _button(row, "PauseButton", "Pause")
	_pause.pressed.connect(func() -> void: pause_pressed.emit())
	for speed: int in SPEEDS:
		var b: Button = _button(row, "Speed%d" % speed, "%dx" % speed)
		b.toggle_mode = true
		b.pressed.connect(func() -> void: speed_chosen.emit(speed))
		_speeds.append(b)
	_button(row, "RestartButton", "Watch again").pressed.connect(func() -> void: restart_pressed.emit())
	_button(row, "ExitButton", "Exit").pressed.connect(func() -> void: exit_pressed.emit())
	_clock = MenuKit.label("0:00 / 0:00")
	_clock.name = "Clock"
	row.add_child(_clock)
	_note = MenuKit.label("", MenuKit.BODY_SIZE, MenuKit.WARN_COLOR)
	_note.name = "Note"
	row.add_child(_note)


## Shows where the playback is: `tick` of `end_tick`, whether it's paused, the
## speed, and a note (empty for none).
func show_state(tick: int, end_tick: int, paused: bool, speed: int, note: String) -> void:
	_clock.text = "%s / %s" % [
		MenuKit.clock(tick / World.TICK_RATE), MenuKit.clock(end_tick / World.TICK_RATE),
	]
	_pause.text = "Play" if paused else "Pause"
	for i: int in SPEEDS.size():
		_speeds[i].button_pressed = SPEEDS[i] == speed
	_note.text = note
	_note.visible = note != ""


## Lets the bar's buttons take focus while the pad's control-bar mode is on.
func set_focus_enabled(on: bool) -> void:
	HudFocus.enable(self, on)


func _button(parent: Control, button_name: String, text: String) -> Button:
	var b: Button = Button.new()
	b.name = button_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	parent.add_child(b)
	return b
