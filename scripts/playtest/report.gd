class_name PlaytestReport
extends RefCounted
## Turns playtest results into the Markdown tables of a baseline: one row per
## mission, tier and pilot (and per fresh or chained soldiers), then the
## mission-specific tables (The Ford's villager, Old Mill's waves, a chained
## campaign's progress) and the anomalies with the seeds that reproduce them.
## Pure functions of the results, so a batch run in several processes reads
## back from its JSON lines (PlaytestResult.from_dict) and merges.

## The missions in campaign order, then any others by name: the order rows go in.
const MISSION_ORDER: Array[StringName] = [&"riverside", &"the_ford", &"old_mill"]
const PILOT_ORDER: Array[String] = ["competent", "naive"]
## How many seeds an anomaly line names before it says "and n more".
const MAX_SEEDS_LISTED: int = 8
## How many timed-out runs per group have their leftover enemies described.
const MAX_DETAILED: int = 3


## Every table, as one Markdown document, for these results.
static func markdown(results: Array[PlaytestResult], title: String, preamble: String = "") -> String:
	var out: PackedStringArray = PackedStringArray()
	out.append("# " + title)
	out.append("")
	if preamble != "":
		out.append(preamble)
		out.append("")
	out.append("## Results by mission, tier and pilot")
	out.append("")
	out.append_array(_main_table(results))
	out.append("")
	var ford: PackedStringArray = _ford_table(results)
	if not ford.is_empty():
		out.append("## The Ford: the villager")
		out.append("")
		out.append_array(ford)
		out.append("")
	var mill: PackedStringArray = _mill_table(results)
	if not mill.is_empty():
		out.append("## Old Mill: the waves")
		out.append("")
		out.append_array(mill)
		out.append("")
	var chain: PackedStringArray = _chain_table(results)
	if not chain.is_empty():
		out.append("## The campaign chained (survivors carry over)")
		out.append("")
		out.append_array(chain)
		out.append("")
	out.append("## Anomalies")
	out.append("")
	out.append_array(_anomalies(results))
	out.append("")
	return "\n".join(out)


## Nearest-rank percentile (0..100) of values; 0 for none.
static func percentile(values: Array[float], percent: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var rank: int = clampi(ceili(percent / 100.0 * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[rank]


## The median: halfway between the two middle values of an even count.
static func median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	if n % 2 == 1:
		return sorted[n >> 1]
	return (sorted[(n >> 1) - 1] + sorted[n >> 1]) / 2.0


## Results grouped by mission, mode, tier and pilot, in table order. Each entry
## is {"label", "mission", "chain", "tier", "pilot", "runs"}.
static func groups(results: Array[PlaytestResult]) -> Array[Dictionary]:
	var by_key: Dictionary[String, Dictionary] = {}
	for r: PlaytestResult in results:
		var key: String = "%s|%d|%d|%s" % [r.mission_id, int(r.chain), r.tier, r.pilot]
		if not by_key.has(key):
			var runs: Array[PlaytestResult] = []
			by_key[key] = {
				"label": "%s%s" % [r.mission_id, " (chain)" if r.chain else ""],
				"mission": r.mission_id, "chain": r.chain, "tier": r.tier, "pilot": r.pilot, "runs": runs,
			}
		var members: Array[PlaytestResult] = by_key[key]["runs"]
		members.append(r)
	var out: Array[Dictionary] = []
	out.assign(by_key.values())
	out.sort_custom(_group_before)
	return out


static func _group_before(a: Dictionary, b: Dictionary) -> bool:
	var ma: int = _mission_rank(a["mission"])
	var mb: int = _mission_rank(b["mission"])
	if ma != mb:
		return ma < mb
	if a["chain"] != b["chain"]:
		return not a["chain"]
	if a["tier"] != b["tier"]:
		return a["tier"] < b["tier"]
	return PILOT_ORDER.find(a["pilot"]) < PILOT_ORDER.find(b["pilot"])


static func _mission_rank(mission_id: StringName) -> int:
	var at: int = MISSION_ORDER.find(mission_id)
	return at if at >= 0 else MISSION_ORDER.size()


static func _main_table(results: Array[PlaytestResult]) -> PackedStringArray:
	var rows: PackedStringArray = PackedStringArray([
		"| mission | tier | pilot | runs | win | lose | timeout | min (median) | min (p90) | min (median of wins) | losses/run | losses % of roster | losses/win | kills/run | friendly-fire deaths/run | stuck units/run |",
		"|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
	])
	for g: Dictionary in groups(results):
		var runs: Array[PlaytestResult] = g["runs"]
		var minutes: Array[float] = []
		var won_minutes: Array[float] = []
		var won: int = 0
		var lost: int = 0
		var timeouts: int = 0
		var losses: float = 0.0
		var losses_pct: float = 0.0
		var win_losses: float = 0.0
		var kills: float = 0.0
		var friendly: float = 0.0
		var stuck: float = 0.0
		for r: PlaytestResult in runs:
			minutes.append(r.minutes())
			match r.outcome:
				PlaytestResult.WON:
					won += 1
					won_minutes.append(r.minutes())
					win_losses += r.losses
				PlaytestResult.LOST:
					lost += 1
				_:
					timeouts += 1
			losses += r.losses
			losses_pct += 100.0 * r.losses / maxf(1.0, r.roster)
			kills += r.kills
			friendly += r.friendly_fire
			stuck += r.stuck_units
		var n: float = runs.size()
		rows.append("| %s | %d | %s | %d | %s | %s | %s | %.1f | %.1f | %s | %.1f | %.0f%% | %s | %.1f | %.2f | %.2f |" % [
			g["label"], g["tier"], g["pilot"], runs.size(), _pct(won, runs.size()), _pct(lost, runs.size()),
			_pct(timeouts, runs.size()), median(minutes), percentile(minutes, 90.0),
			("%.1f" % median(won_minutes)) if won > 0 else "n/a", losses / n,
			losses_pct / n, ("%.1f" % (win_losses / won)) if won > 0 else "n/a", kills / n, friendly / n, stuck / n,
		])
	return rows


static func _ford_table(results: Array[PlaytestResult]) -> PackedStringArray:
	var rows: PackedStringArray = PackedStringArray()
	for g: Dictionary in groups(results):
		if g["mission"] != &"the_ford":
			continue
		var runs: Array[PlaytestResult] = g["runs"]
		var died: int = 0
		var sprung: int = 0
		var killers: Dictionary[String, int] = {}
		var lowest: Array[float] = []
		for r: PlaytestResult in runs:
			lowest.append(r.villager_lowest_percent)
			if r.ambushes_sprung > 0:
				sprung += 1
			if r.villager_died:
				died += 1
				killers[r.villager_killer] = killers.get(r.villager_killer, 0) + 1
		if rows.is_empty():
			rows.append("| mode | tier | pilot | runs | villager died | killed by | his lowest hp, median / worst (%) | pool ambush sprung |")
			rows.append("|---|---|---|---|---|---|---|---|")
		rows.append("| %s | %d | %s | %d | %s | %s | %.0f / %.0f | %s |" % [
			"chain" if g["chain"] else "fresh", g["tier"], g["pilot"], runs.size(),
			_pct(died, runs.size()), _counts_text(killers), median(lowest), percentile(lowest, 0.0),
			_pct(sprung, runs.size()),
		])
	return rows


static func _mill_table(results: Array[PlaytestResult]) -> PackedStringArray:
	var rows: PackedStringArray = PackedStringArray()
	for g: Dictionary in groups(results):
		if g["mission"] != &"old_mill":
			continue
		var runs: Array[PlaytestResult] = g["runs"]
		var drawn: Dictionary[String, int] = {}
		var ended_in: Dictionary[String, int] = {}
		var charges: Array[float] = []
		var breaks: int = 0
		for r: PlaytestResult in runs:
			breaks += r.stall_breaks
			for wave: String in r.waves:
				drawn[wave] = drawn.get(wave, 0) + 1
			if r.outcome == PlaytestResult.LOST and not r.waves.is_empty():
				# A loss is the wave on the field when it happened (the last to spawn).
				var key: String = "lost in %s" % (
					"no wave" if r.waves_spawned == 0 else "wave %d (%s)" % [r.waves_spawned, r.waves[r.waves_spawned - 1]]
				)
				ended_in[key] = ended_in.get(key, 0) + 1
			elif r.outcome == PlaytestResult.TIMEOUT and not r.waves.is_empty():
				# A stalemate is whatever is still standing, which need not be the last wave.
				var left: String = "+".join(r.alive_groups) if not r.alive_groups.is_empty() else "nothing found"
				var stale: String = "timeout with %s left" % left
				ended_in[stale] = ended_in.get(stale, 0) + 1
			if r.charges_done_tick >= 0:
				charges.append(float(r.charges_done_tick) / World.TICK_RATE)
		if rows.is_empty():
			rows.append("| mode | tier | pilot | runs | waves drawn (runs) | ended badly in | charges laid by (median s) | sorties to finish a stand-off |")
			rows.append("|---|---|---|---|---|---|---|---|")
		rows.append("| %s | %d | %s | %d | %s | %s | %s | %d |" % [
			"chain" if g["chain"] else "fresh", g["tier"], g["pilot"], runs.size(), _counts_text(drawn),
			_counts_text(ended_in) if not ended_in.is_empty() else "-",
			("%.0f" % median(charges)) if not charges.is_empty() else "n/a", breaks,
		])
	return rows


static func _chain_table(results: Array[PlaytestResult]) -> PackedStringArray:
	var by_pilot: Dictionary[String, Dictionary] = {}
	var order: Array[String] = []
	for r: PlaytestResult in results:
		if not r.chain:
			continue
		var key: String = "%d|%s" % [r.tier, r.pilot]
		if not by_pilot.has(key):
			by_pilot[key] = {"tier": r.tier, "pilot": r.pilot, "reached": {}, "won": {}}
			order.append(key)
		var entry: Dictionary = by_pilot[key]
		var reached: Dictionary = entry["reached"]
		var wins: Dictionary = entry["won"]
		reached[r.mission_id] = int(reached.get(r.mission_id, 0)) + 1
		if r.won():
			wins[r.mission_id] = int(wins.get(r.mission_id, 0)) + 1
	var rows: PackedStringArray = PackedStringArray()
	if order.is_empty():
		return rows
	order.sort()
	rows.append("| tier | pilot | campaigns | riverside won | the_ford reached / won | old_mill reached / won | cleared |")
	rows.append("|---|---|---|---|---|---|---|")
	for key: String in order:
		var entry: Dictionary = by_pilot[key]
		var reached: Dictionary = entry["reached"]
		var wins: Dictionary = entry["won"]
		var started: int = int(reached.get(&"riverside", 0))
		rows.append("| %d | %s | %d | %d | %d / %d | %d / %d | %s |" % [
			entry["tier"], entry["pilot"], started, int(wins.get(&"riverside", 0)),
			int(reached.get(&"the_ford", 0)), int(wins.get(&"the_ford", 0)),
			int(reached.get(&"old_mill", 0)), int(wins.get(&"old_mill", 0)),
			_pct(int(wins.get(&"old_mill", 0)), started),
		])
	return rows


# Timeouts and instant losses, group by group, with the seeds that reproduce
# them (SEED_BASE=<seed> SEEDS=1 and the group's other settings) and, for the
# first few timeouts, what the run left standing.
static func _anomalies(results: Array[PlaytestResult]) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for g: Dictionary in groups(results):
		var runs: Array[PlaytestResult] = g["runs"]
		var timeouts: Array[PlaytestResult] = []
		var instants: Array[PlaytestResult] = []
		var stuck: Array[PlaytestResult] = []
		for r: PlaytestResult in runs:
			if r.stuck_units > 0:
				stuck.append(r)
			if r.outcome == PlaytestResult.TIMEOUT:
				timeouts.append(r)
			for note: String in r.notes:
				if note.begins_with("instant loss"):
					instants.append(r)
					break
		if timeouts.is_empty() and instants.is_empty() and stuck.is_empty():
			continue
		var head: String = "%s tier %d %s" % [g["label"], g["tier"], g["pilot"]]
		if not timeouts.is_empty():
			out.append("- **%s: %d of %d timed out**, seeds %s." % [head, timeouts.size(), runs.size(), _seeds_text(timeouts)])
			for k: int in mini(MAX_DETAILED, timeouts.size()):
				out.append("  - seed %d: %s" % [timeouts[k].campaign_seed, "; ".join(timeouts[k].notes)])
		if not instants.is_empty():
			out.append("- **%s: %d instant loss(es)** (lost within a minute), seeds %s." % [head, instants.size(), _seeds_text(instants)])
		if not stuck.is_empty():
			var units: int = 0
			for r: PlaytestResult in stuck:
				units += r.stuck_units
			out.append("- %s: units stuck (walking 4 s without nearer a waypoint) in %d of %d runs, %d units in all, seeds %s." % [
				head, stuck.size(), runs.size(), units, _seeds_text(stuck),
			])
			for note: String in stuck[0].notes:
				if note.begins_with("stuck"):
					out.append("  - seed %d: %s" % [stuck[0].campaign_seed, note])
	if out.is_empty():
		out.append("None: no run timed out, none was lost within a minute, and no unit got stuck.")
	return out


static func _seeds_text(runs: Array[PlaytestResult]) -> String:
	var seeds: PackedStringArray = PackedStringArray()
	for k: int in mini(MAX_SEEDS_LISTED, runs.size()):
		seeds.append(str(runs[k].campaign_seed))
	var text: String = ", ".join(seeds)
	if runs.size() > MAX_SEEDS_LISTED:
		text += " and %d more" % (runs.size() - MAX_SEEDS_LISTED)
	return text


static func _pct(count: int, of_total: int) -> String:
	return "%.0f%%" % (100.0 * count / maxf(1.0, of_total))


# "a 3, b 1": counts, most first (ties by name).
static func _counts_text(counts: Dictionary[String, int]) -> String:
	if counts.is_empty():
		return "-"
	var names: Array[String] = []
	names.assign(counts.keys())
	names.sort_custom(func(a: String, b: String) -> bool:
		return counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
	var parts: PackedStringArray = PackedStringArray()
	for n: String in names:
		parts.append("%s %d" % [n, counts[n]])
	return ", ".join(parts)
