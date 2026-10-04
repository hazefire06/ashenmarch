class_name ViewFixtures
extends RefCounted
## Builders for the tests that run MainView on a campaign mission: a tiny flat
## map written to user:// (the sim loads maps from PNG files, so a map has to
## be on disk), a MissionDef over it with a one-soldier roster and a script
## that wins after a given number of ticks, and the MissionLaunch for it.
## Tiny and quiet so a test can step the real scene in no time; the shipped
## catalog is used, since MainView loads it itself.

const M: int = 1000
## The map's width and depth in samples, one meter apart.
const SIZE: int = 60
const MAP_DIR: String = "user://test_view_map"
const HEIGHT_PATH: String = MAP_DIR + "/height.png"
const MASK_PATH: String = MAP_DIR + "/mask.png"
## Where the roster stands and the camera looks, in meters.
const DEPLOY_AT: Vector2i = Vector2i(30, 30)
## Win after this many ticks to never win inside a test.
const NEVER: int = 1_000_000_000


## The tiny map: flat dry grass, 60 x 60 samples a meter apart. The PNG files
## are written the first time and kept until cleanup().
static func map() -> MapInfo:
	if not FileAccess.file_exists(HEIGHT_PATH) or not FileAccess.file_exists(MASK_PATH):
		DirAccess.make_dir_recursive_absolute(MAP_DIR)
		var height: Image = Image.create(SIZE, SIZE, false, Image.FORMAT_L8)
		height.fill(Color.BLACK)
		height.save_png(HEIGHT_PATH)
		# R water, G ground, B blocked: all zero is dry open grass.
		var mask: Image = Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
		mask.fill(Color.BLACK)
		mask.save_png(MASK_PATH)
	var info: MapInfo = MapInfo.new()
	info.display_name = "Test Flat"
	info.heightmap_path = HEIGHT_PATH
	info.mask_path = MASK_PATH
	info.cell_size = M
	info.max_height = M
	info.max_walkable_slope = M
	return info


## Removes what map() wrote.
static func cleanup() -> void:
	for path: String in [HEIGHT_PATH, MASK_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(MAP_DIR)


## A mission on the tiny map: one Shieldman deploys, the Dark side has one idle
## Husk group in the far corner, the player wins when the TIMER has run
## `win_ticks` ticks (0 wins on the first step, NEVER never), and there are
## two objectives, one shown from the start and one revealed later.
static func mission(win_ticks: int = NEVER, atmosphere: Atmosphere = null) -> MissionDef:
	var win: TriggerAction = MissionFixtures.action(TriggerAction.Kind.WIN)
	var timer: TriggerSpec = MissionFixtures.timer(&"win", win_ticks)
	timer.actions = [win]
	var rules: MissionScript = MissionFixtures.script(
		[MissionFixtures.group(&"husks", 1, 5, 5)], [timer],
		[
			MissionFixtures.objective(&"hold", "Hold the field"),
			MissionFixtures.objective(&"extra", "Take the hill", true, false),
		]
	)
	var def: MissionDef = MissionDef.new()
	def.id = &"test_flat"
	def.display_name = "Test Flat"
	def.map = map()
	def.rules = rules
	var entry: RosterEntry = RosterEntry.new()
	entry.type_id = &"shieldman"
	def.roster = [entry]
	def.deploy = PackedInt32Array([DEPLOY_AT.x * M, DEPLOY_AT.y * M])
	def.camera_start = PackedInt32Array([20 * M, 25 * M])
	def.camera_distance = 40 * M
	def.atmosphere = atmosphere
	return def


## The launch of that mission at tier 2 with seed 1, the roster planned from a
## fresh campaign. `campaign` false is the development kind (the debug keys
## stay on, losing focus doesn't pause).
static func launch(
	win_ticks: int = NEVER, atmosphere: Atmosphere = null, campaign: bool = true
) -> MissionLaunch:
	var def: MissionDef = mission(win_ticks, atmosphere)
	var state: CampaignState = CampaignState.new_campaign(1, 2)
	var plan: DeployPlan = state.plan_deploy(def, PackedInt32Array(), PackedStringArray(["Ada"]))
	return MissionLaunch.new(def, 2, 1, plan.command(0, def), campaign)
