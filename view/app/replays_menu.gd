class_name ReplaysMenu
extends MenuScreen
## The recorded games, newest first: what each was (the mission or skirmish,
## its mode), how it ended, how long it ran and when, with Watch and Delete.
## The App records every mission and skirmish (ReplayStore, newest
## ReplayStore.KEEP kept) and decides what Watch and Delete do; this screen
## only lists. A file that won't load is listed as damaged, with Delete only.

## Watch was pressed for the replay at `path`.
signal watch_requested(path: String)
## Delete was pressed for the replay at `path`: the App confirms first.
signal delete_requested(path: String)
## Back (or Esc).
signal back_requested

const OUTCOME_NAMES: Dictionary[String, String] = {
	"WON": "Victory", "LOST": "Defeat", "DRAW": "Draw", "NONE": "Unfinished",
}

var _rows: VBoxContainer
var _back: Button
var _first_watch: Button


func _init() -> void:
	super(true)
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	add_child(margin)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)
	column.add_child(MenuKit.title("Replays"))
	var scroller: ScrollContainer = MenuKit.scroller()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroller)
	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 6)
	scroller.add_child(_rows)
	_back = MenuKit.button("BackButton", "Back")
	_back.pressed.connect(func() -> void: back_requested.emit())
	column.add_child(_back)


## Lists the replays at `paths` (ReplayStore.list), newest first as given.
func setup(paths: PackedStringArray) -> void:
	MenuKit.clear(_rows)
	_first_watch = null
	if paths.is_empty():
		_rows.add_child(MenuKit.label(
			"No replays yet. Every mission and skirmish you play is recorded here.",
			MenuKit.BODY_SIZE, MenuKit.MUTED_COLOR
		))
	for path: String in paths:
		_rows.add_child(_row(path))
	_focus_default()


## The text a replay is listed with.
static func describe(replay: Replay) -> String:
	var summary: Dictionary = replay.summary
	var parts: PackedStringArray = PackedStringArray([str(summary.get("title", "Untitled"))])
	if summary.has("mode"):
		parts.append(str(summary["mode"]))
	if summary.has("tier"):
		parts.append(MenuKit.tier_name(summary["tier"]))
	parts.append(OUTCOME_NAMES.get(str(summary.get("outcome", "NONE")), "Unfinished"))
	parts.append(MenuKit.clock(replay.seconds()))
	var stamp: int = summary.get("recorded_at", 0)
	if stamp > 0:
		parts.append(_local_time(stamp))
	return "   ·   ".join(parts)


func _row(path: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var replay: Replay = ReplayStore.load_file(path)
	var text: String = describe(replay) if replay != null else "%s (damaged)" % path.get_file()
	var line: Label = MenuKit.label(text, MenuKit.BODY_SIZE, MenuKit.BODY_COLOR if replay != null else MenuKit.MUTED_COLOR)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.clip_text = true
	row.add_child(line)
	if replay != null:
		var watch: Button = MenuKit.button("Watch", "Watch", 110.0)
		watch.pressed.connect(func() -> void: watch_requested.emit(path))
		row.add_child(watch)
		if _first_watch == null:
			_first_watch = watch
	var delete: Button = MenuKit.button("Delete", "Delete", 110.0)
	delete.pressed.connect(func() -> void: delete_requested.emit(path))
	row.add_child(delete)
	return row


static func _local_time(unix_seconds: int) -> String:
	var bias_minutes: int = Time.get_time_zone_from_system().get("bias", 0)
	var t: Dictionary = Time.get_datetime_dict_from_unix_time(unix_seconds + bias_minutes * 60)
	return "%04d-%02d-%02d %02d:%02d" % [t["year"], t["month"], t["day"], t["hour"], t["minute"]]


func _focus_default() -> void:
	_focus(_first_watch if _first_watch != null else _back)


func _cancel() -> bool:
	back_requested.emit()
	return true
