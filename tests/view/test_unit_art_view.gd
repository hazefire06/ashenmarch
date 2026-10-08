extends GutTest
## Units whose type has art are drawn with it: the direction the unit faces
## on screen, the animation the sim calls for, a death that falls away from
## the blow and stays fallen, and F10's switch back to placeholders. Types
## without art keep the placeholder quad. While the view is frozen (paused, or
## the mission decided) an art body holds its frame.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _world: World
var _view: UnitsView
var _selection: UnitSelection
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
	_selection = UnitSelection.new()
	_view = _art_view(_world, TestArt.art(&"shieldman"), _selection, _gibs)


# A UnitsView of world that draws the Shieldman with art.
func _art_view(world: World, art: UnitArt, selection: UnitSelection, gibs: Gibs = null) -> UnitsView:
	var arts: UnitArtCatalog = UnitArtCatalog.new()
	arts.put(art)
	var view: UnitsView = UnitsView.new()
	add_child_autofree(view)
	view.setup(world, selection, gibs, arts)
	return view


func _sprite(unit: Unit) -> UnitSprite:
	return _sprite_in(_view, unit)


func _sprite_in(view: UnitsView, unit: Unit) -> UnitSprite:
	for sprite: UnitSprite in view.sprites():
		if sprite.unit_id == unit.id:
			return sprite
	return null


# The node that draws an art body.
func _art_body(sprite: UnitSprite) -> AnimatedSprite3D:
	var found: Array[Node] = sprite.find_children("*", "AnimatedSprite3D", false, false)
	return found[0] as AnimatedSprite3D if not found.is_empty() else null


# The sprite's mesh nodes drawing a mesh of that class: the placeholder body
# and the health bar are QuadMeshes, the ring a TorusMesh, the facing tick a
# BoxMesh.
func _meshes(sprite: UnitSprite, mesh_class: String) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for node: Node in sprite.find_children("*", "MeshInstance3D", true, false):
		var mesh_node: MeshInstance3D = node as MeshInstance3D
		if mesh_node.mesh != null and mesh_node.mesh.is_class(mesh_class):
			out.append(mesh_node)
	return out


# The placeholder's quad: the only QuadMesh that is the sprite's own child.
func _placeholder_body(sprite: UnitSprite) -> MeshInstance3D:
	for mesh_node: MeshInstance3D in _meshes(sprite, "QuadMesh"):
		if mesh_node.get_parent() == sprite:
			return mesh_node
	return null


func _ring_showing(sprite: UnitSprite) -> bool:
	return _meshes(sprite, "TorusMesh")[0].is_visible_in_tree()


func _tick_showing(sprite: UnitSprite) -> bool:
	return _meshes(sprite, "BoxMesh")[0].is_visible_in_tree()


func _hp_bar_showing(sprite: UnitSprite) -> bool:
	for mesh_node: MeshInstance3D in _meshes(sprite, "QuadMesh"):
		if mesh_node.get_parent() != sprite and mesh_node.is_visible_in_tree():
			return true
	return false


# The ground direction a lying body's head points: from its feet-end corners
# to its head-end corners.
func _head_direction(sprite: UnitSprite) -> Vector2:
	var corners: PackedVector3Array = sprite.lying_corners()
	var feet: Vector3 = (corners[0] + corners[1]) * 0.5
	var head: Vector3 = (corners[2] + corners[3]) * 0.5
	return Vector2(head.x - feet.x, head.z - feet.z).normalized()


func _kill(unit: Unit, source_x: int, source_z: int, overkill: int = 0) -> void:
	_kill_in(_view, _world, unit, source_x, source_z, overkill)


func _kill_in(view: UnitsView, world: World, unit: Unit, source_x: int, source_z: int, overkill: int = 0) -> void:
	var event: CombatEvent = CombatEvent.new(CombatEvent.Kind.KILL, 0, unit.id, MeleeCombat.Aspect.FRONT, 100, overkill)
	event.source_x = source_x
	event.source_z = source_z
	unit.kill()
	world.combat_events.append(event)
	view.after_step()
	world.combat_events.clear()
	view._process(0.0)


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
	var head: Vector2 = _head_direction(_sprite(_shieldman))
	assert_almost_eq(head.y, 1.0, 0.05, "the placeholder corpse lies along the blow from the north")
	assert_false(_sprite(_longbow).is_pickable(), "still gibbed after the rebuild")

	_view.set_art_enabled(true)
	_view.after_step()
	_view._process(0.0)
	var body: UnitSprite = _sprite(_shieldman)
	assert_true(body.has_art())
	assert_true(body.is_dead())
	assert_eq(body.shown_animation(), &"die_0", "still facing the blow from the north")
	assert_eq(body.shown_frame(), 3, "the corpse shows the death's last frame, not a replay")
	assert_false(_sprite(_longbow).is_pickable())


func test_gibs_take_the_art_color() -> void:
	assert_eq(_sprite(_shieldman).gib_color(), Color(0.2, 0.4, 0.6))
	assert_eq(_sprite(_longbow).gib_color(), _longbow.type.placeholder_color)
	_kill(_shieldman, 30 * M, 20 * M, 1000)
	assert_true(_gibs._materials.has(Color(0.2, 0.4, 0.6)), "the burst is the art's colour")
	assert_false(_gibs._materials.has(_shieldman.type.placeholder_color), "not the placeholder's")


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


func test_a_hit_flash_shows_on_an_art_body_and_fades() -> void:
	var sprite: UnitSprite = _sprite(_shieldman)
	var body: AnimatedSprite3D = _art_body(sprite)
	var resting: Color = body.modulate
	_world.combat_events.append(CombatEvent.new(CombatEvent.Kind.HIT, 0, _shieldman.id))
	_world.combat_events.append(CombatEvent.new(CombatEvent.Kind.HIT, 0, _longbow.id))
	_view.after_step()
	_world.combat_events.clear()
	# Modulate can only darken the art, so the flash cuts green and blue.
	assert_lt(body.modulate.g, resting.g - 0.4, "the flash shows")
	assert_lt(body.modulate.b, resting.b - 0.4)
	var quad: StandardMaterial3D = _placeholder_body(_sprite(_longbow)).material_override as StandardMaterial3D
	assert_true(quad.albedo_color.is_equal_approx(UnitSprite.HIT_FLASH_COLOR), "the placeholder flashes as before")
	sprite._process(UnitSprite.FLASH_TIME)
	assert_eq(body.modulate, resting, "and fades back")


func test_the_body_turns_with_the_camera_and_keeps_its_last_forward_looking_straight_down() -> void:
	var camera: Camera3D = Camera3D.new()
	add_child_autofree(camera)
	# Looking east, a south-facing unit faces screen-right.
	camera.look_at_from_position(Vector3(20.0, 15.0, 30.0), Vector3(30.0, 0.0, 30.0))
	camera.make_current()
	_view._process(0.0)
	assert_eq(_sprite(_shieldman).shown_animation(), &"idle_6")
	# Straight down has no horizontal forward, so the last one stands.
	camera.look_at_from_position(Vector3(30.0, 20.0, 30.0), Vector3(30.0, 0.0, 30.0), Vector3(0.0, 0.0, -1.0))
	_view._process(0.0)
	assert_eq(_sprite(_shieldman).shown_animation(), &"idle_6")


func test_a_death_that_falls_forward_turns_away_from_the_blow() -> void:
	var art: UnitArt = TestArt.art(&"shieldman")
	art.die_falls_forward = true
	var view: UnitsView = _art_view(_world, art, UnitSelection.new())
	# A blow from the east: the body turns west, away from it, and falls on
	# its face (die_2, screen-left). Falling backward it would face east
	# (die_6); ignoring the blow it would still face south (die_4).
	_kill_in(view, _world, _shieldman, 40 * M, 30 * M)
	var sprite: UnitSprite = _sprite_in(view, _shieldman)
	assert_eq(sprite.shown_animation(), &"die_2")
	assert_almost_eq(_head_direction(sprite).x, -1.0, 0.05, "picked where it fell: head to the west")


func test_an_art_body_tints_by_modulate_and_shows_no_facing_tick() -> void:
	var sprite: UnitSprite = _sprite(_shieldman)
	var body: AnimatedSprite3D = _art_body(sprite)
	assert_eq(body.modulate, Color.WHITE, "the art is coloured already")
	assert_false(_tick_showing(sprite), "the art shows facing itself")
	assert_true(_tick_showing(_sprite(_longbow)), "a placeholder keeps its tick")
	sprite.set_statuses(true, false, false)
	assert_ne(body.modulate, Color.WHITE, "paralysis tints it")
	sprite.set_statuses(false, false, false)
	assert_eq(body.modulate, Color.WHITE)
	_kill(_shieldman, 30 * M, 20 * M)
	assert_eq(body.modulate, UnitSprite.ART_DEAD_TINT, "dimmed when dead")


func test_an_art_corpse_is_picked_by_a_footprint_along_its_fall() -> void:
	_kill(_shieldman, 30 * M, 20 * M)
	var sprite: UnitSprite = _sprite(_shieldman)
	var corners: PackedVector3Array = sprite.lying_corners()
	var centre: Vector3 = (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25
	assert_almost_eq(centre.x, sprite.global_position.x, 0.001, "centred on the unit")
	assert_almost_eq(centre.z, sprite.global_position.z, 0.001)
	var feet: Vector3 = (corners[0] + corners[1]) * 0.5
	var head: Vector3 = (corners[2] + corners[3]) * 0.5
	assert_almost_eq(head.x - feet.x, 0.0, 0.001)
	assert_almost_eq(head.z - feet.z, sprite.height, 0.001, "a body length, head south, away from the blow")
	assert_almost_eq(corners[0].distance_to(corners[1]), sprite.half_width * 2.0, 0.001, "a body wide")


func test_a_rebuild_keeps_the_hurt_the_selected_and_the_hidden_as_they_were() -> void:
	# Deep water east of x = 20 m hides a Husk from the Light side.
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(20) + "3".repeat(20))
	var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	var husk: Unit = world.spawn_unit(_catalog.index_of(&"husk"), DARK, 25 * M, 20 * M, -1, 0)
	var shieldman: Unit = world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 10 * M, 20 * M, 1, 0)
	var longbow: Unit = world.spawn_unit(_catalog.index_of(&"longbow"), LIGHT, 10 * M, 24 * M, 1, 0)
	var selection: UnitSelection = UnitSelection.new()
	var view: UnitsView = _art_view(world, TestArt.art(&"shieldman"), selection)
	longbow.hp = 40
	view.after_step()
	selection.select(PackedInt32Array([shieldman.id]))
	for enabled: bool in [false, true]:
		view.set_art_enabled(enabled)
		var which: String = "art" if enabled else "placeholders"
		assert_eq(_sprite_in(view, shieldman).has_art(), enabled)
		assert_true(_ring_showing(_sprite_in(view, shieldman)), "still selected: " + which)
		assert_false(_ring_showing(_sprite_in(view, longbow)), "still not selected: " + which)
		assert_true(_hp_bar_showing(_sprite_in(view, longbow)), "still hurt: " + which)
		assert_null(_sprite_in(view, husk), "still out of sight in the water: " + which)


func test_a_rebuild_leaves_one_sprite_per_unit_under_its_own_name() -> void:
	_view.set_art_enabled(false)
	var sprites: Array[UnitSprite] = []
	for child: Node in _view.get_children():
		if child is UnitSprite:
			sprites.append(child as UnitSprite)
	assert_eq(sprites.size(), _world.units.size(), "the old sprites leave the tree at once")
	for sprite: UnitSprite in sprites:
		assert_eq(String(sprite.name), "Unit_%d" % sprite.unit_id)


func test_a_freeze_undone_before_the_view_redraws_holds_nothing() -> void:
	_walk()
	_view.frozen = true
	_view.set_art_enabled(false)
	_view.set_art_enabled(true)
	_view.frozen = false
	_view._process(0.0)
	assert_true(_art_body(_sprite(_shieldman)).is_playing(), "the rebuilt body isn't left held")


# A mission decided by the Shieldman's death: MainView runs after_step (the
# KILL starts the death on its first frame), then freezes the view in the
# same physics frame, before the body has drawn any of the fall. Returns the
# body once the death has had time to play (4 frames at 12 fps: a third of a
# second).
func _die_as_the_view_freezes(source_x: int, source_z: int) -> AnimatedSprite3D:
	var event: CombatEvent = CombatEvent.new(CombatEvent.Kind.KILL, 0, _shieldman.id)
	event.source_x = source_x
	event.source_z = source_z
	_shieldman.kill()
	_world.combat_events.append(event)
	_view.after_step()
	_world.combat_events.clear()
	_view.frozen = true
	_view._process(0.0)
	var body: AnimatedSprite3D = _art_body(_sprite(_shieldman))
	await wait_seconds(0.5)
	return body


func test_a_death_on_the_tick_that_freezes_the_view_still_falls() -> void:
	# From the south: the body keeps facing the camera, so only hold() could
	# stop it.
	var body: AnimatedSprite3D = await _die_as_the_view_freezes(30 * M, 40 * M)
	assert_eq(body.animation, &"die_4")
	assert_eq(body.frame, 3, "the body fell to its corpse frame")
	assert_false(body.is_playing(), "and lies there")
	_view.frozen = false
	_view._process(0.0)
	assert_eq(body.frame, 3, "thawing doesn't fell it again")


func test_a_death_that_turns_the_body_as_the_view_freezes_still_falls() -> void:
	# From the north: the body turns to face it on the first frame drawn, after
	# the freeze, which switches it to die_0's frames while held.
	var body: AnimatedSprite3D = await _die_as_the_view_freezes(30 * M, 20 * M)
	assert_eq(body.animation, &"die_0")
	assert_eq(body.frame, 3, "the body fell to its corpse frame")
	assert_false(body.is_playing(), "and lies there")


func test_a_corpse_rebuilt_while_frozen_shows_its_last_frame() -> void:
	_kill(_shieldman, 30 * M, 20 * M)
	_view.frozen = true
	_view._process(0.0)
	_view.set_art_enabled(false)
	_view.set_art_enabled(true)
	_view._process(0.0)
	var body: AnimatedSprite3D = _art_body(_sprite(_shieldman))
	assert_eq(body.animation, &"die_0")
	assert_eq(body.frame, 3)
	await wait_seconds(0.2)
	assert_eq(body.frame, 3, "it stays the corpse")
