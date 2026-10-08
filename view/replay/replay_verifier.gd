class_name ReplayVerifier
extends Node
## Plays replays headless-fast and says whether each reproduces its recorded
## checkpoints and final hash: the cross-platform determinism check. The App
## runs it instead of the menus when asked:
##   native: <game> --headless -- --verify-replays[=a.amr,b.amr] [--trace=FROM-TO] [--trace-entities]
##   web:    index.html?verify=1[&trace=FROM-TO][&entities=1]
## With no files named it checks every golden replay (ReplayStore.GOLDEN_DIR).
##
## One line per replay, the same on every platform so outputs diff cleanly:
##   VERIFY <file> OK ticks=<n> checkpoints=<n> final=<hash>
##   VERIFY <file> DIVERGED tick=<t> parts=<a,b> checkpoints=<matched>/<n> final=<hash>
##   VERIFY <file> ERROR <reason>
## then VERIFY SUMMARY ok=<n> failed=<n> on=<platform>. A trace adds
## TRACE <file> tick=<t> <part>=<hash>... per tick in its range (and
## TRACE <file> tick=<t> entity=<id> <hash> per entity with --trace-entities),
## to diff two platforms' runs down to the tick and entity that first differ.

signal finished(all_ok: bool)

## Ticks played per frame. Large when headless; small on the web so the page
## stays responsive and the result panel can draw.
var ticks_per_frame: int = 2000
## Inclusive tick range to trace, or [-1, -1] for none.
var trace_from: int = -1
var trace_to: int = -1
var trace_entities: bool = false
var catalog: UnitCatalog

var _paths: PackedStringArray = PackedStringArray()
var _index: int = -1
var _player: ReplayPlayer
var _name: String = ""
var _ok: int = 0
var _failed: int = 0
var _lines: PackedStringArray = PackedStringArray()
var _label: Label


## What was asked for on the command line or in the page's URL: an empty
## dictionary if nothing, else "paths" (PackedStringArray, maybe empty for all
## goldens), "trace" ([from, to] or empty) and "entities" (bool).
static func requested() -> Dictionary:
	if OS.has_feature("web"):
		return _from_query(str(JavaScriptBridge.eval("window.location.search", true)))
	return _from_args(OS.get_cmdline_user_args())


static func _from_args(args: PackedStringArray) -> Dictionary:
	var request: Dictionary = {}
	for arg: String in args:
		if arg == "--verify-replays":
			request["paths"] = PackedStringArray()
		elif arg.begins_with("--verify-replays="):
			request["paths"] = arg.trim_prefix("--verify-replays=").split(",", false)
	if request.is_empty():
		return request
	request["trace"] = PackedInt32Array()
	request["entities"] = false
	for arg: String in args:
		if arg.begins_with("--trace="):
			request["trace"] = _range(arg.trim_prefix("--trace="))
		elif arg == "--trace-entities":
			request["entities"] = true
	return request


static func _from_query(search: String) -> Dictionary:
	var params: Dictionary = {}
	for pair: String in search.trim_prefix("?").split("&", false):
		var kv: PackedStringArray = pair.split("=", true, 1)
		params[kv[0].uri_decode()] = kv[1].uri_decode() if kv.size() > 1 else ""
	if not params.has("verify") or params["verify"] in ["", "0"]:
		return {}
	var paths: PackedStringArray = PackedStringArray()
	if params["verify"] != "1":
		paths = str(params["verify"]).split(",", false)
	return {
		"paths": paths,
		"trace": _range(str(params.get("trace", ""))),
		"entities": params.get("entities", "") == "1",
	}


static func _range(text: String) -> PackedInt32Array:
	var ends: PackedStringArray = text.split("-", false)
	if ends.size() != 2 or not ends[0].is_valid_int() or not ends[1].is_valid_int():
		return PackedInt32Array()
	return PackedInt32Array([ends[0].to_int(), ends[1].to_int()])


## Golden replay files, sorted.
static func golden_paths() -> PackedStringArray:
	var paths: PackedStringArray = PackedStringArray()
	for file_name: String in DirAccess.get_files_at(ReplayStore.GOLDEN_DIR):
		if file_name.get_extension() == ReplayStore.EXTENSION:
			paths.append(ReplayStore.GOLDEN_DIR.path_join(file_name))
	paths.sort()
	return paths


## Starts checking. `request` is what requested() returned.
func start(request: Dictionary) -> void:
	_paths = request.get("paths", PackedStringArray())
	if _paths.is_empty():
		_paths = golden_paths()
	var trace: PackedInt32Array = request.get("trace", PackedInt32Array())
	if trace.size() == 2:
		trace_from = trace[0]
		trace_to = trace[1]
	trace_entities = request.get("entities", false)
	if DisplayServer.get_name() != "headless":
		_build_label()
	_emit("VERIFY START %d replays on %s" % [_paths.size(), platform()])
	_next()


## "macOS arm64", "Web wasm32" and so on.
static func platform() -> String:
	return "%s %s" % [OS.get_name(), Engine.get_architecture_name()]


func _process(_delta: float) -> void:
	if _player == null:
		return
	if trace_from < 0:
		_player.advance(ticks_per_frame)
	else:
		for i: int in ticks_per_frame:
			if _player.is_done():
				break
			_player.step()
			_trace(_player.world)
	if _player.is_done():
		_report()
		_next()


func _next() -> void:
	_index += 1
	_player = null
	if _index >= _paths.size():
		_emit("VERIFY SUMMARY ok=%d failed=%d on=%s" % [_ok, _failed, platform()])
		set_process(false)
		finished.emit(_failed == 0)
		return
	var path: String = _paths[_index]
	_name = path.get_file()
	var problems: Array[String] = []
	var replay: Replay = ReplayStore.load_file(path, problems)
	if replay == null:
		_fail("ERROR %s" % "; ".join(problems))
		_next()
		return
	_player = ReplayPlayer.new(replay, catalog)
	if _player.world == null:
		_fail("ERROR %s" % _player.error)
		_next()


func _report() -> void:
	var replay: Replay = _player.replay
	var final: String = _player.world.state_hash()
	var checks: String = "%d/%d" % [_player.matched, replay.checkpoints.size()]
	if _player.verified():
		_ok += 1
		_emit("VERIFY %s OK ticks=%d checkpoints=%s final=%s" % [_name, replay.end_tick, checks, final])
	elif not _player.divergence.is_empty():
		_fail("DIVERGED tick=%d parts=%s checkpoints=%s final=%s" % [
			_player.divergence["tick"], ",".join(_player.divergence["parts"]), checks, final,
		])
	else:
		_fail("DIVERGED at the end only: final=%s expected=%s" % [final, replay.final_hash])


func _trace(world: World) -> void:
	# world.tick is the tick just played plus one; trace by the tick played.
	var played: int = world.tick - 1
	if played < trace_from or played > trace_to:
		return
	var parts: Dictionary[String, String] = world.subsystem_hashes()
	var fields: PackedStringArray = PackedStringArray()
	for part: String in parts:
		fields.append("%s=%s" % [part, parts[part].left(16)])
	_emit("TRACE %s tick=%d %s" % [_name, played, " ".join(fields)])
	if trace_entities:
		var entities: Dictionary[int, String] = world.entity_hashes()
		for entity_id: int in entities:
			_emit("TRACE %s tick=%d entity=%d %s" % [_name, played, entity_id, entities[entity_id].left(16)])


func _fail(what: String) -> void:
	_failed += 1
	_emit("VERIFY %s %s" % [_name, what])


func _emit(line: String) -> void:
	print(line)
	_lines.append(line)
	if _label != null:
		_label.text = "\n".join(_lines)


func _build_label() -> void:
	_label = Label.new()
	_label.position = Vector2(16, 16)
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)
