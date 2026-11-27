extends GutTest
## RtsCamera's framing (A5): the default zoom is close and fairly top-down, at
## the elevation the unit sprites are rendered at, and the zoom range and the
## pitch at its ends are what they were. The campaign missions open at it.

const MISSIONS: Array[String] = [
	"res://data/missions/riverside/mission.tres",
	"res://data/missions/the_ford/mission.tres",
	"res://data/missions/old_mill/mission.tres",
]


func test_the_default_is_close_and_at_the_sprites_elevation() -> void:
	assert_lte(RtsCamera.DEFAULT_DISTANCE, 45.0, "close: soldiers large on screen")
	assert_almost_eq(rad_to_deg(RtsCamera.pitch_at(RtsCamera.DEFAULT_DISTANCE)), 50.0, 0.01)


func test_the_zoom_range_and_its_end_pitches_are_kept() -> void:
	assert_eq(RtsCamera.MIN_DISTANCE, 8.0)
	assert_eq(RtsCamera.MAX_DISTANCE, 250.0)
	assert_almost_eq(rad_to_deg(RtsCamera.pitch_at(RtsCamera.MIN_DISTANCE)), 35.0, 0.01)
	assert_almost_eq(rad_to_deg(RtsCamera.pitch_at(RtsCamera.MAX_DISTANCE)), 65.0, 0.01)


func test_the_pitch_rises_steadily_with_the_distance() -> void:
	var last: float = -INF
	for step: int in 61:
		var d: float = lerpf(RtsCamera.MIN_DISTANCE, RtsCamera.MAX_DISTANCE, step / 60.0)
		var pitch: float = RtsCamera.pitch_at(d)
		assert_gte(pitch, last, "at %.1f m" % d)
		last = pitch


func test_the_campaign_missions_open_at_the_default_framing() -> void:
	for path: String in MISSIONS:
		var mission: MissionDef = load(path) as MissionDef
		assert_almost_eq(mission.camera_distance / 1000.0, RtsCamera.DEFAULT_DISTANCE, 0.001, path)
		var focus: Vector2 = Vector2(mission.camera_start[0], mission.camera_start[1])
		var squad: Vector2 = Vector2(mission.deploy[0], mission.deploy[1])
		assert_lt(focus.distance_to(squad) / 1000.0, 25.0, "%s looks near its squad" % path)
