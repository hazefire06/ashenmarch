class_name SkirmishResults
extends MenuScreen
## The results screen after a skirmish: Victory, Defeat or Draw, why it ended,
## how long it took, the mode and each side's final score, and for each side a
## table of what it deployed and what it lost, by unit type.
##
## It shows a finished skirmish and decides nothing: Rematch, Change army and
## Main menu are signals for the App. Everything is read from what the sim
## froze at the decision (SkirmishRuntime: the score, end_tick, and final_alive,
## the snapshot of who stood on their side then), never from the units' state
## now: the world goes on being a world after the decision (a gas cloud can
## still kill a body that was already counted), and the table must match the
## score. A unit's type comes from the unit itself, which stays in the world
## after it dies.

## Rematch: the same armies on the same map, with a new seed.
signal rematch_pressed
## Change army: back to the setup screen, as this skirmish was set up.
signal change_army_pressed
## Main menu.
signal main_menu_pressed

## The tables' columns.
const COLUMNS: int = 3
const COLUMN_NAMES: Array[String] = ["Unit", "Deployed", "Lost"]
## The type of a unit the world no longer has (none is ever despawned in a
## skirmish, but a row must not vanish if one were).
const UNKNOWN_TYPE: String = "Unknown"

var _outcome: MissionRuntime.Outcome = MissionRuntime.Outcome.NONE
var _rematch: Button


## Builds the screen from a finished skirmish. `world` is read-only: its
## skirmish runtime and its units. `skirmish` is only for the name of the
## enemy's template (without it, the template's id is shown).
func setup(
	skirmish_setup: SkirmishSetup, world: World, outcome: MissionRuntime.Outcome,
	skirmish: SkirmishCatalog = null
) -> void:
	_outcome = outcome
	var runtime: SkirmishRuntime = world.skirmish if world != null else null
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 32)
	add_child(margin)
	var page: VBoxContainer = VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	margin.add_child(page)
	_build_header(page, skirmish_setup, world, runtime)
	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 28)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	if runtime != null:
		# The player's side first.
		var mine: int = skirmish_setup.player_faction()
		for side: int in [mine, 1 - mine]:
			_build_side(body, skirmish_setup, world, runtime, skirmish, side)
	_build_footer(page)
	if is_inside_tree():
		_focus_default()


## True for a victory.
func is_victory() -> bool:
	return _outcome == MissionRuntime.Outcome.WON


## True for a draw.
func is_draw() -> bool:
	return _outcome == MissionRuntime.Outcome.DRAW


## Why the skirmish ended, in words ("" if it hasn't).
static func reason_text(runtime: SkirmishRuntime) -> String:
	match runtime.end_reason:
		SkirmishRuntime.EndReason.TIME:
			return "Time ran out"
		SkirmishRuntime.EndReason.ELIMINATION:
			if runtime.winner == SkirmishRuntime.DRAW:
				return "Both sides were wiped out"
			return "%s was wiped out" % SkirmishMenu.side_name(1 - runtime.winner)
	return ""


## A side's final score in the words of the mode: kills, time on the hill, or
## flags (with how long they were held, which is what breaks a tie).
static func score_text(runtime: SkirmishRuntime, side: int) -> String:
	match runtime.rules.mode:
		SkirmishRules.Mode.BODY_COUNT:
			return "Kills: %d" % runtime.score(side)
		SkirmishRules.Mode.KING_OF_THE_HILL:
			return "Hill held: %s" % _clock_of(runtime.hold_ticks[side])
		SkirmishRules.Mode.CAPTURE_THE_FLAGS:
			return "Flags: %d of %d (held for %s)" % [
				runtime.flags_owned(side), runtime.rules.flag_count(), _clock_of(runtime.owned_ticks[side])
			]
	return ""


func _focus_default() -> void:
	_focus(_rematch)


# Esc has no meaning here: every way out is a choice about what comes next.
func _cancel() -> bool:
	return false


func _build_header(
	page: VBoxContainer, skirmish_setup: SkirmishSetup, world: World, runtime: SkirmishRuntime
) -> void:
	var text: String = "Draw"
	var color: Color = MenuKit.WARN_COLOR
	if _outcome == MissionRuntime.Outcome.WON:
		text = "Victory"
		color = MenuKit.GOOD_COLOR
	elif _outcome == MissionRuntime.Outcome.LOST:
		text = "Defeat"
		color = MenuKit.BAD_COLOR
	var title: Label = MenuKit.title(text, 56, color)
	title.name = "Outcome"
	page.add_child(title)
	if runtime == null:
		return
	var reason: Label = MenuKit.label(reason_text(runtime), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR)
	reason.name = "Reason"
	page.add_child(reason)
	var ended: int = runtime.end_tick if runtime.end_tick >= 0 else world.tick
	@warning_ignore("integer_division")
	var seconds: int = (ended - runtime.start_tick) / World.TICK_RATE
	var line: Label = MenuKit.label(
		"%s   -   %s   -   Time %s" % [
			SkirmishMenu.mode_name(runtime.rules.mode), skirmish_setup.map.display_name,
			MenuKit.clock(seconds)
		],
		14, MenuKit.MUTED_COLOR
	)
	line.name = "MatchLine"
	page.add_child(line)


# One side's column: who it was, its score, and what it deployed and lost.
func _build_side(
	body: HBoxContainer, skirmish_setup: SkirmishSetup, world: World, runtime: SkirmishRuntime,
	skirmish: SkirmishCatalog, side: int
) -> void:
	var scroll: ScrollContainer = MenuKit.scroller()
	body.add_child(scroll)
	var column: VBoxContainer = VBoxContainer.new()
	column.name = "Side%d" % side
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	var heading: Label = MenuKit.label(
		_heading_text(skirmish_setup, skirmish, side), MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR
	)
	heading.name = "Heading%d" % side
	column.add_child(heading)
	var score: Label = MenuKit.label(score_text(runtime, side))
	score.name = "Score%d" % side
	column.add_child(score)
	var grid: GridContainer = GridContainer.new()
	grid.name = "Table%d" % side
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	for column_name: String in COLUMN_NAMES:
		grid.add_child(MenuKit.label(column_name, 14, MenuKit.MUTED_COLOR))
	_fill_table(grid, world, runtime, side)


# "Light (you)", or "Dark (AI: Horde)" for the enemy's side.
func _heading_text(skirmish_setup: SkirmishSetup, skirmish: SkirmishCatalog, side: int) -> String:
	var side_text: String = SkirmishMenu.side_name(side)
	if side == skirmish_setup.player_faction():
		return "%s (you)" % side_text
	var template_name: String = String(skirmish_setup.ai_template_id)
	if skirmish != null:
		var template: ArmyTemplate = skirmish.template(skirmish_setup.ai_template_id)
		if template != null:
			template_name = template.display_name
	if template_name.is_empty():
		return "%s (AI)" % side_text
	return "%s (AI: %s)" % [side_text, template_name]


# A row per unit type the side fielded, in catalog order, and the totals. From
# the roster the sim recorded at the start and the snapshot it took at the
# decision.
func _fill_table(grid: GridContainer, world: World, runtime: SkirmishRuntime, side: int) -> void:
	var roster: PackedInt32Array = runtime.roster_ids[side]
	var survived: PackedByteArray = runtime.final_alive[side]
	var known: bool = survived.size() == roster.size()
	# Per catalog index (-1: no longer in the world): deployed, then lost.
	var tally: Dictionary[int, PackedInt32Array] = {}
	var names: Dictionary[int, String] = {}
	var deployed_total: int = 0
	var lost_total: int = 0
	for k: int in roster.size():
		var unit: Unit = world.get_unit(roster[k])
		var key: int = unit.type_index if unit != null else -1
		if not tally.has(key):
			tally[key] = PackedInt32Array([0, 0])
			names[key] = unit.type.display_name if unit != null else UNKNOWN_TYPE
		tally[key][0] += 1
		deployed_total += 1
		if known and survived[k] == 0:
			tally[key][1] += 1
			lost_total += 1
	var keys: Array[int] = []
	for key: int in tally:
		keys.append(key)
	keys.sort()
	for key: int in keys:
		grid.add_child(MenuKit.label(names[key], MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
		grid.add_child(MenuKit.label(str(tally[key][0])))
		grid.add_child(_lost_label(tally[key][1]))
	grid.add_child(MenuKit.label("Total", MenuKit.BODY_SIZE, MenuKit.TEXT_COLOR))
	grid.add_child(MenuKit.label(str(deployed_total)))
	grid.add_child(_lost_label(lost_total))


# Losses in red, a clean sheet in the ordinary colour.
static func _lost_label(lost: int) -> Label:
	return MenuKit.label(str(lost), MenuKit.BODY_SIZE, MenuKit.BAD_COLOR if lost > 0 else MenuKit.BODY_COLOR)


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
	var change: Button = MenuKit.button("ChangeArmyButton", "Change army", 200.0)
	change.pressed.connect(func() -> void: change_army_pressed.emit())
	footer.add_child(change)
	_rematch = MenuKit.button("RematchButton", "Rematch", 220.0)
	_rematch.pressed.connect(func() -> void: rematch_pressed.emit())
	footer.add_child(_rematch)


# Ticks as m:ss.
static func _clock_of(ticks: int) -> String:
	@warning_ignore("integer_division")
	return MenuKit.clock(ticks / World.TICK_RATE)
