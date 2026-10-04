class_name Results
extends MenuScreen
## The results screen after a mission: Victory or Defeat, how long it took, who
## fell and to what, what was killed, how each objective ended, and a table of
## every soldier who deployed (what he did this mission, what his kills have
## made of him, how he stands, and whether he lived).
##
## It shows a finished mission and decides nothing: Continue (after a victory),
## Retry (after a defeat) and Main menu are signals, and the App commits the
## victory (CampaignState.apply_victory) or drops the defeat. Everything is
## read from what the mission left: `stats` for time, kills, losses and
## friendly fire; `world` for each soldier's final health and the objectives'
## final states; `plan` for who he is and what he deployed with.

## After a victory, Continue: apply it, save, and go on.
signal continue_pressed
## After a defeat, Retry: from the saved campaign, with the same seed.
signal retry_pressed
## Main menu, either way. After a victory the App applies and saves first.
signal main_menu_pressed

## The soldier table's columns, and the two notes under the title.
const COLUMNS: int = 9
const COLUMN_NAMES: Array[String] = ["Name", "Type", "Kills", "Total", "Acc", "Rate", "Speed", "HP", "Status"]
const DEFEAT_NOTE: String = "Nothing from this attempt is kept. Retry starts again from your saved campaign."
const VICTORY_NOTE: String = "Survivors and their wounds go on to the next mission."

var _won: bool = false
var _continue: Button
var _retry: Button


## Builds the screen from a finished mission. `world` is read-only: its units
## give the final health and its mission the objectives' final states (either
## may be missing and the part that needs it is left out).
func setup(
	outcome: MissionRuntime.Outcome, stats: MissionStats, mission: MissionDef, plan: DeployPlan,
	world: World, catalog: UnitCatalog
) -> void:
	_won = outcome == MissionRuntime.Outcome.WON
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)
	var page: VBoxContainer = VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	margin.add_child(page)
	_build_header(page, stats, mission)
	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	_build_summary(body, stats, plan, world, catalog)
	_build_soldiers(body, stats, plan, world, catalog)
	_build_footer(page)
	if is_inside_tree():
		_focus_default()


## True for a victory.
func is_victory() -> bool:
	return _won


func _focus_default() -> void:
	_focus(_continue if _won else _retry)


# Esc has no meaning here: both ways out change what happens to the campaign.
func _cancel() -> bool:
	return false


func _build_header(page: VBoxContainer, stats: MissionStats, mission: MissionDef) -> void:
	var title: Label = MenuKit.title(
		"Victory" if _won else "Defeat", 56, MenuKit.GOOD_COLOR if _won else MenuKit.BAD_COLOR
	)
	title.name = "Outcome"
	page.add_child(title)
	var line: Label = MenuKit.label(
		"%s   -   Time %s" % [mission.display_name, MenuKit.clock(stats.seconds())],
		MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	line.name = "MissionLine"
	page.add_child(line)
	var note: Label = MenuKit.label(VICTORY_NOTE if _won else DEFEAT_NOTE, 14, MenuKit.MUTED_COLOR)
	note.name = "Note"
	page.add_child(note)


func _build_summary(
	body: HBoxContainer, stats: MissionStats, plan: DeployPlan, world: World, catalog: UnitCatalog
) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	scroll.size_flags_stretch_ratio = 0.8
	body.add_child(scroll)
	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	scroll.add_child(column)

	column.add_child(MenuKit.label("Enemies killed: %d" % stats.enemies_killed(), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
	var killed: VBoxContainer = VBoxContainer.new()
	killed.name = "EnemiesKilled"
	column.add_child(killed)
	for type_id: StringName in _kill_order(stats):
		killed.add_child(MenuKit.label("%s: %d" % [_type_name(catalog, type_id), stats.enemy_dead[type_id]]))

	column.add_child(MenuKit.label("Light losses: %d" % stats.lost.size(), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
	var lost: VBoxContainer = VBoxContainer.new()
	lost.name = "Losses"
	column.add_child(lost)
	if stats.lost.is_empty():
		lost.add_child(MenuKit.label("None", MenuKit.BODY_SIZE, MenuKit.GOOD_COLOR))
	for id: int in stats.lost:
		lost.add_child(MenuKit.label(_soldier_label(plan, catalog, id)))

	column.add_child(MenuKit.label(
		"Lost to friendly fire: %d" % stats.friendly_fire.size(), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	))
	var friendly: VBoxContainer = VBoxContainer.new()
	friendly.name = "FriendlyFire"
	column.add_child(friendly)
	for id: int in stats.friendly_fire:
		friendly.add_child(MenuKit.label(_soldier_label(plan, catalog, id), MenuKit.BODY_SIZE, MenuKit.WARN_COLOR))

	var runtime: MissionRuntime = world.mission if world != null else null
	if runtime != null:
		column.add_child(MenuKit.label("Objectives", MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
		var objectives: VBoxContainer = VBoxContainer.new()
		objectives.name = "Objectives"
		column.add_child(objectives)
		for i: int in runtime.objective_count():
			_add_objective(objectives, runtime, i)


func _add_objective(list: VBoxContainer, runtime: MissionRuntime, i: int) -> void:
	var state: MissionRuntime.ObjectiveState = runtime.objective_state(i)
	if state == MissionRuntime.ObjectiveState.HIDDEN:
		return
	var verdict: String = "Not done"
	var color: Color = MenuKit.MUTED_COLOR
	if state == MissionRuntime.ObjectiveState.DONE:
		verdict = "Done"
		color = MenuKit.GOOD_COLOR
	elif state == MissionRuntime.ObjectiveState.FAILED:
		verdict = "Failed"
		color = MenuKit.BAD_COLOR
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	list.add_child(row)
	var mark: Label = MenuKit.label(verdict, MenuKit.BODY_SIZE, color)
	mark.custom_minimum_size.x = 70.0
	row.add_child(mark)
	row.add_child(MenuKit.paragraph(runtime.objective_text(i) + (" (optional)" if runtime.objective_optional(i) else "")))


func _build_soldiers(
	body: HBoxContainer, stats: MissionStats, plan: DeployPlan, world: World, catalog: UnitCatalog
) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	scroll.size_flags_stretch_ratio = 1.3
	body.add_child(scroll)
	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	column.add_child(MenuKit.label("Soldiers", MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
	var grid: GridContainer = GridContainer.new()
	grid.name = "SoldierGrid"
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	for column_name: String in COLUMN_NAMES:
		grid.add_child(MenuKit.label(column_name, 14, MenuKit.MUTED_COLOR))
	var units: Dictionary[int, Unit] = {}
	if world != null:
		for unit: Unit in world.units:
			if unit.soldier_id != 0:
				units[unit.soldier_id] = unit
	for i: int in plan.size():
		_add_soldier_row(grid, stats, plan, i, units.get(plan.soldier_ids[i]), catalog)


func _add_soldier_row(
	grid: GridContainer, stats: MissionStats, plan: DeployPlan, slot: int, unit: Unit, catalog: UnitCatalog
) -> void:
	var id: int = plan.soldier_ids[slot]
	var type: UnitType = catalog.find(plan.type_ids[slot])
	var total: int = plan.kills[slot] + stats.kills_of(id)
	var fallen: bool = stats.was_lost(id)
	var max_hp: int = type.max_hp if type != null else 0
	var hp_text: String = "-"
	var hp_color: Color = MenuKit.BODY_COLOR
	if not fallen and unit != null:
		hp_text = "%d/%d" % [unit.hp, max_hp]
		if unit.hp < max_hp:
			hp_color = MenuKit.WARN_COLOR
	var status: String = "Survived"
	var status_color: Color = MenuKit.GOOD_COLOR
	if fallen:
		status = "Fallen"
		status_color = MenuKit.BAD_COLOR
	elif plan.is_recruit[slot]:
		status = "Recruit"
		status_color = MenuKit.TEXT_COLOR
	grid.add_child(MenuKit.label(plan.names[slot], MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
	grid.add_child(MenuKit.label(_type_name(catalog, plan.type_ids[slot])))
	grid.add_child(MenuKit.label(str(stats.kills_of(id))))
	grid.add_child(MenuKit.label(str(total)))
	grid.add_child(MenuKit.label(MenuKit.bonus_text(type.veterancy_accuracy_permille if type != null else 0, total)))
	grid.add_child(MenuKit.label(MenuKit.bonus_text(type.veterancy_attack_rate_permille if type != null else 0, total)))
	grid.add_child(MenuKit.label(MenuKit.bonus_text(type.veterancy_speed_permille if type != null else 0, total)))
	grid.add_child(MenuKit.label(hp_text, MenuKit.BODY_SIZE, hp_color))
	grid.add_child(MenuKit.label(status, MenuKit.BODY_SIZE, status_color))


func _build_footer(page: VBoxContainer) -> void:
	var footer: HBoxContainer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	page.add_child(footer)
	var menu: Button = MenuKit.button("MainMenuButton", "Main menu", 200.0)
	menu.pressed.connect(func() -> void: main_menu_pressed.emit())
	footer.add_child(menu)
	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	if _won:
		_continue = MenuKit.button("ContinueButton", "Continue", 220.0)
		_continue.pressed.connect(func() -> void: continue_pressed.emit())
		footer.add_child(_continue)
	else:
		_retry = MenuKit.button("RetryButton", "Retry", 220.0)
		_retry.pressed.connect(func() -> void: retry_pressed.emit())
		footer.add_child(_retry)


# The enemy types that died, most first, ties by id so the order is stable.
static func _kill_order(stats: MissionStats) -> Array[StringName]:
	var order: Array[StringName] = []
	for type_id: StringName in stats.enemy_dead:
		order.append(type_id)
	order.sort_custom(func(a: StringName, b: StringName) -> bool:
		if stats.enemy_dead[a] != stats.enemy_dead[b]:
			return stats.enemy_dead[a] > stats.enemy_dead[b]
		return String(a) < String(b)
	)
	return order


static func _type_name(catalog: UnitCatalog, type_id: StringName) -> String:
	var type: UnitType = catalog.find(type_id)
	return type.display_name if type != null else String(type_id)


# "Ailsa (Longbow)" for a deployed soldier; a soldier the plan doesn't know
# (it can't happen from a real mission) is only a number.
static func _soldier_label(plan: DeployPlan, catalog: UnitCatalog, soldier_id: int) -> String:
	var slot: int = plan.soldier_ids.find(soldier_id)
	if slot < 0:
		return "Soldier %d" % soldier_id
	return "%s (%s)" % [plan.names[slot], _type_name(catalog, plan.type_ids[slot])]
