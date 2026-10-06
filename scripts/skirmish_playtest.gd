extends SceneTree
## The skirmish playtest harness: `make skirmish-playtest`. Plays skirmishes
## headless through the real sim, many seeds, and prints one line per run and
## then tables of who wins, how long it takes and what it costs, so unit costs
## and army templates can be tuned from numbers instead of one person's
## evening. Every world is built exactly as the game builds one
## (SkirmishSetup.create_world), so a run's settings and seed reproduce it in
## the game and here.
##
## Two matrices, each answering its own question:
##   A  commander against commander: each Light template against Dark's balanced
##      one, and Light's balanced one against each Dark template, on every map
##      and mode, Light starting at A and then at B. Is any army template or
##      unit too strong or too weak when no one is playing?
##   B  a Phase 8 pilot plays Light (the competent or the naive bot, which
##      bracket a player) against the Dark commander. Does the AI give a
##      player a fight, on every map and mode, against every Dark template?
##
## Settings are environment variables (all optional):
##   MATRIX         comma list of A, B; default both
##   MAPS           comma list of map ids, default every map of the skirmish catalog
##   MODES          comma list of body_count, king_of_the_hill, capture_the_flags;
##                  default all three
##   SEEDS          runs per cell, default 2 for A and 5 for B (a cell is a map, a
##                  mode, a pairing and a start for A; a map, a mode, templates and
##                  a pilot for B)
##   SEED_BASE      the first world seed, default 1000; run i uses SEED_BASE + i,
##                  so SEED_BASE=<seed> SEEDS=1 replays one run
##   BUDGET         points both armies are bought with, default 1000
##   MINUTES        the skirmish's time limit in game minutes, default 10
##   PILOTS         (B) comma list of competent, naive; default both
##   PAIRINGS       (A) comma list of <light template>:<dark template>; default
##                  every Light template against dark_balanced, and light_balanced
##                  against every other Dark template (7 pairings)
##   DARK_TEMPLATES (B) comma list of Dark template ids; default all of them
##   LIGHT_TEMPLATES (B) the pilot's army templates, default light_balanced
##   STARTS         comma list of A, B: the starts Light plays from, each run once
##                  per start. Default: A runs from both, B alternates the pilot's
##                  start by the seed's parity (even seeds A, odd B)
##   RAW            write every run as a JSON line to this file (as it finishes)
##   REPORT         comma list of RAW files to merge into tables instead of
##                  playing: for batches run in several processes
##   OUT            write the Markdown tables to this file
##   TRACE          print a status line every this many game seconds during a run
## An unknown map, mode, template or pilot stops the run with exit code 1, so a
## typo doesn't quietly run a subset. Runs are independent and deterministic, so
## a batch splits across processes by matrix, map or mode with no loss; REPORT
## puts the pieces together. Exit code 1 too if a world can't be built or a file
## can't be written.

const SKIRMISH_PATH: String = "res://data/skirmish/skirmish.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
const DEFAULT_SEEDS_A: int = 2
const DEFAULT_SEEDS_B: int = 5
const DEFAULT_SEED_BASE: int = 1000
const DEFAULT_BUDGET: int = 1000
const DEFAULT_MINUTES: int = 10
const BALANCED_LIGHT: StringName = &"light_balanced"
const BALANCED_DARK: StringName = &"dark_balanced"

var _raw: FileAccess
# False once a setting was found wrong (_bad), so that every one is reported before
# the run is refused.
var _settings_ok: bool = true
# Runs whose world could not be built: the exit code is 1 if there were any.
var _unbuilt: int = 0


func _initialize() -> void:
	quit(_run())


func _run() -> int:
	var merge: PackedStringArray = _list("REPORT")
	if not merge.is_empty():
		return _merge(merge)
	return _play()


# ---- playing ----

func _play() -> int:
	var catalog: UnitCatalog = load(CATALOG_PATH) as UnitCatalog
	var skirmish: SkirmishCatalog = load(SKIRMISH_PATH) as SkirmishCatalog
	var problems: PackedStringArray = skirmish.validate(catalog)
	if not problems.is_empty():
		printerr("skirmish-playtest: the skirmish catalog doesn't validate: %s" % [problems])
		return 1
	var plan: Array[Dictionary] = _plan(skirmish)
	if plan.is_empty():
		# _plan has said why.
		return 1
	var raw_path: String = _env("RAW", "")
	if raw_path != "":
		_raw = FileAccess.open(raw_path, FileAccess.WRITE)
		if _raw == null:
			printerr("skirmish-playtest: can't write %s" % raw_path)
			return 1
	var runner: SkirmishRunner = SkirmishRunner.new(catalog, skirmish)
	runner.trace_seconds = int(_env("TRACE", "0"))
	var results: Array[SkirmishResult] = []
	var started_ms: int = Time.get_ticks_msec()
	for i: int in plan.size():
		var run: Dictionary = plan[i]
		var result: SkirmishResult = runner.play(
			run["map"], run["mode"], run["minutes"], run["budget"], run["light"], run["dark"],
			run["start"], run["seed"], run["pilot"]
		)
		runner.release()
		if result == null:
			printerr("skirmish-playtest: a world could not be built (%s)" % [run])
			_unbuilt += 1
			continue
		results.append(result)
		print("[%d/%d] %s" % [i + 1, plan.size(), result.line()])
		for note: String in result.notes:
			print("    " + note)
		if _raw != null:
			_raw.store_line(JSON.stringify(result.to_dict()))
			_raw.flush()
	var wall_s: float = float(Time.get_ticks_msec() - started_ms) / 1000.0
	var ticks: int = 0
	var wall_ms: int = 0
	for r: SkirmishResult in results:
		ticks += r.end_tick
		wall_ms += r.wall_ms
	var first_seed: int = int(_env("SEED_BASE", str(DEFAULT_SEED_BASE)))
	var preamble: String = (
		"%d runs; matrices %s; maps %s; modes %s; budget %d; %d-minute limit; seeds from %d. "
		+ "%.1f s wall clock, %.2f ms per simulated tick."
	) % [
		results.size(), ", ".join(_matrices()), ", ".join(_ids(plan, "map")),
		", ".join(_ids(plan, "mode_name")), int(_env("BUDGET", str(DEFAULT_BUDGET))),
		int(_env("MINUTES", str(DEFAULT_MINUTES))), first_seed, wall_s, float(wall_ms) / maxf(1.0, float(ticks)),
	]
	return _finish(results, preamble)


# Every run to play, in order, as dictionaries of what SkirmishRunner.play
# takes (plus "mode_name" for the preamble); empty after a printerr if a
# setting is wrong.
func _plan(skirmish: SkirmishCatalog) -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	var matrices: PackedStringArray = _matrices()
	if matrices.is_empty():
		return none
	var maps: Array[StringName] = _maps(skirmish)
	var modes: Array[SkirmishRules.Mode] = _modes()
	var pilots: Array[PlaytestPilot.Kind] = _pilots()
	var starts: Array[int] = _starts()
	var base: int = int(_env("SEED_BASE", str(DEFAULT_SEED_BASE)))
	var budget: int = int(_env("BUDGET", str(DEFAULT_BUDGET)))
	var minutes: int = int(_env("MINUTES", str(DEFAULT_MINUTES)))
	var seeds_a: int = int(_env("SEEDS", str(DEFAULT_SEEDS_A)))
	var seeds_b: int = int(_env("SEEDS", str(DEFAULT_SEEDS_B)))
	var pairings: Array[PackedStringArray] = _pairings(skirmish)
	var dark_templates: Array[StringName] = _templates(skirmish, "DARK_TEMPLATES", UnitType.Faction.DARK, "")
	var light_templates: Array[StringName] = _templates(skirmish, "LIGHT_TEMPLATES", UnitType.Faction.LIGHT, String(BALANCED_LIGHT))
	if not _settings_ok:
		return none
	if maps.is_empty() or modes.is_empty() or budget < 1 or minutes < 1 or seeds_a < 1 or seeds_b < 1:
		printerr("skirmish-playtest: nothing to run (check MAPS, MODES, BUDGET, MINUTES, SEEDS)")
		return none
	var wants_a: bool = matrices.has(SkirmishResult.MATRIX_A)
	var wants_b: bool = matrices.has(SkirmishResult.MATRIX_B)
	if (wants_a and pairings.is_empty()) or (wants_b and (pilots.is_empty() or dark_templates.is_empty() or light_templates.is_empty())):
		printerr("skirmish-playtest: nothing to run (check PAIRINGS, PILOTS, DARK_TEMPLATES, LIGHT_TEMPLATES)")
		return none
	var plan: Array[Dictionary] = []
	for map_id: StringName in maps:
		for mode: SkirmishRules.Mode in modes:
			if wants_a:
				for pair: PackedStringArray in pairings:
					for start: int in (starts if not starts.is_empty() else [0, 1]):
						for i: int in seeds_a:
							plan.append(_run_of(map_id, mode, minutes, budget, pair[0], pair[1], start, base + i, SkirmishRunner.NO_PILOT))
			if wants_b:
				for light: StringName in light_templates:
					for dark: StringName in dark_templates:
						for pilot: PlaytestPilot.Kind in pilots:
							for i: int in seeds_b:
								# Alternating by the seed's parity gives each start the same
								# number of runs without doubling the matrix.
								for start: int in (starts if not starts.is_empty() else [(base + i) % 2]):
									plan.append(_run_of(map_id, mode, minutes, budget, light, dark, start, base + i, pilot))
	return plan


func _run_of(
	map_id: StringName, mode: SkirmishRules.Mode, minutes: int, budget: int, light: StringName,
	dark: StringName, start: int, world_seed: int, pilot: int
) -> Dictionary:
	return {
		"map": map_id, "mode": mode, "mode_name": _mode_name(mode), "minutes": minutes, "budget": budget,
		"light": light, "dark": dark, "start": start, "seed": world_seed, "pilot": pilot,
	}


# ---- merging ----

func _merge(paths: PackedStringArray) -> int:
	var results: Array[SkirmishResult] = []
	for path: String in paths:
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			printerr("skirmish-playtest: can't read %s" % path)
			return 1
		while not file.eof_reached():
			var text: String = file.get_line().strip_edges()
			if text.is_empty():
				continue
			var result: SkirmishResult = SkirmishResult.from_dict(JSON.parse_string(text))
			if result == null:
				printerr("skirmish-playtest: %s has a line that isn't a run: %s" % [path, text.left(80)])
				return 1
			results.append(result)
	var files: PackedStringArray = PackedStringArray()
	for path: String in paths:
		files.append(path.get_file())
	return _finish(results, "%d runs merged from %s." % [results.size(), ", ".join(files)])


# Prints the tables, and writes them to OUT if it is set. The exit code: 0, or 1
# if OUT could not be written or a world could not be built.
func _finish(results: Array[SkirmishResult], preamble: String) -> int:
	var text: String = SkirmishReport.markdown(results, "Skirmish playtest results", preamble)
	print("")
	print(text)
	var code: int = 1 if _unbuilt > 0 else 0
	var out_path: String = _env("OUT", "")
	if out_path == "":
		return code
	var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		printerr("skirmish-playtest: can't write %s" % out_path)
		return 1
	file.store_string(text)
	return code


# ---- settings ----

# Reports a wrong setting; the run is refused once they have all been read.
func _bad(message: String) -> void:
	printerr("skirmish-playtest: " + message)
	_settings_ok = false


func _env(key: String, fallback: String) -> String:
	var value: String = OS.get_environment(key).strip_edges()
	return value if value != "" else fallback


func _list(key: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for part: String in OS.get_environment(key).split(",", false):
		out.append(part.strip_edges())
	return out


# The list in `key`, or the comma list `fallback` when it is unset.
func _list_or(key: String, fallback: String) -> PackedStringArray:
	var out: PackedStringArray = _list(key)
	if out.is_empty():
		for part: String in fallback.split(",", false):
			out.append(part)
	return out


# The matrices MATRIX names (A and B when it is unset), upper-cased; empty after a
# printerr for one that is neither.
func _matrices() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for text: String in _list_or("MATRIX", "A,B"):
		var m: String = text.to_upper()
		if m != SkirmishResult.MATRIX_A and m != SkirmishResult.MATRIX_B:
			_bad("MATRIX wants A or B, not %s" % text)
			return PackedStringArray()
		if not out.has(m):
			out.append(m)
	return out


# The maps named by MAPS (all of them when it is unset), in catalog order; an
# unknown one is an error (an empty result).
func _maps(skirmish: SkirmishCatalog) -> Array[StringName]:
	var out: Array[StringName] = []
	var wanted: PackedStringArray = _list("MAPS")
	for id: String in wanted:
		if skirmish.skirmish_map(StringName(id)) == null:
			_bad("no map called %s" % id)
			return []
	for m: SkirmishMap in skirmish.maps:
		if wanted.is_empty() or wanted.has(String(m.id)):
			out.append(m.id)
	return out


func _modes() -> Array[SkirmishRules.Mode]:
	var out: Array[SkirmishRules.Mode] = []
	var names: Array[String] = []
	for key: String in SkirmishRules.Mode.keys():
		names.append(key.to_lower())
	var wanted: PackedStringArray = _list_or("MODES", ",".join(names))
	for text: String in wanted:
		var at: int = names.find(text)
		if at < 0:
			_bad("MODES wants %s, not %s" % [", ".join(names), text])
			return []
		out.append(SkirmishRules.Mode.values()[at])
	return out


func _mode_name(mode: SkirmishRules.Mode) -> String:
	return String(SkirmishRules.Mode.keys()[mode]).to_lower()


func _pilots() -> Array[PlaytestPilot.Kind]:
	var out: Array[PlaytestPilot.Kind] = []
	for text: String in _list_or("PILOTS", "competent,naive"):
		var kind: int = PlaytestPilot.kind_from_name(text)
		if kind < 0:
			_bad("PILOTS wants competent or naive, not %s" % text)
			return []
		out.append(kind as PlaytestPilot.Kind)
	return out


# The starts STARTS names, 0 for A and 1 for B; empty if it is unset.
func _starts() -> Array[int]:
	var out: Array[int] = []
	for text: String in _list("STARTS"):
		if text.to_upper() != "A" and text.to_upper() != "B":
			_bad("STARTS wants A or B, not %s" % text)
			return []
		out.append(0 if text.to_upper() == "A" else 1)
	return out


# Matrix A's pairings as [light template, dark template], from PAIRINGS or the
# default seven; empty after a printerr for one that isn't a Light and a Dark
# template.
func _pairings(skirmish: SkirmishCatalog) -> Array[PackedStringArray]:
	var out: Array[PackedStringArray] = []
	var wanted: PackedStringArray = _list("PAIRINGS")
	if wanted.is_empty():
		for light: ArmyTemplate in skirmish.templates_for(UnitType.Faction.LIGHT):
			out.append(PackedStringArray([String(light.id), String(BALANCED_DARK)]))
		for dark: ArmyTemplate in skirmish.templates_for(UnitType.Faction.DARK):
			if dark.id != BALANCED_DARK:
				out.append(PackedStringArray([String(BALANCED_LIGHT), String(dark.id)]))
		return out
	for text: String in wanted:
		var parts: PackedStringArray = text.split(":")
		var light: ArmyTemplate = skirmish.template(StringName(parts[0])) if parts.size() == 2 else null
		var dark: ArmyTemplate = skirmish.template(StringName(parts[1])) if parts.size() == 2 else null
		if light == null or dark == null or light.faction != UnitType.Faction.LIGHT or dark.faction != UnitType.Faction.DARK:
			_bad("PAIRINGS wants <light template>:<dark template>, not %s" % text)
			return []
		out.append(PackedStringArray([parts[0], parts[1]]))
	return out


# The templates of one side named by `key` (all of that side's when `fallback`
# is "" and the setting is unset); empty after a printerr for an unknown one.
func _templates(
	skirmish: SkirmishCatalog, key: String, side: UnitType.Faction, fallback: String
) -> Array[StringName]:
	var out: Array[StringName] = []
	var wanted: PackedStringArray = _list(key)
	if wanted.is_empty() and fallback != "":
		wanted = PackedStringArray([fallback])
	for id: String in wanted:
		var t: ArmyTemplate = skirmish.template(StringName(id))
		if t == null or t.faction != side:
			_bad("%s wants templates of the %s side, not %s" % [key, "Light" if side == UnitType.Faction.LIGHT else "Dark", id])
			return []
		out.append(t.id)
	if wanted.is_empty():
		for t: ArmyTemplate in skirmish.templates_for(side):
			out.append(t.id)
	return out


# The distinct values of a plan field, as text, in plan order.
func _ids(plan: Array[Dictionary], field: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for run: Dictionary in plan:
		var text: String = String(run[field])
		if not out.has(text):
			out.append(text)
	return out
