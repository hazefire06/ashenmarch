extends SceneTree
## Where a sim tick's time goes: `make profile-sim` (headless). Plays the
## benchmark's load (BenchScenario: 100 units fighting, 200 projectiles in the
## air) for TICKS ticks and times each stage of World.step() by running the
## stages itself, in World.step()'s order. The sim can't time itself (no clock
## in sim/), hence this mirror.
##
## The mirror is checked: a second world, fed the same top-ups, takes real
## World.step() calls alongside, and the two must hash alike at the end. If
## they don't, World.step() changed and this file needs the same change; it
## says so and exits 1.
##
## Prints mean and max milliseconds per stage, and the stages of the slowest
## ticks. Settings: TICKS=1800, PROJECTILES=200.

const CATALOG_PATH: String = "res://data/units/catalog.tres"
const STAGES: PackedStringArray = [
	"commands", "mission", "skirmish", "ai", "weather", "statuses", "melee", "errands", "ranged",
	"movement", "integrate", "projectiles", "explosions", "fire", "cleanup",
]
const WORST: int = 5


func _initialize() -> void:
	quit(_run())


func _run() -> int:
	var catalog: UnitCatalog = load(CATALOG_PATH) as UnitCatalog
	var ticks: int = int(_env("TICKS", "1800"))
	var target: int = int(_env("PROJECTILES", "200"))
	var timed: World = SkirmishSetup.create_world(BenchScenario.setup(), catalog)
	var check: World = SkirmishSetup.create_world(BenchScenario.setup(), catalog)
	var load_a: BenchScenario = BenchScenario.new(catalog, target)
	var load_b: BenchScenario = BenchScenario.new(catalog, target)
	var totals: PackedFloat64Array = PackedFloat64Array()
	totals.resize(STAGES.size())
	var maxima: PackedFloat64Array = PackedFloat64Array()
	maxima.resize(STAGES.size())
	var per_tick: Array[PackedFloat64Array] = []
	for t: int in ticks:
		load_a.between_ticks(timed)
		load_b.between_ticks(check)
		var stage_ms: PackedFloat64Array = _step_timed(timed)
		check.step()
		per_tick.append(stage_ms)
		for i: int in STAGES.size():
			totals[i] += stage_ms[i]
			maxima[i] = maxf(maxima[i], stage_ms[i])
	if timed.state_hash() != check.state_hash():
		printerr("profile_sim: the mirror no longer matches World.step(); update _step_timed")
		return 1
	var total: float = 0.0
	for v: float in totals:
		total += v
	print("profile_sim: %d ticks, %d units alive, %d projectiles in the air at the end, %.2f ms/tick mean" % [
		ticks, load_a.alive, load_a.flying, total / ticks,
	])
	for i: int in STAGES.size():
		print("  %-12s mean %6.3f ms  max %7.2f ms  %5.1f%%" % [
			STAGES[i], totals[i] / ticks, maxima[i], 100.0 * totals[i] / maxf(total, 0.001),
		])
	var order: Array[int] = []
	for t: int in per_tick.size():
		order.append(t)
	order.sort_custom(func(a: int, b: int) -> bool: return _sum(per_tick[a]) > _sum(per_tick[b]))
	print("  slowest ticks:")
	for k: int in mini(WORST, order.size()):
		var t: int = order[k]
		var parts: PackedStringArray = PackedStringArray()
		for i: int in STAGES.size():
			if per_tick[t][i] >= 0.5:
				parts.append("%s %.1f" % [STAGES[i], per_tick[t][i]])
		print("    tick %d: %.1f ms (%s)" % [t, _sum(per_tick[t]), ", ".join(parts)])
	return 0


# World.step(), stage by stage, timed. Keep in step with World.step().
func _step_timed(w: World) -> PackedFloat64Array:
	var ms: PackedFloat64Array = PackedFloat64Array()
	ms.resize(STAGES.size())
	w.combat_events.clear()
	w.projectile_events.clear()
	w.ai_events.clear()
	w.mission_events.clear()
	w.projectile_pass_begun = false
	if w.fire != null:
		w.fire.changed.clear()
	var t: int = Time.get_ticks_usec()
	w._apply_commands()
	t = _lap(ms, 0, t)
	if w.mission != null:
		w.mission.update(w)
	t = _lap(ms, 1, t)
	if w.skirmish != null:
		w.skirmish.update(w)
	t = _lap(ms, 2, t)
	if not w.ai.groups.is_empty():
		w.ai.update(w)
	t = _lap(ms, 3, t)
	w.weather.update(w.tick)
	t = _lap(ms, 4, t)
	if w.terrain != null:
		w.statuses.update(w)
		t = _lap(ms, 5, t)
		w.combat.update(w)
		t = _lap(ms, 6, t)
		w.interactions.update(w)
		t = _lap(ms, 7, t)
		w.ranged.update(w)
		t = _lap(ms, 8, t)
		w.movement.update(w)
		t = _lap(ms, 9, t)
	w._integrate()
	t = _lap(ms, 10, t)
	if w.terrain != null and w.catalog != null:
		w.projectile_pass_begun = true
		w.projectile_system.update(w)
		t = _lap(ms, 11, t)
		w.explosions.resolve(w, w.projectile_system.grid)
		t = _lap(ms, 12, t)
		w.fire.update(w)
		t = _lap(ms, 13, t)
		w._drop_removed_projectiles()
		w._drop_spent_clouds()
		t = _lap(ms, 14, t)
	w.projectile_pass_begun = false
	w.tick += 1
	return ms


static func _lap(ms: PackedFloat64Array, stage: int, since_us: int) -> int:
	var now: int = Time.get_ticks_usec()
	ms[stage] += (now - since_us) / 1000.0
	return now


static func _sum(values: PackedFloat64Array) -> float:
	var total: float = 0.0
	for v: float in values:
		total += v
	return total


static func _env(key: String, fallback: String) -> String:
	var value: String = OS.get_environment(key)
	return value if value != "" else fallback
