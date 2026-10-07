extends GutTest
## CommandCodec: every command class survives encode, var_to_bytes, and
## decode unchanged; every kind is covered; records that are damaged in any way
## decode to null rather than to a command that would apply garbage.


# One of every class the codec knows, with no field left at a default.
func _samples() -> Array[SimCommand]:
	var ids: PackedInt32Array = PackedInt32Array([7, 3, 12])
	var types: Array[StringName] = [&"shieldman", &"longbow"]
	return [
		MoveUnitsCommand.new(5, ids, 1200, -340, Formations.Kind.WEDGE),
		AttackMoveCommand.new(6, ids, -5000, 77000, Formations.Kind.CIRCLE),
		StopUnitsCommand.new(7, ids),
		GroundAttackCommand.new(8, ids, 33000, 44000),
		UseSpecialCommand.new(9, ids),
		HealCommand.new(10, ids, 41),
		InteractCommand.new(11, ids, 52),
		ApplyStatusCommand.new(12, ids, StatusEffects.Kind.CONFUSION, 90),
		SetWeatherCommand.new(13, 800, 100, -3, 4, 300, 250),
		SpawnUnitCommand.new(14, &"husk", UnitType.Faction.DARK, 1000, 2000, 600, -800),
		DeployCommand.new(
			0, types, PackedInt32Array([101, 102]), PackedInt32Array([3, 0]), PackedInt32Array([40, 0]),
			60000, 70000, 0, 1000, Formations.Kind.LONG_LINE, UnitType.Faction.LIGHT
		),
		SpawnHerbPlantCommand.new(15, 9000, 8000),
		SpawnEntityCommand.new(16, 1, 2, 3),
		SetVelocityCommand.new(17, 23, -4, 5, -6),
		DespawnEntityCommand.new(18, 23),
	]


func test_every_command_round_trips_through_bytes() -> void:
	for command: SimCommand in _samples():
		var record: Array = CommandCodec.encode(command)
		assert_false(record.is_empty(), "%s encodes" % _name(command))
		var back: SimCommand = CommandCodec.decode(bytes_to_var(var_to_bytes(record)))
		assert_not_null(back, "%s decodes" % _name(command))
		if back == null:
			continue
		assert_eq(back.get_script(), command.get_script(), "%s keeps its class" % _name(command))
		assert_eq(CommandCodec.encode(back), record, "%s keeps every field" % _name(command))


func test_every_kind_has_a_sample_and_a_layout() -> void:
	var seen: Array[int] = []
	for command: SimCommand in _samples():
		seen.append(CommandCodec.encode(command)[0])
	seen.sort()
	var kinds: Array[int] = []
	kinds.assign(CommandCodec.Kind.values())
	kinds.sort()
	assert_eq(seen, kinds, "one sample per kind, so a new kind can't go untested")
	for kind: int in kinds:
		assert_true(CommandCodec.LAYOUTS.has(kind), "kind %d has a layout" % kind)


func test_kinds_keep_their_numbers() -> void:
	# Old replays decode by these numbers: they must never move.
	assert_eq(CommandCodec.Kind.MOVE, 1)
	assert_eq(CommandCodec.Kind.DEPLOY, 11)
	assert_eq(CommandCodec.Kind.DESPAWN_ENTITY, 15)


func test_records_hold_only_plain_types() -> void:
	for command: SimCommand in _samples():
		for value: Variant in CommandCodec.encode(command):
			assert_true(
				value is int or value is PackedInt32Array or value is PackedStringArray,
				"%s: %s is a plain type" % [_name(command), type_string(typeof(value))]
			)


func test_an_encoded_record_is_a_copy() -> void:
	var ids: PackedInt32Array = PackedInt32Array([1, 2])
	var command: StopUnitsCommand = StopUnitsCommand.new(0, ids)
	var record: Array = CommandCodec.encode(command)
	(record[2] as PackedInt32Array).set(0, 99)
	assert_eq(command.unit_ids[0], 1)


func test_damaged_records_decode_to_null() -> void:
	var move: Array = CommandCodec.encode(_samples()[0])
	var cases: Dictionary[String, Array] = {
		"empty": [],
		"kind only": [1],
		"unknown kind": [99, 0],
		"kind zero": [0, 0],
		"string kind": ["1", 0, PackedInt32Array(), 0, 0, 0],
		"negative tick": [1, -1, PackedInt32Array(), 0, 0, 0],
		"short": move.slice(0, move.size() - 1),
		"long": move + [0],
		"float field": [1, 0, PackedInt32Array(), 1.5, 0, 0],
		"untyped id list": [1, 0, [1, 2], 0, 0, 0],
		"bad formation": [1, 0, PackedInt32Array(), 0, 0, 99],
		"bad status": [CommandCodec.Kind.APPLY_STATUS, 0, PackedInt32Array(), 99, 10],
		"bad faction": [CommandCodec.Kind.SPAWN_UNIT, 0, PackedStringArray(["husk"]), 7, 0, 0, 0, 0],
		"two type names": [CommandCodec.Kind.SPAWN_UNIT, 0, PackedStringArray(["a", "b"]), 0, 0, 0, 0, 0],
		"deploy lengths": [
			CommandCodec.Kind.DEPLOY, 0, PackedStringArray(["shieldman", "longbow"]),
			PackedInt32Array([1]), PackedInt32Array([0, 0]), PackedInt32Array([0, 0]),
			0, 0, 0, 1000, 0, 0,
		],
	}
	for case: String in cases:
		assert_null(CommandCodec.decode(cases[case]), case)


func test_a_command_the_codec_does_not_know_encodes_to_nothing() -> void:
	assert_eq(CommandCodec.encode(RandomImpulseCommand.new(0, 1, 5)), [])
	assert_push_error("no record kind")


func _name(command: SimCommand) -> String:
	return command.get_script().resource_path.get_file()
