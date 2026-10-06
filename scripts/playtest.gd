extends SceneTree
## The playtest harness: `make playtest`. A bot (PlaytestPilot) plays the
## campaign's missions headless through the real sim, many seeds, and prints
## one line per run and then tables of win rate, length, losses and kills per
## mission, tier and pilot, so a balance change can be judged by numbers
## instead of one person's evening. Every world is built exactly as the game
## builds one (a CampaignState's plan and mission_seed, MissionSetup), so a
## seed printed here is the seed that reproduces in the game and here.
##
## Settings are environment variables (all optional):
##   MISSIONS     comma list of mission ids, default every mission of the campaign
##   TIERS        comma list of difficulty tiers 0..4, default 2 (the middle)
##   SEEDS        runs per mission, tier and pilot, default 20
##   SEED_BASE    the first campaign seed, default 1000; run i uses SEED_BASE + i,
##                so SEED_BASE=<seed> SEEDS=1 replays one run
##   PILOTS       comma list of competent, naive; default both
##   CHAIN        1: play the whole campaign in order per seed, the survivors of
##                each mission (kills, wounds) carrying to the next, as the game
##                does; a lost mission ends that campaign (MISSIONS is ignored).
##                Default 0: every mission starts with fresh recruits.
##   MAX_MINUTES  game minutes before a run is called a timeout (a loss, in a
##                column of its own), default 25
##   OUT          write the Markdown tables to this file
##   TRACE        print a status line every this many game seconds during a run
##   RAW          write every run as a JSON line to this file (as it finishes)
##   REPORT       comma list of RAW files to merge into tables instead of
##                playing: for batches run in several processes
## Runs are independent and deterministic, so a batch splits across processes
## by mission, tier or pilot with no loss; REPORT puts the pieces together.

const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
const DEFAULT_SEEDS: int = 20
const DEFAULT_SEED_BASE: int = 1000
const DEFAULT_TIER: int = 2
const DEFAULT_MAX_MINUTES: int = 25

var _raw: FileAccess
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
	var campaign: CampaignDef = load(CAMPAIGN_PATH) as CampaignDef
	var catalog: UnitCatalog = load(CATALOG_PATH) as UnitCatalog
	var problems: PackedStringArray = campaign.validate(catalog)
	if not problems.is_empty():
		printerr("playtest: the campaign doesn't validate: %s" % [problems])
		return 1
	var missions: Array[MissionDef] = _missions(campaign)
	var tiers: Array[int] = _tiers()
	var pilots: Array[PlaytestPilot.Kind] = _pilots()
	var chain: bool = _env("CHAIN", "0") == "1"
	var seeds: int = int(_env("SEEDS", str(DEFAULT_SEEDS)))
	var base: int = int(_env("SEED_BASE", str(DEFAULT_SEED_BASE)))
	var max_minutes: int = int(_env("MAX_MINUTES", str(DEFAULT_MAX_MINUTES)))
	var max_ticks: int = max_minutes * 60 * World.TICK_RATE
	if missions.is_empty() or tiers.is_empty() or pilots.is_empty() or seeds < 1 or max_ticks < 1:
		printerr("playtest: nothing to run (check MISSIONS, TIERS, PILOTS, SEEDS, MAX_MINUTES)")
		return 1
	var raw_path: String = _env("RAW", "")
	if raw_path != "":
		_raw = FileAccess.open(raw_path, FileAccess.WRITE)
		if _raw == null:
			printerr("playtest: can't write %s" % raw_path)
			return 1
	var runner: PlaytestRunner = PlaytestRunner.new(catalog, campaign.soldier_names)
	runner.trace_seconds = int(_env("TRACE", "0"))
	var results: Array[PlaytestResult] = []
	var started_ms: int = Time.get_ticks_msec()
	for tier: int in tiers:
		for pilot: PlaytestPilot.Kind in pilots:
			if chain:
				for i: int in seeds:
					_play_campaign(runner, campaign, base + i, tier, pilot, max_ticks, results)
				continue
			for mission: MissionDef in missions:
				var index: int = campaign.missions.find(mission)
				for i: int in seeds:
					var state: CampaignState = CampaignState.new_campaign(base + i, tier)
					_record(runner.play(mission, index, state, pilot, max_ticks), runner, results)
	var wall_s: float = float(Time.get_ticks_msec() - started_ms) / 1000.0
	var ticks: int = 0
	var wall_ms: int = 0
	for r: PlaytestResult in results:
		ticks += r.end_tick
		wall_ms += r.wall_ms
	var preamble: String = (
		"%d runs; missions %s; tiers %s; pilots %s; %s; seeds %d to %d; cap %d game minutes. "
		+ "%.1f s wall clock, %.2f ms per simulated tick."
	) % [
		results.size(), ", ".join(_ids(missions)) if not chain else "the whole campaign in order",
		tiers, _pilot_names(pilots), "survivors carried over (CHAIN)" if chain else "fresh recruits each mission",
		base, base + seeds - 1, max_minutes, wall_s, float(wall_ms) / maxf(1.0, float(ticks)),
	]
	return _finish(results, preamble)


# A whole campaign for one seed: each mission in order with the last one's
# survivors, until one is lost.
func _play_campaign(
	runner: PlaytestRunner, campaign: CampaignDef, seed_value: int, tier: int,
	pilot: PlaytestPilot.Kind, max_ticks: int, results: Array[PlaytestResult]
) -> void:
	var state: CampaignState = CampaignState.new_campaign(seed_value, tier)
	for index: int in campaign.missions.size():
		var mission: MissionDef = campaign.missions[index]
		var result: PlaytestResult = runner.play(mission, state.mission_index, state, pilot, max_ticks, true)
		if result == null:
			printerr("playtest: a world could not be built")
			_unbuilt += 1
			return
		var won: bool = result.won()
		if won:
			state.apply_victory(mission, runner.last_plan, runner.last_world, runner.last_stats)
		_record(result, runner, results)
		if not won:
			return


# Prints a run's line, keeps it for the tables, writes its JSON line, and lets
# the world go: a batch would otherwise hold every finished world.
func _record(result: PlaytestResult, runner: PlaytestRunner, results: Array[PlaytestResult]) -> void:
	runner.release()
	if result == null:
		printerr("playtest: a world could not be built")
		_unbuilt += 1
		return
	results.append(result)
	print(result.line())
	for note: String in result.notes:
		print("    " + note)
	if _raw != null:
		_raw.store_line(JSON.stringify(result.to_dict()))
		_raw.flush()


# ---- merging ----

func _merge(paths: PackedStringArray) -> int:
	var results: Array[PlaytestResult] = []
	for path: String in paths:
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			printerr("playtest: can't read %s" % path)
			return 1
		while not file.eof_reached():
			var text: String = file.get_line().strip_edges()
			if text.is_empty():
				continue
			var result: PlaytestResult = PlaytestResult.from_dict(JSON.parse_string(text))
			if result == null:
				printerr("playtest: %s has a line that isn't a run: %s" % [path, text.left(80)])
				return 1
			results.append(result)
	var files: PackedStringArray = PackedStringArray()
	for path: String in paths:
		files.append(path.get_file())
	return _finish(results, "%d runs merged from %s." % [results.size(), ", ".join(files)])


# Prints the tables, and writes them to OUT if it is set. The exit code: 0, or 1
# if OUT could not be written or a world could not be built.
func _finish(results: Array[PlaytestResult], preamble: String) -> int:
	var text: String = PlaytestReport.markdown(results, "Playtest results", preamble)
	print("")
	print(text)
	var code: int = 1 if _unbuilt > 0 else 0
	var out_path: String = _env("OUT", "")
	if out_path == "":
		return code
	var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		printerr("playtest: can't write %s" % out_path)
		return 1
	file.store_string(text)
	return code


# ---- settings ----

func _env(key: String, fallback: String) -> String:
	var value: String = OS.get_environment(key).strip_edges()
	return value if value != "" else fallback


func _list(key: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for part: String in OS.get_environment(key).split(",", false):
		out.append(part.strip_edges())
	return out


# The missions named by MISSIONS (all of them when it is unset), in campaign
# order; an id the campaign doesn't have is reported and skipped.
func _missions(campaign: CampaignDef) -> Array[MissionDef]:
	var wanted: PackedStringArray = _list("MISSIONS")
	for id: String in wanted:
		var known: bool = false
		for mission: MissionDef in campaign.missions:
			known = known or String(mission.id) == id
		if not known:
			printerr("playtest: no mission called %s" % id)
	var out: Array[MissionDef] = []
	for mission: MissionDef in campaign.missions:
		if wanted.is_empty() or wanted.has(String(mission.id)):
			out.append(mission)
	return out


func _tiers() -> Array[int]:
	var out: Array[int] = []
	for text: String in _env("TIERS", str(DEFAULT_TIER)).split(",", false):
		if not text.strip_edges().is_valid_int() or int(text) < 0 or int(text) >= Difficulty.TIERS:
			printerr("playtest: TIERS wants whole numbers 0 to %d, not %s" % [Difficulty.TIERS - 1, text])
			continue
		out.append(int(text))
	return out


func _pilots() -> Array[PlaytestPilot.Kind]:
	var out: Array[PlaytestPilot.Kind] = []
	for text: String in _env("PILOTS", "competent,naive").split(",", false):
		var kind: int = PlaytestPilot.kind_from_name(text.strip_edges())
		if kind < 0:
			printerr("playtest: PILOTS wants competent or naive, not %s" % text)
			continue
		out.append(kind as PlaytestPilot.Kind)
	return out


func _ids(missions: Array[MissionDef]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for mission: MissionDef in missions:
		out.append(String(mission.id))
	return out


func _pilot_names(pilots: Array[PlaytestPilot.Kind]) -> String:
	var out: PackedStringArray = PackedStringArray()
	for pilot: PlaytestPilot.Kind in pilots:
		out.append(PlaytestPilot.kind_name(pilot))
	return ", ".join(out)
