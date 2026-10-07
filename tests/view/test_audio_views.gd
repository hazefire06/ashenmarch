extends GutTest
## The sound views: SfxPlayer turns the sim's events into sounds within its
## caps and cull distance and acknowledges orders; Ambience follows the rain
## and the fire; UiSounds clicks for buttons added anywhere; every sound in the
## bank loads; and H (or the bar's Center) glides the camera to the selection.

const M: int = 1000


func _main() -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.skirmish_launch()
	add_child_autofree(main)
	return main


func test_every_sound_loads_and_the_beds_loop() -> void:
	for sound: StringName in SfxBank.STREAMS:
		assert_not_null(SfxBank.stream(sound), String(sound))
		assert_true(SfxBank.LEVELS_DB.has(sound), String(sound))
	for bed: StringName in [&"rain_loop", &"fire_loop"]:
		assert_eq((SfxBank.stream(bed) as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_FORWARD, String(bed))
	assert_eq((SfxBank.stream(&"explosion") as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_DISABLED)


func test_events_become_sounds_within_the_caps() -> void:
	var main: MainView = _main()
	var sfx: SfxPlayer = main.find_child("Sfx", true, false) as SfxPlayer
	assert_not_null(sfx)
	var near: Vector3 = main._camera.focus
	for i: int in 5:
		sfx.play_at(&"explosion", near)
	assert_eq(sfx.started_this_tick(), SfxPlayer.MAX_PER_TICK, "one sound at most MAX_PER_TICK a tick")
	for i: int in 10:
		sfx.play_at(&"sword_hit" if i % 2 == 0 else &"death", near)
	assert_eq(sfx.started_this_tick(), SfxPlayer.MAX_TICK_TOTAL, "and MAX_TICK_TOTAL in all")
	main._physics_process(1.0 / World.TICK_RATE)
	assert_false(sfx.play_at(&"heal", near + Vector3(SfxPlayer.CULL_DISTANCE + 10.0, 0, 0)), "too far to hear")
	assert_true(sfx.play_at(&"heal", near), "a new tick, a fresh budget")


func test_a_blast_in_the_world_is_heard() -> void:
	var main: MainView = _main()
	var sfx: SfxPlayer = main.find_child("Sfx", true, false) as SfxPlayer
	var focus: Vector3 = main._camera.focus
	var event: ProjectileEvent = ProjectileEvent.new(
		ProjectileEvent.Kind.EXPLODE, roundi(focus.x * M), 0, roundi(focus.z * M)
	)
	main.world.step()
	main.world.projectile_events.append(event)
	sfx.after_step()
	assert_eq(sfx.started_this_tick(), 1)


func test_the_beds_follow_the_rain_and_the_fire() -> void:
	var main: MainView = _main()
	var beds: Ambience = main.find_child("Ambience", true, false) as Ambience
	assert_eq(beds.targets(), Vector2.ZERO, "clear and unburnt")
	main.world.enqueue(SetWeatherCommand.new(main.world.tick, 1000, 0, 0, 0, 0))
	main._physics_process(1.0 / World.TICK_RATE)
	assert_almost_eq(beds.targets().x, 1.0, 0.01, "rain at full")


func test_buttons_added_anywhere_click() -> void:
	var clicks: UiSounds = UiSounds.new()
	add_child_autofree(clicks)
	var button: Button = Button.new()
	add_child_autofree(button)
	assert_eq(button.pressed.get_connections().size(), 1, "connected as it entered the tree")
	remove_child(button)
	add_child(button)
	assert_eq(button.pressed.get_connections().size(), 1, "and only once")


func test_h_glides_the_camera_to_the_selection() -> void:
	var main: MainView = _main()
	main._physics_process(1.0 / World.TICK_RATE)
	var mine: PackedInt32Array = PackedInt32Array()
	var middle: Vector2 = Vector2.ZERO
	for unit: Unit in main.world.units:
		if unit.faction == UnitType.Faction.LIGHT:
			mine.append(unit.id)
			middle += Vector2(unit.x, unit.z) / float(M)
	middle /= mine.size()
	main._selection.selection.select(mine)
	main._camera.focus_on(Vector2(5, 5))
	var press: InputEventKey = InputEventKey.new()
	press.physical_keycode = KEY_H
	press.pressed = true
	main._unhandled_input(press)
	assert_true(main._camera.is_gliding())
	for i: int in 120:
		main._camera._process(1.0 / 60.0)
	assert_false(main._camera.is_gliding(), "arrived")
	assert_almost_eq(main._camera.focus.x, middle.x, 0.1)
	assert_almost_eq(main._camera.focus.z, middle.y, 0.1)


func test_moving_the_camera_by_hand_stops_a_glide() -> void:
	var main: MainView = _main()
	main._camera.glide_to(Vector2(50, 50))
	Input.action_press(InputBindings.CAM_FORWARD)
	main._camera._process(1.0 / 60.0)
	Input.action_release(InputBindings.CAM_FORWARD)
	assert_false(main._camera.is_gliding())


func test_an_order_is_acknowledged() -> void:
	var main: MainView = _main()
	assert_true(main._selection.order_given.is_connected(
		(main.find_child("Sfx", true, false) as SfxPlayer).acknowledge
	))
