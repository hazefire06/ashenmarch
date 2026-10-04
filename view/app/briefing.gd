class_name Briefing
extends MenuScreen
## The mission briefing: what the mission is, what it asks, and who goes.
## - The text and the objectives that show from the start (the hidden ones are
##   the mission's surprises).
## - The roster slot by slot, from CampaignState.plan_deploy: a veteran with his
##   kills, what they have earned him (accuracy, attack rate and speed bonuses
##   as percentages of his type's caps) and his health, or a recruit.
## - A Bench checkbox on every fielded veteran, so a wounded one can sit this
##   out: the plan is made again, and the next best veteran of the type (or a
##   recruit) takes his slot. A benched veteran waits in the reserve list with
##   his box still ticked, to be put back.
## - The reserve: everyone alive who isn't going.
## Nothing here changes the campaign: the plan is only a plan until the mission
## is won (CampaignState.apply_victory), so the player can bench and unbench
## freely. Start hands the plan and the bench to the App, which must build the
## mission from that very plan.

## Start was pressed: this plan is the one to field.
signal start_pressed(plan: DeployPlan, benched: PackedInt32Array)
## Back or Esc: leave without starting.
signal back_pressed

## The roster tables' columns: bench box, name, type, kills, the three bonuses, hp.
const COLUMNS: int = 8
const COLUMN_NAMES: Array[String] = ["", "Name", "Type", "Kills", "Acc", "Rate", "Speed", "HP"]
## The tooltip on a bench box, and the key to the bonus columns under the lists.
const BENCH_HINT: String = "Leave this veteran out; the next best veteran or a recruit takes his place."
const BONUS_HINT: String = "Acc: accuracy, Rate: attack rate, Speed: move speed. Each kill adds less than the one before."

var _campaign: CampaignDef
var _state: CampaignState
var _catalog: UnitCatalog
var _mission: MissionDef
var _plan: DeployPlan
var _benched: PackedInt32Array = PackedInt32Array()
var _roster_box: VBoxContainer
var _start: Button


## Builds the briefing for the campaign's next mission. `benched` is who the
## player had already benched (a Retry keeps it); ids that aren't on the roll
## any more are dropped.
func setup(
	campaign: CampaignDef, state: CampaignState, catalog: UnitCatalog,
	already_benched: PackedInt32Array = PackedInt32Array()
) -> void:
	_campaign = campaign
	_state = state
	_catalog = catalog
	_mission = campaign.missions[state.mission_index]
	for id: int in already_benched:
		if state.find_soldier(id) != null and not _benched.has(id):
			_benched.append(id)
	_plan = state.plan_deploy(_mission, _benched, campaign.soldier_names)
	_build()
	if is_inside_tree():
		_focus_default()


## The roster that would deploy now.
func plan() -> DeployPlan:
	return _plan


## The soldiers benched so far.
func benched() -> PackedInt32Array:
	return _benched


## Benches or un-benches a soldier and plans again: what the Bench checkboxes do.
func set_benched(soldier_id: int, on: bool) -> void:
	var at: int = _benched.find(soldier_id)
	if on and at < 0:
		_benched.append(soldier_id)
	elif not on and at >= 0:
		_benched.remove_at(at)
	else:
		return
	_plan = _state.plan_deploy(_mission, _benched, _campaign.soldier_names)
	_fill_roster()
	# The box that was clicked is gone (the lists were rebuilt); keep the
	# keyboard on its replacement so Space can flip it back.
	var again: CheckBox = find_child("Bench%d" % soldier_id, true, false) as CheckBox
	_focus(again if again != null else _start)


func _focus_default() -> void:
	_focus(_start)


func _cancel() -> bool:
	back_pressed.emit()
	return true


func _build() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)
	var page: VBoxContainer = VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	margin.add_child(page)
	_build_header(page)
	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	_build_mission_column(body)
	_build_roster_column(body)
	var footer: HBoxContainer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	page.add_child(footer)
	var back: Button = MenuKit.button("BackButton", "Back", 160.0)
	back.pressed.connect(func() -> void: back_pressed.emit())
	footer.add_child(back)
	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_start = MenuKit.button("StartButton", "Start mission", 220.0)
	_start.pressed.connect(func() -> void: start_pressed.emit(_plan, _benched))
	footer.add_child(_start)


func _build_header(page: VBoxContainer) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	page.add_child(row)
	var names: VBoxContainer = VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(names)
	var count: Label = MenuKit.label(
		"Mission %d of %d" % [_state.mission_index + 1, _campaign.missions.size()], 14, MenuKit.MUTED_COLOR
	)
	count.name = "MissionCount"
	names.add_child(count)
	var title: Label = MenuKit.title(_mission.display_name)
	title.name = "MissionName"
	names.add_child(title)
	var difficulty: Label = MenuKit.label(
		"Difficulty: %s" % MenuKit.tier_name(_state.tier), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	difficulty.name = "Difficulty"
	difficulty.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(difficulty)


func _build_mission_column(body: HBoxContainer) -> void:
	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_stretch_ratio = 0.9
	column.add_theme_constant_override("separation", 10)
	body.add_child(column)
	# The story scrolls; the objectives, which matter more, stay in view under it.
	var scroll: ScrollContainer = MenuKit.scroller()
	column.add_child(scroll)
	var text: Label = MenuKit.paragraph(_mission.briefing)
	text.name = "BriefingText"
	scroll.add_child(text)
	column.add_child(MenuKit.label("Objectives", MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
	var list: VBoxContainer = VBoxContainer.new()
	list.name = "Objectives"
	column.add_child(list)
	for objective: ObjectiveSpec in _mission.rules.objectives:
		if not objective.shown_at_start:
			continue
		var line: String = "- " + objective.text + (" (optional)" if objective.optional else "")
		list.add_child(MenuKit.paragraph(line))


func _build_roster_column(body: HBoxContainer) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	scroll.size_flags_stretch_ratio = 1.2
	body.add_child(scroll)
	_roster_box = VBoxContainer.new()
	_roster_box.name = "RosterBox"
	_roster_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_roster_box)
	_fill_roster()


# The roster and reserve lists, from the current plan. Rebuilt whole on every
# bench change: it is a few dozen labels.
func _fill_roster() -> void:
	MenuKit.clear(_roster_box)
	var veterans: int = 0
	for recruit: bool in _plan.is_recruit:
		if not recruit:
			veterans += 1
	var heading: Label = MenuKit.label(
		"Roster: %d soldiers (%d veterans, %d recruits)" % [_plan.size(), veterans, _plan.size() - veterans],
		MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	heading.name = "RosterHeading"
	_roster_box.add_child(heading)
	var grid: GridContainer = _new_grid("RosterGrid")
	for i: int in _plan.size():
		if _plan.is_recruit[i]:
			_add_recruit_row(grid, i)
		else:
			_add_veteran_row(grid, _state.find_soldier(_plan.soldier_ids[i]), true)
	var reserve: Array[Soldier] = _state.reserve_for(_mission, _benched)
	if reserve.is_empty():
		return
	var reserve_heading: Label = MenuKit.label(
		"Reserve: %d" % reserve.size(), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	reserve_heading.name = "ReserveHeading"
	_roster_box.add_child(reserve_heading)
	var reserve_grid: GridContainer = _new_grid("ReserveGrid")
	for soldier: Soldier in reserve:
		_add_veteran_row(reserve_grid, soldier, false)
	var hint: Label = MenuKit.paragraph(BONUS_HINT, 13, MenuKit.MUTED_COLOR)
	_roster_box.add_child(hint)


func _new_grid(grid_name: String) -> GridContainer:
	var grid: GridContainer = GridContainer.new()
	grid.name = grid_name
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	_roster_box.add_child(grid)
	for column_name: String in COLUMN_NAMES:
		grid.add_child(MenuKit.label(column_name, 14, MenuKit.MUTED_COLOR))
	return grid


# A veteran: his bench box (on a fielded one; on a reserve one only if he is
# benched, ticked), name, type, kills, bonuses and health.
func _add_veteran_row(grid: GridContainer, soldier: Soldier, fielded: bool) -> void:
	if fielded or _benched.has(soldier.id):
		var box: CheckBox = CheckBox.new()
		box.name = "Bench%d" % soldier.id
		box.tooltip_text = BENCH_HINT
		MenuKit.style_check(box)
		box.set_pressed_no_signal(_benched.has(soldier.id))
		box.toggled.connect(func(on: bool) -> void: set_benched(soldier.id, on))
		grid.add_child(box)
	else:
		grid.add_child(Control.new())
	var type: UnitType = _catalog.find(soldier.type_id)
	var max_hp: int = type.max_hp if type != null else 0
	var hp: int = soldier.current_hp(max_hp)
	var wounded: bool = hp < max_hp
	grid.add_child(MenuKit.label(soldier.name, MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
	grid.add_child(MenuKit.label(_type_name(soldier.type_id)))
	grid.add_child(MenuKit.label(str(soldier.kills)))
	grid.add_child(MenuKit.label(MenuKit.bonus_text(type.veterancy_accuracy_permille if type != null else 0, soldier.kills)))
	grid.add_child(MenuKit.label(MenuKit.bonus_text(type.veterancy_attack_rate_permille if type != null else 0, soldier.kills)))
	grid.add_child(MenuKit.label(MenuKit.bonus_text(type.veterancy_speed_permille if type != null else 0, soldier.kills)))
	grid.add_child(MenuKit.label("%d/%d" % [hp, max_hp], MenuKit.BODY_SIZE, MenuKit.WARN_COLOR if wounded else MenuKit.BODY_COLOR))


# A recruit: just a name, a type and the word.
func _add_recruit_row(grid: GridContainer, slot: int) -> void:
	grid.add_child(Control.new())
	grid.add_child(MenuKit.label(_plan.names[slot], MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
	grid.add_child(MenuKit.label(_type_name(_plan.type_ids[slot])))
	grid.add_child(MenuKit.label("Recruit", MenuKit.BODY_SIZE, MenuKit.MUTED_COLOR))
	for _blank: int in COLUMNS - 4:
		grid.add_child(Control.new())


func _type_name(type_id: StringName) -> String:
	var type: UnitType = _catalog.find(type_id)
	return type.display_name if type != null else String(type_id)
