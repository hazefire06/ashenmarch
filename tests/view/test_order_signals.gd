extends GutTest
## SelectionController's order_given carries the ids and the kind of order;
## player_selected reports each selection the player makes; notices take a
## colour and a time; and SfxPlayer's tones follow the signals.


func _main() -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = ViewFixtures.skirmish_launch()
	add_child_autofree(main)
	# The skirmish starts with no one placed; put three Shieldmen where the
	# camera looks, and let the view make their sprites.
	var catalog: UnitCatalog = main.world.catalog
	var focus: Vector3 = main._camera.focus
	for i: int in 3:
		main.world.spawn_unit(
			catalog.index_of(&"shieldman"), UnitType.Faction.LIGHT,
			roundi((focus.x + i * 2.0) * 1000.0), roundi(focus.z * 1000.0), 0, 1000
		)
	main._physics_process(1.0 / World.TICK_RATE)
	main._process(0.1)
	return main


func _light_ids(main: MainView) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in main.world.units:
		if unit.faction == UnitType.Faction.LIGHT and unit.is_alive():
			ids.append(unit.id)
	return ids


func _sfx(main: MainView) -> SfxPlayer:
	return main.find_child("Sfx", true, false) as SfxPlayer


func test_each_order_carries_its_ids_and_kind() -> void:
	var main: MainView = _main()
	var sel: SelectionController = main._selection
	var ids: PackedInt32Array = _light_ids(main)
	sel.selection.select(ids)
	var point: Vector3 = main._camera.focus
	watch_signals(sel)
	sel.stop_selected()
	sel.retreat_selected()
	sel.use_special_selected()
	sel.order_world(point, false, false)
	sel.order_world(point, true, false)
	sel.order_world(point, false, true)
	var want: Array[int] = [
		SelectionController.OrderKind.OTHER, SelectionController.OrderKind.RETREAT,
		SelectionController.OrderKind.SPECIAL, SelectionController.OrderKind.MOVE,
		SelectionController.OrderKind.ATTACK, SelectionController.OrderKind.MOVE,
	]
	assert_signal_emit_count(sel, "order_given", want.size())
	var sorted: PackedInt32Array = sel.selection.ids()
	for i: int in want.size():
		var params: Array = get_signal_parameters(sel, "order_given", i)
		assert_eq(params[0], sorted, "order %d carries the selected ids" % i)
		assert_eq(params[1], want[i], "order %d kind" % i)


func test_clicking_the_same_unit_again_reports_a_player_selection() -> void:
	var main: MainView = _main()
	var sel: SelectionController = main._selection
	var sprite: UnitSprite = null
	var at: Vector2 = Vector2.ZERO
	for s: UnitSprite in main._units_view.sprites():
		if sel.unit_at(sel._screen_rect(s).get_center()) == s.unit_id:
			sprite = s
			at = sel._screen_rect(s).get_center()
			break
	assert_not_null(sprite, "a pickable unit")
	var changes: Array[int] = [0]
	sel.selection.changed.connect(func() -> void: changes[0] += 1)
	watch_signals(sel)
	sel.select_at(at, false)
	sel.select_at(at, false)
	assert_signal_emit_count(sel, "player_selected", 2)
	assert_eq(changes[0], 1, "the selection changed once")
	assert_eq(get_signal_parameters(sel, "player_selected", 1)[0], PackedInt32Array([sprite.unit_id]))


func test_a_dying_selected_unit_is_not_a_player_selection() -> void:
	var main: MainView = _main()
	var sel: SelectionController = main._selection
	var ids: PackedInt32Array = _light_ids(main)
	sel.selection.select(ids)
	watch_signals(sel)
	var changes: Array[int] = [0]
	sel.selection.changed.connect(func() -> void: changes[0] += 1)
	main.world.get_unit(ids[0]).kill()
	sel._process(0.0)
	assert_eq(changes[0], 1, "prune changed the selection")
	assert_signal_not_emitted(sel, "player_selected")


func test_a_notice_takes_a_colour_and_a_time() -> void:
	var sprite: UnitSprite = UnitSprite.new()
	add_child_autofree(sprite)
	sprite.show_notice("x", Color.RED, 2.5)
	var label: Label3D = sprite.find_children("*", "Label3D", true, false).back() as Label3D
	assert_eq(label.modulate, Color.RED)
	sprite._process(2.0)
	assert_eq(sprite.notice_text(), "x", "still showing after 2 s")
	sprite.show_notice("y")
	assert_eq(label.modulate, UnitSprite.NOTICE_COLOR, "the default colour comes back")
	sprite._process(1.1)
	assert_eq(sprite.notice_text(), "", "the default time is NOTICE_TIME")


func test_the_tones_follow_the_selection_signals() -> void:
	var main: MainView = _main()
	var sel: SelectionController = main._selection
	var sfx: SfxPlayer = _sfx(main)
	# The shipped bank has no streams yet for the interface tones.
	var variants: Dictionary = {}
	for id: StringName in SoundBank.shared().ids():
		variants[id] = 1
	sfx.bank = AudioFixtures.bank(variants, 3, 0.2)
	sfx.after_step()
	sel.order_given.emit(PackedInt32Array([1]), SelectionController.OrderKind.MOVE)
	sel.player_selected.emit(PackedInt32Array([1]))
	sel.formation_changed.emit(Formations.Kind.BOX)
	sel.group_changed.emit(2)
	sel.group_changed.emit(-1)
	var cues: Array[StringName] = []
	for played: Dictionary in sfx.played_this_tick():
		cues.append(played["cue"])
	assert_eq(cues, [&"order_ack", &"ui_select", &"ui_formation", &"ui_group"])
	assert_true(sfx.played_this_tick()[0].has("db"))
