class_name SkirmishHud
extends Control
## A skirmish's score at a glance, in two parts. Always on: one line at the top
## centre, where a mission's message line would sit (MissionHud's is empty in a
## skirmish): the mode, the time left and each side's score, with the player's
## side marked "(you)":
##   Body Count · 9:58 · Light (you) 3 · Dark 1
##   King of the Hill · 7:32 · Hill: Light (you) 1:12 · Dark 0:48
##   Capture the Flags · 4:10 · Flags: Light (you) 2 · Dark 1
## And on F7 (InputBindings.TOGGLE_SCOREBOARD), a panel in the middle of the
## screen: the mode and the clock, then for each side, the player's first, how
## many are alive of those deployed, how many were lost, how many of the enemy
## were killed, and the score in the mode's terms; in Capture the Flags also
## who owns each flag. Neither says who is winning in words: the banner at the
## end does (MissionHud).
## MainView calls show_world after every step; a label's text is only touched
## when it changes. Reads the World; never writes it, and never takes mouse
## input, so it can't block a click.

const LINE_FONT_SIZE: int = 20
const OUTLINE_SIZE: int = 8
const LINE_COLOR: Color = MenuKit.TEXT_COLOR
const OUTLINE_COLOR: Color = MenuKit.OUTLINE_COLOR
const SEPARATOR: String = " · "
## Added after the player's side in the top line.
const YOU_MARK: String = " (you)"
const BOARD_COLUMNS: PackedStringArray = ["", "Alive / Deployed", "Lost", "Kills", "Score"]
## The table's rows: the header, the player's side, the AI's.
const BOARD_ROWS: int = 3
const BOARD_HINT: String = "F7 closes this"
const HINT_FONT_SIZE: int = 14

var _world: World
var _player: UnitType.Faction = UnitType.Faction.LIGHT
var _line: Label
var _board: PanelContainer
var _summary: Label
## The grid's cells, row by row: the header, then the player's side, then the
## AI's, BOARD_COLUMNS.size() to a row.
var _cells: Array[Label] = []
var _flag_box: VBoxContainer
var _flag_lines: Array[Label] = []


func _ready() -> void:
	InputBindings.install()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build_line()
	_build_board()


## Names the player's side (it is marked in the top line and listed first on
## the scoreboard) and shows the world. Add the node to the tree first.
func setup(world: World, player_faction: UnitType.Faction) -> void:
	_player = player_faction
	show_world(world)


## Shows the skirmish as it stands now. Hides itself when the world has none.
func show_world(world: World) -> void:
	_world = world
	var runtime: SkirmishRuntime = world.skirmish
	visible = runtime != null
	if runtime == null:
		_set_text(_line, "")
		_board.visible = false
		return
	_set_text(_line, line_text(runtime, world.tick, _player))
	if _board.visible:
		_refresh_board(runtime, world.tick)


## Shows the scoreboard if hidden, hides it if shown.
func toggle_scoreboard() -> void:
	_board.visible = not _board.visible
	if _board.visible and _world != null and _world.skirmish != null:
		_refresh_board(_world.skirmish, _world.tick)


## Whether the scoreboard is on show.
func scoreboard_visible() -> bool:
	return _board.visible


## The top line as drawn: mode, time left, score. Empty when there is no
## skirmish.
func clock_text() -> String:
	return _line.text


## The scoreboard's mode and clock line, as drawn at the last refresh.
func scoreboard_summary() -> String:
	return _summary.text


## The scoreboard's table as drawn at the last refresh: the header row, then
## the player's side, then the AI's, each a row of cells.
func scoreboard_rows() -> Array[PackedStringArray]:
	var rows: Array[PackedStringArray] = []
	var width: int = BOARD_COLUMNS.size()
	for r: int in BOARD_ROWS:
		var row: PackedStringArray = PackedStringArray()
		for c: int in width:
			row.append(_cells[r * width + c].text)
		rows.append(row)
	return rows


## What the scoreboard says about each flag (Capture the Flags), as drawn at
## the last refresh. Empty in the other modes.
func scoreboard_flag_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for label: Label in _flag_lines:
		out.append(label.text)
	return out


## The mode's name as the player knows it.
static func mode_name(mode: SkirmishRules.Mode) -> String:
	match mode:
		SkirmishRules.Mode.BODY_COUNT:
			return "Body Count"
		SkirmishRules.Mode.KING_OF_THE_HILL:
			return "King of the Hill"
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			return "Capture the Flags"
	return "Skirmish"


## A side's score in the mode's terms: enemies killed (Body Count), time held on
## the hill as m:ss (King of the Hill), flags owned (Capture the Flags).
static func score_text(runtime: SkirmishRuntime, side: int) -> String:
	if runtime.rules.mode == SkirmishRules.Mode.KING_OF_THE_HILL:
		return MenuKit.clock(seconds_of(runtime.hold_ticks[side]))
	return str(runtime.score(side))


## Whole seconds of a number of ticks, rounded down.
static func seconds_of(ticks: int) -> int:
	return floori(float(ticks) / World.TICK_RATE)


## The top line for a skirmish at `tick`: "<mode> · <m:ss left> · <score>".
static func line_text(runtime: SkirmishRuntime, tick: int, player: UnitType.Faction) -> String:
	var left: int = ceili(float(runtime.ticks_left(tick)) / World.TICK_RATE)
	var parts: PackedStringArray = PackedStringArray()
	for side: int in SkirmishRuntime.SIDES:
		var mark: String = YOU_MARK if side == player else ""
		parts.append("%s%s %s" % [SideColors.side_name(side), mark, score_text(runtime, side)])
	var prefix: String = ""
	match runtime.rules.mode:
		SkirmishRules.Mode.KING_OF_THE_HILL:
			prefix = "Hill: "
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			prefix = "Flags: "
	return "%s%s%s%s%s%s" % [
		mode_name(runtime.rules.mode), SEPARATOR, MenuKit.clock(left), SEPARATOR, prefix,
		SEPARATOR.join(parts),
	]


# Nodes receive unhandled input while hidden, which is how F7 shows it again.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(InputBindings.TOGGLE_SCOREBOARD):
		toggle_scoreboard()
		get_viewport().set_input_as_handled()


func _build_line() -> void:
	_line = MenuKit.label("", LINE_FONT_SIZE, LINE_COLOR)
	_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	_line.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	_line.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_line.offset_top = MissionHud.OBJECTIVE_TOP
	_line.offset_bottom = MissionHud.OBJECTIVE_TOP + LINE_FONT_SIZE * 1.6
	add_child(_line)


func _build_board() -> void:
	var center: CenterContainer = CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_board = MenuKit.panel()
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board.visible = false
	center.add_child(_board)
	# Containers pass the mouse on by default, which would still make the panel
	# something the pointer is over: every one ignores it.
	var column: VBoxContainer = VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 10)
	_board.add_child(column)
	column.add_child(MenuKit.title("Scoreboard", MenuKit.HEADING_SIZE))
	_summary = MenuKit.label("", MenuKit.BODY_SIZE, MenuKit.BODY_COLOR)
	column.add_child(_summary)
	var grid: GridContainer = GridContainer.new()
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.columns = BOARD_COLUMNS.size()
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 6)
	column.add_child(grid)
	for r: int in BOARD_ROWS:
		for c: int in BOARD_COLUMNS.size():
			var color: Color = MenuKit.MUTED_COLOR if r == 0 else MenuKit.BODY_COLOR
			var cell: Label = MenuKit.label(BOARD_COLUMNS[c] if r == 0 else "", MenuKit.BODY_SIZE, color)
			if c > 0:
				cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			grid.add_child(cell)
			_cells.append(cell)
	_flag_box = VBoxContainer.new()
	_flag_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_flag_box)
	column.add_child(MenuKit.label(BOARD_HINT, HINT_FONT_SIZE, MenuKit.MUTED_COLOR))


# Fills the table, the clock and the flag lines from the runtime as it is now.
func _refresh_board(runtime: SkirmishRuntime, tick: int) -> void:
	var limit: int = seconds_of(runtime.rules.time_limit_ticks)
	var left: int = ceili(float(runtime.ticks_left(tick)) / World.TICK_RATE)
	_set_text(_summary, "%s%s%s left of %s" % [
		mode_name(runtime.rules.mode), SEPARATOR, MenuKit.clock(left), MenuKit.clock(limit),
	])
	var width: int = BOARD_COLUMNS.size()
	var other: int = 1 - _player
	var sides: Array[int] = [_player, other]
	for r: int in sides.size():
		var side: int = sides[r]
		var owner_name: String = "You" if side == _player else "AI"
		var texts: PackedStringArray = PackedStringArray([
			"%s (%s)" % [owner_name, SideColors.side_name(side)],
			"%d / %d" % [runtime.alive[side], runtime.roster_ids[side].size()],
			str(runtime.deaths[side]),
			str(runtime.deaths[1 - side]),
			score_text(runtime, side),
		])
		for c: int in width:
			var cell: Label = _cells[(r + 1) * width + c]
			_set_text(cell, texts[c])
			if c == 0:
				cell.add_theme_color_override("font_color", SideColors.of(side))
	_refresh_flag_lines(runtime)


# One line per flag in Capture the Flags: who owns it, and who is taking it.
func _refresh_flag_lines(runtime: SkirmishRuntime) -> void:
	var shown: PackedInt32Array = PackedInt32Array()
	if runtime.rules.mode == SkirmishRules.Mode.CAPTURE_THE_FLAGS:
		shown = FlagsView.shown_flags(runtime.rules)
	while _flag_lines.size() < shown.size():
		var label: Label = MenuKit.label("", MenuKit.BODY_SIZE, MenuKit.BODY_COLOR)
		_flag_box.add_child(label)
		_flag_lines.append(label)
	for i: int in _flag_lines.size():
		_flag_lines[i].visible = i < shown.size()
		if i >= shown.size():
			continue
		var flag: int = shown[i]
		var holder: int = runtime.flag_owner[flag]
		var text: String = "Flag %d: %s" % [flag + 1, SideColors.side_name(holder) if holder >= 0 else "nobody"]
		if runtime.flag_capture_side[flag] != SkirmishRuntime.NO_SIDE:
			text += " (%s capturing, %d%%)" % [
				SideColors.side_name(runtime.flag_capture_side[flag]),
				roundi(FlagsView.capture_ratio(runtime, flag) * 100.0),
			]
		_set_text(_flag_lines[i], text)
		_flag_lines[i].add_theme_color_override("font_color", SideColors.of(holder))


# Only touches the label when the text changed, so a long skirmish isn't
# re-laying-out its text 30 times a second.
func _set_text(label: Label, text: String) -> void:
	if label.text != text:
		label.text = text
