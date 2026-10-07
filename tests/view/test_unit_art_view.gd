extends GutTest
## Units whose type has art are drawn with it: the direction the unit faces
## on screen, the animation the sim calls for, a death that falls away from
## the blow and stays fallen, and F10's switch back to placeholders. Types
## without art keep the placeholder quad. While the view is frozen (paused, or
## the mission decided) an art body holds its frame.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _catalog: UnitCatalog
var _world: World
var _view: UnitsView
var _gibs: Gibs
var _shieldman: Unit
var _longbow: Unit


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(60, 60), _catalog)
	# Facing south, toward a camera that looks north: direction 4.
	_shieldman = _world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 30 * M, 30 * M, 0, 1)
	_longbow = _world.spawn_unit(_catalog.index_of(&"longbow"), LIGHT, 20 * M, 40 * M, 0, -1)
	_gibs = Gibs.new()
	add_child_autofree(_gibs)
	_gibs.setup(_world.terrain)
	var arts: UnitArtCatalog = UnitArtCatalog.new()
	arts.put(TestArt.art(&"shieldman"))
	_view = UnitsView.new()
	add_child_autofree(_view)
	_view.setup(_world, UnitSelection.new(), _gibs, arts)


func _sprite(unit: Unit) -> UnitSprite:
	for sprite: UnitSprite in _view.sprites():
		if sprite.unit_id == unit.id:
			return sprite
	return null


# The node that draws an art body.
func _art_body(sprite: UnitSprite) -> AnimatedSprite3D:
	var found: Array[Node] = sprite.find_children("*", "AnimatedSprite3D", false, false)
	return found[0] as AnimatedSprite3D if not found.is_empty() else null


func _kill(unit: Unit, source_x: int, source_z: int, overkill: int = 0) -> void:
	var event: CombatEvent = CombatEvent.new(CombatEvent.Kind.KILL, 0, unit.id, MeleeCombat.Aspect.FRONT, 100, overkill)
	event.source_x = source_x
	event.source_z = source_z
	unit.kill()
	_world.combat_events.append(event)
	_view.after_step()
	_world.combat_events.clear()
	_view._process(0.0)


# The Shieldman walks a tick's worth south at 3 m/s.
func _walk() -> void:
	_shieldman.transition_to(Unit.State.MOVING)
	_shieldman.x += 100
	_view.after_step()
	_view._process(0.0)


func test_only_types_with_art_get_an_art_body() -> void:
	assert_true(_sprite(_shieldman).has_art())
	assert_false(_sprite(_longbow).has_art())


func test_the_body_shows_the_way_the_unit_faces_on_screen() -> void:
	_view._process(0.0)
	assert_eq(_sprite(_shieldman).shown_animation(), &"idle_4")


func test_a_moving_unit_walks() -> void:
	_walk()
	assert_eq(_sprite(_shieldman).shown_animation(), &"walk_4")


func test_a_death_faces_the_blow_and_ignores_later_facing() -> void:
	# The blow comes from the north, so the body turns to face north (seen
	# from behind by a north-looking camera) and falls backward, away from it.
	_kill(_shieldman, 30 * M, 20 * M)
	assert_eq(_sprite(_shieldman).shown_animation(), &"die_0")
	_shieldman.facing_x = FixedMath.DIR_ONE
	_shieldman.facing_z = 0
	_view.after_step()
	_view._process(0.0)
	assert_eq(_sprite(_shieldman).shown_animation(), &"die_0")


func test_toggling_art_keeps_the_dead_dead_and_the_gibbed_gone() -> void:
	_kill(_shieldman, 30 * M, 20 * M)
	_kill(_longbow, 20 * M, 30 * M, 1000)
	assert_false(_sprite(_longbow).is_pickable(), "gibbed")

	_view.set_art_enabled(false)
	assert_false(_view.art_enabled())
	assert_false(_sprite(_shieldman).has_art())
	assert_true(_sprite(_shieldman).is_dead())
	assert_false(_sprite(_longbow).is_pickable(), "still gibbed after the rebuild")

	_view.set_art_enabled(true)
	_view.after_step()
	_view._process(0.0)
	var body: UnitSprite = _sprite(_shieldman)
	assert_true(body.has_art())
	assert_true(body.is_dead())
	assert_string_starts_with(String(body.shown_animation()), "die_")
	assert_eq(body.shown_frame(), 3, "the corpse shows the death's last frame, not a replay")
	assert_false(_sprite(_longbow).is_pickable())


func test_gibs_take_the_art_color() -> void:
	assert_eq(_sprite(_shieldman).gib_color(), Color(0.2, 0.4, 0.6))
	assert_eq(_sprite(_longbow).gib_color(), _longbow.type.placeholder_color)


func test_a_frozen_view_holds_the_art_frame_and_a_thawed_one_plays_on() -> void:
	_walk()
	var body: AnimatedSprite3D = _art_body(_sprite(_shieldman))
	assert_true(body.is_playing(), "walking")

	_view.frozen = true
	_view._process(0.0)
	var frame: int = body.frame
	var progress: float = body.frame_progress
	watch_signals(body)
	await wait_seconds(0.5)
	assert_eq(body.frame, frame, "no walking in place while paused")
	assert_eq(body.frame_progress, progress, "not even part of the way to the next frame")
	assert_signal_not_emitted(body, "frame_changed")

	_view.frozen = false
	await wait_seconds(0.5)
	assert_signal_emitted(body, "frame_changed", "the legs walk on")


func test_a_body_rebuilt_while_frozen_starts_held() -> void:
	_walk()
	_view.frozen = true
	_view._process(0.0)
	_view.set_art_enabled(false)
	_view.set_art_enabled(true)
	var body: AnimatedSprite3D = _art_body(_sprite(_shieldman))
	assert_not_null(body)
	assert_false(body.is_playing(), "held from the start")


func test_a_held_body_turning_with_the_camera_stays_held() -> void:
	_walk()
	_view.frozen = true
	_view._process(0.0)
	var sprite: UnitSprite = _sprite(_shieldman)
	# The camera orbits to look east while the game is paused.
	sprite.face_camera(Vector2(1.0, 0.0))
	assert_eq(sprite.shown_animation(), &"walk_6", "turned with the camera")
	assert_false(_art_body(sprite).is_playing(), "and still held")


func test_thawing_does_not_replay_a_finished_death() -> void:
	_kill(_shieldman, 30 * M, 20 * M)
	# The test death is 4 frames at 12 fps: a third of a second.
	await wait_seconds(0.5)
	var body: AnimatedSprite3D = _art_body(_sprite(_shieldman))
	assert_false(body.is_playing(), "the death played out")
	assert_eq(body.frame, 3)

	_view.frozen = true
	_view._process(0.0)
	_view.frozen = false
	_view._process(0.0)
	assert_eq(body.frame, 3, "still the corpse, not the death again")
	assert_false(body.is_playing())
