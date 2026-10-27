class_name BudgetRun
extends Node
## The Web texture budget's check (docs/specs/2026-10-15-art-a4-loading-design.md
## §6). The App runs it instead of the menus when asked:
##   native: <game> -- --budget        (make budget, make budget-app)
##   web:    index.html?budget=1       (make export-web serve-web)
## It plays the worst case for texture memory, rendered: an AI-against-AI
## skirmish on Old Mill with every buyable type, EACH of each per side, until
## the world has played play_ticks (60 s). Then it measures, prints one line
## and shows it on screen:
##   web:     BUDGET tab=<MB> limit=1000 PASS|FAIL|UNKNOWN js_wasm=<MB> (<how>) video=<MB>
##            textures=<MB> art=<MB> types=<n> art_load=<ms> pck=<MB> wire=<MB> s3tc=<yes|no>
##            ticks=<n> seconds=<s> on=web
##   desktop: BUDGET video=<MB> textures=<MB> static=<MB> art=<MB> types=<n> art_load=<ms>
##            ticks=<n> seconds=<s> on=<os>
## tab is js_wasm plus video. js_wasm is measureUserAgentSpecificMemory when
## the page is cross-origin isolated ("measured"), else Chrome's JS heap alone
## ("fallback"), else unknown (-1). Only a measured tab gets PASS or FAIL: the
## JS heap leaves out the wasm memory and the pck the page holds, so a
## fallback line shows its count but says UNKNOWN, as an unknown one does.
## art is the loaded unit sheets' bytes, computed from their sizes and formats
## (UnitArt.sheet_bytes): Godot 4.7 doesn't give scripts the driver's own
## count per texture. Desktop has no budget, so its line has no verdict. The
## page sets window.__amBudgetLine to the line, for a script to read.

signal finished(line: String)

const LIMIT_MB: int = 1000
const EACH: int = 2
const MAP_ID: StringName = &"old_mill"
const SEED: int = 1000
const MINUTES: int = 10
## Frames to wait for the browser's memory measurement, which Chrome takes at
## its next garbage collection, before giving up on it.
const JS_WAIT_FRAMES: int = 1800
const MAIN_SCENE: String = "res://view/main.tscn"
const MB: float = 1_000_000.0
## How the page can say it read its memory.
const HOWS: Array[String] = ["measured", "fallback", "unknown"]
## Starts the page's measurement; window.__amBudget gets its JSON.
const JS_MEASURE: String = """
window.__amBudget = null;
(async () => {
	const out = {how: 'unknown', bytes: -1, pck: -1, wire: -1, s3tc: false};
	const pck = performance.getEntriesByType('resource').find((e) => e.name.split('?')[0].endsWith('.pck'));
	if (pck) { out.pck = pck.decodedBodySize; out.wire = pck.transferSize; }
	const gl = document.createElement('canvas').getContext('webgl2');
	out.s3tc = !!(gl && gl.getExtension('WEBGL_compressed_texture_s3tc'));
	try {
		if (!self.crossOriginIsolated || !performance.measureUserAgentSpecificMemory) throw new Error('unavailable');
		out.bytes = (await performance.measureUserAgentSpecificMemory()).bytes;
		out.how = 'measured';
	} catch (e) {
		if (performance.memory) { out.bytes = performance.memory.totalJSHeapSize; out.how = 'fallback'; }
	}
	window.__amBudget = JSON.stringify(out);
})();
"""

var catalog: UnitCatalog
var skirmish: SkirmishCatalog
## Sim ticks to play before measuring.
var play_ticks: int = 60 * World.TICK_RATE
var main: MainView
## The result, once measured.
var line: String = ""

var _started_ms: int = 0
var _measuring: bool = false
var _js_frames: int = 0
var _fields: Dictionary = {}
var _label: Label


## True when the command line or the page's URL asks for the check.
static func requested() -> bool:
	if OS.has_feature("web"):
		return asked_in_query(str(JavaScriptBridge.eval("window.location.search", true)))
	return "--budget" in OS.get_cmdline_user_args()


## True when a page's search string (?a=1&budget=1) holds budget=<not 0>.
static func asked_in_query(search: String) -> bool:
	for pair: String in search.trim_prefix("?").split("&", false):
		var kv: PackedStringArray = pair.split("=", true, 1)
		if kv[0].uri_decode() == "budget":
			var value: String = kv[1].uri_decode() if kv.size() > 1 else ""
			return value != "" and value != "0"
	return false


## The worst case for texture memory: every buyable type of each side, EACH of
## each, AI against AI on Old Mill, with a budget that buys both armies.
static func worst_case_setup(units: UnitCatalog, skirmishes: SkirmishCatalog) -> SkirmishSetup:
	var setup: SkirmishSetup = SkirmishSetup.new()
	setup.map = skirmishes.skirmish_map(MAP_ID)
	setup.rules = SkirmishRules.for_map(setup.map, SkirmishRules.Mode.BODY_COUNT, MINUTES, UnitType.Faction.LIGHT)
	var light: Army = Army.new(UnitType.Faction.LIGHT)
	var dark: Army = Army.new(UnitType.Faction.DARK)
	for type: UnitType in units.types:
		if type.cost <= 0:
			continue
		(light if type.faction == UnitType.Faction.LIGHT else dark).set_count(type.id, EACH)
	setup.armies = [light, dark]
	setup.budget = maxi(light.cost(units), dark.cost(units))
	setup.player_is_ai = true
	setup.world_seed = SEED
	return setup


## PASS within LIMIT_MB, FAIL over it, UNKNOWN when the tab's memory couldn't
## be read (negative).
static func verdict(tab_mb: float) -> String:
	if tab_mb < 0.0:
		return "UNKNOWN"
	return "PASS" if tab_mb <= LIMIT_MB else "FAIL"


## The web line from the fields (see the head). js_bytes is -1 when unread.
static func web_line(f: Dictionary) -> String:
	var js: float = float(f["js_bytes"])
	var tab: float = js + float(f["video"]) if js >= 0.0 else -1.0
	var judged: float = tab / MB if tab >= 0.0 and f["how"] == "measured" else -1.0
	return (
		"BUDGET tab=%d limit=%d %s js_wasm=%d (%s) video=%d textures=%d art=%d types=%d art_load=%d"
		+ " pck=%d wire=%d s3tc=%s ticks=%d seconds=%d on=web"
	) % [
		_mb(tab), LIMIT_MB, verdict(judged), _mb(js), f["how"], _mb(f["video"]),
		_mb(f["textures"]), _mb(f["art"]), f["types"], f["art_load_ms"], _mb(f["pck"]), _mb(f["wire"]),
		"yes" if f["s3tc"] else "no", f["ticks"], f["seconds"],
	]


## The desktop line from the fields (see the head).
static func desktop_line(f: Dictionary) -> String:
	return "BUDGET video=%d textures=%d static=%d art=%d types=%d art_load=%d ticks=%d seconds=%d on=%s" % [
		_mb(f["video"]), _mb(f["textures"]), _mb(f["static"]), _mb(f["art"]), f["types"], f["art_load_ms"],
		f["ticks"], f["seconds"], OS.get_name().to_lower(),
	]


## The page's measurement (JS_MEASURE's JSON) as web_line's fields: js_bytes,
## how, pck, wire and s3tc. Any script on the page can set window.__amBudget,
## so a value that is missing or of the wrong type reads as unknown (-1,
## "unknown", false), never as a count.
static func page_fields(raw: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(raw) if not raw.is_empty() else null
	var page: Dictionary = parsed if parsed is Dictionary else {}
	var how: Variant = page.get("how")
	return {
		"js_bytes": _count(page.get("bytes")),
		"how": how if how is String and how in HOWS else "unknown",
		"pck": _count(page.get("pck")),
		"wire": _count(page.get("wire")),
		"s3tc": page.get("s3tc") is bool and page["s3tc"],
	}


# A byte count from the page, or -1 when it isn't a number of at least 0.
static func _count(value: Variant) -> float:
	if not (value is float or value is int):
		return -1.0
	return float(value) if float(value) >= 0.0 else -1.0


# Whole MB, or -1 for a count that couldn't be read.
static func _mb(bytes: float) -> int:
	return -1 if bytes < 0.0 else roundi(bytes / MB)


## Builds the worst case and starts playing it.
func start() -> void:
	main = (load(MAIN_SCENE) as PackedScene).instantiate() as MainView
	main.launch = MissionLaunch.for_skirmish(worst_case_setup(catalog, skirmish))
	# Not campaign mode: a window opened from a terminal starts unfocused, and
	# campaign mode pauses when the window loses focus.
	main.launch.campaign_mode = false
	add_child(main)
	_started_ms = Time.get_ticks_msec()
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(16.0, 16.0)
	_label.text = "Budget check: playing %d s..." % roundi(play_ticks / float(World.TICK_RATE))
	layer.add_child(_label)


func _process(_delta: float) -> void:
	if main == null or main.world == null or not line.is_empty():
		return
	if main.paused:
		main.paused = false
	if not _measuring:
		if main.world.tick >= play_ticks or main.is_frozen():
			_measure()
		return
	if OS.has_feature("web"):
		_poll_page()


func _measure() -> void:
	_measuring = true
	var arts: Array[UnitArt] = main.loaded_arts()
	var art_bytes: int = 0
	for art: UnitArt in arts:
		art_bytes += art.sheet_bytes()
	_fields = {
		"video": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		"textures": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
		"static": float(OS.get_static_memory_usage()),
		"art": float(art_bytes),
		"types": arts.size(),
		"art_load_ms": main.art_load_ms,
		"ticks": main.world.tick,
		"seconds": roundi((Time.get_ticks_msec() - _started_ms) / 1000.0),
	}
	if OS.has_feature("web"):
		JavaScriptBridge.eval(JS_MEASURE, true)
	else:
		_finish(desktop_line(_fields))


# Reads the page's measurement once it is there, or gives up on it.
func _poll_page() -> void:
	_js_frames += 1
	var raw: Variant = JavaScriptBridge.eval("window.__amBudget", true)
	if not raw is String or (raw as String).is_empty():
		if _js_frames < JS_WAIT_FRAMES:
			return
		raw = "{}"
	_fields.merge(page_fields(raw), true)
	_finish(web_line(_fields))


func _finish(text: String) -> void:
	line = text
	print(line)
	_label.text = line
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__amBudgetLine = %s;" % JSON.stringify(line), true)
	finished.emit(line)
