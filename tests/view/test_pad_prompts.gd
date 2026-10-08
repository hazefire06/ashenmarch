extends GutTest
## The pad's prompts, glyphs, rebinding and rumble (Phase 11): every pad
## binding has an original glyph; prompts name the key or show the glyph by
## the device in use, and the control bar follows a switch; Settings >
## Controller binds a pad button by pressing it (and the Menu button never);
## rumble is felt from blasts near the camera and from your own losses, and
## left alone on a pad that can't (an Xbox pad on USB under macOS).

const SETTINGS_DIR: String = "user://test_pad_prompts"
const M: int = 1000


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset(InputBindings.Preset.MODERN)


func after_each() -> void:
	PadEvents.release_all()
	InputBindings.reset(InputBindings.Preset.MODERN)
	await get_tree().process_frame
	if DirAccess.dir_exists_absolute(SETTINGS_DIR):
		for file_name: String in DirAccess.get_files_at(SETTINGS_DIR):
			DirAccess.remove_absolute(SETTINGS_DIR + "/" + file_name)
		DirAccess.remove_absolute(SETTINGS_DIR)
	ViewFixtures.cleanup()


func test_every_pad_binding_has_a_glyph() -> void:
	var pad: Dictionary[StringName, InputEvent] = InputBindings.pad_defaults()
	for action: StringName in pad:
		var glyph: Texture2D = InputPrompts.glyph(pad[action])
		assert_not_null(glyph, "%s has a glyph" % action)
		if glyph != null:
			assert_eq(glyph.get_size(), Vector2(64, 64), String(action))


func test_prompts_follow_the_device_in_use() -> void:
	InputDevice.use(InputBindings.Device.KBM)
	assert_eq(InputPrompts.prompt(InputBindings.ABILITY), "T")
	assert_eq(InputPrompts.label(InputBindings.ABILITY), "T")
	InputDevice.use(InputBindings.Device.PAD)
	assert_string_contains(InputPrompts.prompt(InputBindings.ABILITY), "[img=20]res://assets/ui/pad/y.svg[/img]")
	assert_eq(InputPrompts.label(InputBindings.ABILITY), "Y")
	assert_eq(InputPrompts.label(InputBindings.STOP), "Space", "no pad binding: the key's name")
	assert_string_contains(InputPrompts.pad_hints(), "a.svg")


func test_the_control_bar_switches_to_glyphs_with_the_pad() -> void:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.launch()
	add_child_autofree(main)
	var bar: ControlBar = main._control_bar
	InputDevice.use(InputBindings.Device.KBM)
	assert_eq(bar._formation_buttons[0].text, "1 Short line")
	InputDevice.use(InputBindings.Device.PAD)
	assert_eq(bar._formation_buttons[0].text, "Short line", "no key to name")
	var shown: int = 0
	for glyph: TextureRect in bar._caption_glyphs:
		shown += 1 if glyph.visible else 0
	assert_eq(shown, 4, "every row's caption shows its pad button")
	assert_eq(bar._ability_button.text, "Ability (Y)")
	InputDevice.use(InputBindings.Device.KBM)
	assert_eq(bar._formation_buttons[0].text, "1 Short line")


func test_settings_binds_a_pad_button_by_pressing_it() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	settings.capture_pad(InputBindings.PAD_ORDER)
	assert_true(settings.is_capturing())
	PadEvents.tap(JOY_BUTTON_Y)
	assert_false(settings.is_capturing())
	assert_eq(InputBindings.label_for(InputBindings.PAD_ORDER, InputBindings.Device.PAD), "Y")
	assert_eq(InputBindings.label_for(InputBindings.ABILITY, InputBindings.Device.PAD), "X", "the special took X, a swap")
	assert_eq(GameSettings.padbinds(SETTINGS_DIR + "/settings.cfg").size(), 2, "both saved")


func test_settings_binds_a_stick_pushed_well_over() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	settings.capture_pad(InputBindings.PAD_ORBIT_LEFT)
	PadEvents.axis(JOY_AXIS_RIGHT_X, 0.3)
	assert_true(settings.is_capturing(), "a light touch isn't a choice")
	PadEvents.axis(JOY_AXIS_RIGHT_X, -0.9)
	assert_eq(InputBindings.label_for(InputBindings.PAD_ORBIT_LEFT, InputBindings.Device.PAD), "RS left")


func test_the_menu_button_cancels_a_capture_and_is_never_bound() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	settings.capture_pad(InputBindings.PAD_SELECT)
	PadEvents.tap(JOY_BUTTON_START)
	assert_false(settings.is_capturing())
	assert_eq(InputBindings.label_for(InputBindings.PAD_SELECT, InputBindings.Device.PAD), "A")


func test_a_capture_gives_up_after_a_while() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	settings.capture_pad(InputBindings.PAD_SELECT)
	settings._process(SettingsMenu.PAD_CAPTURE_SECONDS + 0.1)
	assert_false(settings.is_capturing())


func test_reset_controller_puts_the_pad_back() -> void:
	var path: String = SETTINGS_DIR + "/settings.cfg"
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(path)
	add_child_autofree(settings)
	settings.capture_pad(InputBindings.PAD_ORDER)
	PadEvents.tap(JOY_BUTTON_Y)
	settings._reset_controller()
	assert_eq(InputBindings.label_for(InputBindings.PAD_ORDER, InputBindings.Device.PAD), "X")
	assert_true(GameSettings.padbinds(path).is_empty())


func test_a_near_blast_is_felt_and_a_far_one_is_not() -> void:
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog())
	world.projectile_events.append(_blast(10 * M, 10 * M, 4 * M))
	var near: Vector3 = PadRumble.felt(world, Vector3(12, 0, 10), UnitType.Faction.LIGHT)
	assert_gt(near.y, 0.5, "a blast 2 m off shakes hard")
	assert_gt(near.z, 0.0)
	var far: Vector3 = PadRumble.felt(world, Vector3(10 + PadRumble.BLAST_REACH + 5.0, 0, 10), UnitType.Faction.LIGHT)
	assert_eq(far.y, 0.0, "out of reach, nothing")


func test_losing_a_unit_is_a_weak_tick_and_killing_one_is_nothing() -> void:
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog())
	var mine: Unit = world.spawn_unit(world.catalog.index_of(&"shieldman"), UnitType.Faction.LIGHT, 5 * M, 5 * M, 1, 0)
	var theirs: Unit = world.spawn_unit(world.catalog.index_of(&"husk"), UnitType.Faction.DARK, 9 * M, 5 * M, 1, 0)
	world.combat_events.append(_kill(theirs.id))
	assert_eq(PadRumble.felt(world, Vector3.ZERO, UnitType.Faction.LIGHT).z, 0.0)
	world.combat_events.append(_kill(mine.id))
	var felt: Vector3 = PadRumble.felt(world, Vector3.ZERO, UnitType.Faction.LIGHT)
	assert_almost_eq(felt.x, PadRumble.DEATH_WEAK, 0.001)
	assert_eq(felt.y, 0.0, "the weak motor only")


func test_an_xbox_pad_on_usb_under_macos_is_left_alone() -> void:
	var usb: Dictionary = {"vendor_id": 0x045E, "product_id": 0x0B12}
	var bluetooth: Dictionary = {"vendor_id": 0x045E, "product_id": 0x0B13}
	assert_true(PadRumble.denied(usb, true))
	assert_false(PadRumble.denied(bluetooth, true), "over Bluetooth it rumbles")
	assert_false(PadRumble.denied(usb, false), "on Windows it rumbles")
	assert_false(PadRumble.denied({}, true), "the web says nothing: the driver decides")


func test_rumble_at_zero_strength_is_off() -> void:
	var rumble: PadRumble = PadRumble.new()
	rumble.strength = 0.0
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog())
	world.projectile_events.append(_blast(10 * M, 10 * M, 4 * M))
	rumble.after_step(world, Vector3(10, 0, 10), UnitType.Faction.LIGHT)
	assert_true(rumble.sent.is_empty())


func _blast(x: int, z: int, radius: int) -> ProjectileEvent:
	var event: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.EXPLODE, x, 0, z)
	event.radius = radius
	return event


func _kill(target_id: int) -> CombatEvent:
	var event: CombatEvent = CombatEvent.new(CombatEvent.Kind.KILL, 0, target_id)
	return event
