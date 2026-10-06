class_name CampaignComplete
extends MenuScreen
## The end of the campaign: how it went and who is left. Survivors with their
## kills (the whole roll, the reserve included), the enemies killed and
## soldiers lost over all the missions, and the roll of the fallen with where
## each one fell. Main menu is the only way out; the save keeps the finished
## campaign, which Continue shows again.

## Main menu, or Esc.
signal main_menu_pressed

## The two tables' column heads.
const SURVIVOR_COLUMNS: Array[String] = ["Name", "Type", "Kills", "Missions"]
const FALLEN_COLUMNS: Array[String] = ["Name", "Type", "Kills", "Fell at"]

var _menu: Button


## Builds the screen from the finished campaign.
func setup(campaign: CampaignDef, state: CampaignState, catalog: UnitCatalog) -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)
	var page: VBoxContainer = VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	margin.add_child(page)
	var title: Label = MenuKit.title("Campaign complete", 56, MenuKit.GOOD_COLOR)
	title.name = "Title"
	page.add_child(title)
	var kills: int = 0
	var losses: int = 0
	var ticks: int = 0
	for entry: Dictionary in state.history:
		kills += entry["kills"]
		losses += entry["losses"]
		ticks += entry["ticks"]
	# Whole seconds are the point, so the remainder is dropped on purpose.
	@warning_ignore("integer_division")
	var seconds: int = ticks / World.TICK_RATE
	var summary: Label = MenuKit.label(
		"%s   -   %d missions won   -   Enemies killed: %d   -   Soldiers lost: %d   -   Time %s" % [
			MenuKit.tier_name(state.tier), state.history.size(), kills, losses,
			MenuKit.clock(seconds),
		],
		MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	summary.name = "Summary"
	page.add_child(summary)

	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	var survivors: Array[Soldier] = state.soldiers.duplicate()
	survivors.sort_custom(_most_kills_first)
	_add_roll(body, "Survivors: %d" % survivors.size(), "SurvivorGrid", SURVIVOR_COLUMNS, survivors, campaign, catalog, false)
	_add_roll(body, "The fallen: %d" % state.fallen.size(), "FallenGrid", FALLEN_COLUMNS, state.fallen, campaign, catalog, true)

	var footer: HBoxContainer = HBoxContainer.new()
	page.add_child(footer)
	_menu = MenuKit.button("MainMenuButton", "Main menu", 220.0)
	_menu.pressed.connect(func() -> void: main_menu_pressed.emit())
	footer.add_child(_menu)
	if is_inside_tree():
		_focus_default()


func _focus_default() -> void:
	_focus(_menu)


func _cancel() -> bool:
	main_menu_pressed.emit()
	return true


# One side of the roll: a heading and a table. The fallen's last column is the
# mission they died in, the survivors' the missions they came through.
func _add_roll(
	body: HBoxContainer, heading: String, grid_name: String, columns: Array[String],
	soldiers: Array[Soldier], campaign: CampaignDef, catalog: UnitCatalog, fallen: bool
) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	body.add_child(scroll)
	var column: VBoxContainer = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	column.add_child(MenuKit.label(heading, MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR))
	var grid: GridContainer = GridContainer.new()
	grid.name = grid_name
	grid.columns = columns.size()
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	for column_name: String in columns:
		grid.add_child(MenuKit.label(column_name, 14, MenuKit.MUTED_COLOR))
	for soldier: Soldier in soldiers:
		var type: UnitType = catalog.find(soldier.type_id)
		grid.add_child(MenuKit.label(soldier.name, MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
		grid.add_child(MenuKit.label(type.display_name if type != null else String(soldier.type_id)))
		grid.add_child(MenuKit.label(str(soldier.kills)))
		grid.add_child(MenuKit.label(
			_mission_name(campaign, soldier.fallen_in) if fallen else str(soldier.missions),
			MenuKit.BODY_SIZE, MenuKit.BAD_COLOR if fallen else MenuKit.BODY_COLOR
		))
	if soldiers.is_empty():
		column.add_child(MenuKit.label("No one.", MenuKit.BODY_SIZE, MenuKit.MUTED_COLOR))


# Most kills first, then the earliest to join: a stable, total order.
static func _most_kills_first(a: Soldier, b: Soldier) -> bool:
	if a.kills != b.kills:
		return a.kills > b.kills
	return a.id < b.id


# The display name of the mission with this id, or the id if the campaign no
# longer has it.
static func _mission_name(campaign: CampaignDef, mission_id: StringName) -> String:
	for mission: MissionDef in campaign.missions:
		if mission.id == mission_id:
			return mission.display_name
	return String(mission_id)
