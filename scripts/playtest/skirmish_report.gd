class_name SkirmishReport
extends RefCounted
## Turns skirmish results into the Markdown tables a balance pass reads: for
## Matrix A (commander against commander) how often each side wins overall, by
## map and mode, by pairing of army templates and by which start Light had;
## for Matrix B (a pilot plays Light against the Dark commander) how often the
## pilot wins, per pilot, by Dark template, and by map and mode; and the runs
## that need a look, with the settings that reproduce them. Pure functions of
## the results, so a batch run in several processes reads back from its JSON
## lines (SkirmishResult.from_dict) and merges. Self-contained: it shares only
## the median with PlaytestReport, whose campaign tables it leaves alone.
##
## Every percentage is a share of the runs in its row, win, loss, draw and
## timeout adding to 100. "Light win" is Light's, whoever commanded it. A
## row's Light lost and Dark lost are the mean units lost per run (dead, or
## converted); "by elimination" is the share of runs ended by wiping a side
## out rather than by the clock.

## The maps and modes in the order rows go in, then any others by name.
const MAP_ORDER: Array[String] = ["riverside", "the_ford", "old_mill"]
const MODE_ORDER: Array[String] = ["body_count", "king_of_the_hill", "capture_the_flags"]
const PILOT_ORDER: Array[String] = ["competent", "naive"]
## How many seeds an anomaly line names before it says "and n more".
const MAX_SEEDS_LISTED: int = 8
## How many timed-out runs have their notes quoted.
const MAX_DETAILED: int = 3


## Every table, as one Markdown document, for these results.
static func markdown(results: Array[SkirmishResult], title: String, preamble: String = "") -> String:
	var out: PackedStringArray = PackedStringArray()
	out.append("# " + title)
	out.append("")
	if preamble != "":
		out.append(preamble)
		out.append("")
	var a: Array[SkirmishResult] = _matrix(results, SkirmishResult.MATRIX_A)
	var b: Array[SkirmishResult] = _matrix(results, SkirmishResult.MATRIX_B)
	if not a.is_empty():
		out.append_array(_matrix_a(a))
	if not b.is_empty():
		out.append_array(_matrix_b(b))
	out.append("## Anomalies")
	out.append("")
	out.append_array(_anomalies(results))
	out.append("")
	return "\n".join(out)


# ---- Matrix A ----

static func _matrix_a(runs: Array[SkirmishResult]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	out.append("## Matrix A: commander against commander (%d runs)" % runs.size())
	out.append("")
	out.append("### Overall")
	out.append("")
	out.append_array(_a_table("scope", [_row("all runs", "", runs)]))
	out.append("")
	out.append("### By map and mode")
	out.append("")
	out.append_array(_a_table("map / mode", _rows(runs, _map_mode_key)))
	out.append("")
	out.append("### By pairing of army templates")
	out.append("")
	out.append_array(_a_table("Light vs Dark", _rows(runs, func(r: SkirmishResult) -> Array[String]:
		return [r.pairing(), r.pairing()])))
	out.append("")
	out.append("### By Light's start")
	out.append("")
	out.append_array(_a_table("Light starts at", _rows(runs, func(r: SkirmishResult) -> Array[String]:
		return [r.start_name(), "start " + r.start_name()])))
	out.append("")
	return out


static func _a_table(first: String, rows: Array[Dictionary]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray([
		"| %s | runs | Light win | Dark win | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |" % first,
		"|---|---|---|---|---|---|---|---|---|---|",
	])
	for row: Dictionary in rows:
		var runs: Array[SkirmishResult] = row["runs"]
		out.append("| %s | %d | %s | %s | %s | %s | %s | %.1f | %.1f | %.1f |" % [
			row["label"], runs.size(), _share(runs, SkirmishResult.LIGHT), _share(runs, SkirmishResult.DARK),
			_share(runs, SkirmishResult.DRAW), _share(runs, SkirmishResult.TIMEOUT), _eliminated(runs),
			_median_minutes(runs), _mean_lost(runs, true), _mean_lost(runs, false),
		])
	return out


# ---- Matrix B ----

static func _matrix_b(runs: Array[SkirmishResult]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	out.append("## Matrix B: a pilot plays Light against the Dark commander (%d runs)" % runs.size())
	out.append("")
	out.append("Win is the pilot's, loss the commander's.")
	out.append("")
	out.append("### By pilot")
	out.append("")
	out.append_array(_b_table("scope", _pilot_rows(runs, func(_r: SkirmishResult) -> Array[String]:
		return ["a", "all"])))
	out.append("")
	out.append("### By pilot and Dark template")
	out.append("")
	out.append_array(_b_table("Dark template", _pilot_rows(runs, func(r: SkirmishResult) -> Array[String]:
		return [String(r.dark_template), String(r.dark_template)])))
	out.append("")
	out.append("### By pilot, map and mode")
	out.append("")
	out.append_array(_b_table("map / mode", _pilot_rows(runs, _map_mode_key)))
	out.append("")
	var light_templates: Dictionary[StringName, bool] = {}
	for r: SkirmishResult in runs:
		light_templates[r.light_template] = true
	if light_templates.size() > 1:
		out.append("### By pilot and Light template")
		out.append("")
		out.append_array(_b_table("Light template", _pilot_rows(runs, func(r: SkirmishResult) -> Array[String]:
			return [String(r.light_template), String(r.light_template)])))
		out.append("")
	return out


static func _b_table(first: String, rows: Array[Dictionary]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray([
		"| pilot | %s | runs | win | loss | draw | timeout | by elimination | min (median) | Light lost/run | Dark lost/run |" % first,
		"|---|---|---|---|---|---|---|---|---|---|---|",
	])
	for row: Dictionary in rows:
		var runs: Array[SkirmishResult] = row["runs"]
		out.append("| %s | %s | %d | %s | %s | %s | %s | %s | %.1f | %.1f | %.1f |" % [
			row["pilot"], row["label"], runs.size(), _share(runs, SkirmishResult.LIGHT),
			_share(runs, SkirmishResult.DARK), _share(runs, SkirmishResult.DRAW),
			_share(runs, SkirmishResult.TIMEOUT), _eliminated(runs), _median_minutes(runs),
			_mean_lost(runs, true), _mean_lost(runs, false),
		])
	return out


# One group per pilot and key, pilots in table order.
static func _pilot_rows(runs: Array[SkirmishResult], key_fn: Callable) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var pilots: Array[String] = []
	for r: SkirmishResult in runs:
		if not pilots.has(r.pilot):
			pilots.append(r.pilot)
	pilots.sort_custom(func(a: String, b: String) -> bool: return _rank(PILOT_ORDER, a) < _rank(PILOT_ORDER, b))
	for pilot: String in pilots:
		var mine: Array[SkirmishResult] = []
		for r: SkirmishResult in runs:
			if r.pilot == pilot:
				mine.append(r)
		for row: Dictionary in _rows(mine, key_fn):
			row["pilot"] = pilot
			out.append(row)
	return out


# ---- grouping ----

# Runs of one matrix.
static func _matrix(results: Array[SkirmishResult], matrix: String) -> Array[SkirmishResult]:
	var out: Array[SkirmishResult] = []
	for r: SkirmishResult in results:
		if r.matrix == matrix:
			out.append(r)
	return out


# The sort key and the label of a run's map and mode.
static func _map_mode_key(r: SkirmishResult) -> Array[String]:
	return ["%02d %02d %s %s" % [_rank(MAP_ORDER, String(r.map_id)), _rank(MODE_ORDER, r.mode), r.map_id, r.mode], r.cell()]


# {"label", "runs"} per distinct label of key_fn(run) = [sort key, label], in
# sort-key order.
static func _rows(runs: Array[SkirmishResult], key_fn: Callable) -> Array[Dictionary]:
	var by_label: Dictionary[String, Dictionary] = {}
	for r: SkirmishResult in runs:
		var key: Array[String] = key_fn.call(r)
		if not by_label.has(key[1]):
			var members: Array[SkirmishResult] = []
			by_label[key[1]] = {"label": key[1], "sort": key[0], "runs": members}
		var group: Array[SkirmishResult] = by_label[key[1]]["runs"]
		group.append(r)
	var out: Array[Dictionary] = []
	out.assign(by_label.values())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["sort"]) < String(b["sort"]))
	return out


# One row for runs that aren't split further.
static func _row(label: String, sort: String, runs: Array[SkirmishResult]) -> Dictionary:
	return {"label": label, "sort": sort, "runs": runs}


# Where a name stands in a fixed order; those not in it go after, by name (the
# caller breaks ties on the name itself).
static func _rank(order: Array[String], name: String) -> int:
	var at: int = order.find(name)
	return at if at >= 0 else order.size()


# ---- numbers ----

# "42%": the share of the runs whose winner is this.
static func _share(runs: Array[SkirmishResult], winner: String) -> String:
	var n: int = 0
	for r: SkirmishResult in runs:
		if r.winner == winner:
			n += 1
	return "%.0f%%" % (100.0 * n / maxf(1.0, runs.size()))


# The share of runs ended by elimination.
static func _eliminated(runs: Array[SkirmishResult]) -> String:
	var n: int = 0
	for r: SkirmishResult in runs:
		if r.end_reason == SkirmishResult.REASON_ELIMINATION:
			n += 1
	return "%.0f%%" % (100.0 * n / maxf(1.0, runs.size()))


static func _median_minutes(runs: Array[SkirmishResult]) -> float:
	var minutes: Array[float] = []
	for r: SkirmishResult in runs:
		minutes.append(r.end_minutes())
	return PlaytestReport.median(minutes)


# Mean units lost per run by Light (or Dark).
static func _mean_lost(runs: Array[SkirmishResult], light: bool) -> float:
	var total: int = 0
	for r: SkirmishResult in runs:
		total += r.light_lost() if light else r.dark_lost()
	return float(total) / maxf(1.0, runs.size())


# ---- anomalies ----

static func _anomalies(results: Array[SkirmishResult]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var timeouts: Array[SkirmishResult] = []
	for r: SkirmishResult in results:
		if r.winner == SkirmishResult.TIMEOUT:
			timeouts.append(r)
	if not timeouts.is_empty():
		out.append("- **%d of %d runs hit the safety cap undecided** (a skirmish decides itself at its time limit, so this is a sim fault). Replay one with SEED_BASE=<seed> SEEDS=1 and its map, mode, templates and start:" % [
			timeouts.size(), results.size(),
		])
		for k: int in mini(MAX_SEEDS_LISTED, timeouts.size()):
			var r: SkirmishResult = timeouts[k]
			out.append("  - %s %s, %s, Light at %s, %s, seed %d%s" % [
				r.matrix, r.cell(), r.pairing(), r.start_name(), r.pilot, r.world_seed,
				(": " + "; ".join(r.notes.slice(0, 1))) if k < MAX_DETAILED and not r.notes.is_empty() else "",
			])
		if timeouts.size() > MAX_SEEDS_LISTED:
			out.append("  - and %d more" % (timeouts.size() - MAX_SEEDS_LISTED))
	if out.is_empty():
		out.append("None: every run was decided by its rules.")
	return out
