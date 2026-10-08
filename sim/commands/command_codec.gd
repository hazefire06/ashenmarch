class_name CommandCodec
extends RefCounted
## Turns commands into plain arrays and back. A record is the replay file's
## unit and, later, lockstep's wire unit: [kind, tick, field, ...], holding
## only ints, Strings, PackedInt32Arrays and PackedStringArrays, so
## var_to_bytes encodes it identically on every platform. StringNames go out
## as Strings; enums as their int values.
##
## Kinds are stable. Append a new one for a new command class; never renumber
## or reuse one, or old replays decode as the wrong command.
##
## decode() trusts nothing: a record from a damaged file (or, one day, a peer)
## with the wrong length, a wrongly typed field, an enum value out of range, a
## negative tick, a number of MAX_MAGNITUDE or more (FixedMath works in
## ranges far below int64, and INT64_MIN hangs normalize()) or a list longer
## than MAX_LIST decodes to null, never to a command that would apply garbage.
##
## Every kind decodes, including the setup and debug ones (spawns, statuses,
## velocities) a replay never holds from a player. When lockstep takes
## commands from peers it must accept only the player-order kinds
## (PLAYER_KINDS).
##
## A layout may end in an optional tail after "|": a record holds either the
## fields before it or all of them, never part of the tail. Decode fills a
## missing tail with its defaults, so a record written before the tail existed
## still loads as the command it was. Encode always writes the whole layout.

enum Kind {
	MOVE = 1,
	ATTACK_MOVE = 2,
	STOP = 3,
	GROUND_ATTACK = 4,
	USE_SPECIAL = 5,
	HEAL = 6,
	INTERACT = 7,
	APPLY_STATUS = 8,
	SET_WEATHER = 9,
	SPAWN_UNIT = 10,
	DEPLOY = 11,
	SPAWN_HERB_PLANT = 12,
	SPAWN_ENTITY = 13,
	SET_VELOCITY = 14,
	DESPAWN_ENTITY = 15,
}

## Every number in a record, the tick included, is under this in magnitude:
## about 1000 km in milli-units, far beyond any map, far inside what
## FixedMath can square.
const MAX_MAGNITUDE: int = 1 << 30
## Most entries a list in a record may have (unit ids, a deploy's roster).
const MAX_LIST: int = 256

## A record's field types, after kind and tick, per kind. I is an int, U a
## PackedInt32Array of unit ids, S a PackedStringArray. Enum fields are I and
## are range-checked in decode.
##
## MOVE and ATTACK_MOVE gained a facing tail in Phase 11; without it the
## facing is (0, 0), the automatic one (UnitOrders.move).
const LAYOUTS: Dictionary[int, String] = {
	Kind.MOVE: "UIII|II",
	Kind.ATTACK_MOVE: "UIII|II",
	Kind.STOP: "U",
	Kind.GROUND_ATTACK: "UII",
	Kind.USE_SPECIAL: "U",
	Kind.HEAL: "UI",
	Kind.INTERACT: "UI",
	Kind.APPLY_STATUS: "UII",
	Kind.SET_WEATHER: "IIIIII",
	Kind.SPAWN_UNIT: "SIIIII",
	Kind.DEPLOY: "SUUUIIIIII",
	Kind.SPAWN_HERB_PLANT: "II",
	Kind.SPAWN_ENTITY: "III",
	Kind.SET_VELOCITY: "IIII",
	Kind.DESPAWN_ENTITY: "I",
}


## The record for `command`, or an empty array (after push_error) for a class
## the codec doesn't know: a test-only command, or a new class someone forgot
## to add here.
static func encode(command: SimCommand) -> Array:
	if command is MoveUnitsCommand:
		var c: MoveUnitsCommand = command
		return [Kind.MOVE, c.tick, c.unit_ids.duplicate(), c.x, c.z, c.formation, c.facing_x, c.facing_z]
	if command is AttackMoveCommand:
		var c: AttackMoveCommand = command
		return [
			Kind.ATTACK_MOVE, c.tick, c.unit_ids.duplicate(), c.x, c.z, c.formation, c.facing_x, c.facing_z,
		]
	if command is StopUnitsCommand:
		var c: StopUnitsCommand = command
		return [Kind.STOP, c.tick, c.unit_ids.duplicate()]
	if command is GroundAttackCommand:
		var c: GroundAttackCommand = command
		return [Kind.GROUND_ATTACK, c.tick, c.unit_ids.duplicate(), c.x, c.z]
	if command is UseSpecialCommand:
		var c: UseSpecialCommand = command
		return [Kind.USE_SPECIAL, c.tick, c.unit_ids.duplicate()]
	if command is HealCommand:
		var c: HealCommand = command
		return [Kind.HEAL, c.tick, c.unit_ids.duplicate(), c.target_id]
	if command is InteractCommand:
		var c: InteractCommand = command
		return [Kind.INTERACT, c.tick, c.unit_ids.duplicate(), c.entity_id]
	if command is ApplyStatusCommand:
		var c: ApplyStatusCommand = command
		return [Kind.APPLY_STATUS, c.tick, c.unit_ids.duplicate(), int(c.kind), c.ticks]
	if command is SetWeatherCommand:
		var c: SetWeatherCommand = command
		return [Kind.SET_WEATHER, c.tick, c.rain, c.snow, c.wind_x, c.wind_z, c.ramp_ticks, c.snow_cover]
	if command is SpawnUnitCommand:
		var c: SpawnUnitCommand = command
		return [
			Kind.SPAWN_UNIT, c.tick, PackedStringArray([String(c.type_id)]), int(c.faction),
			c.x, c.z, c.facing_x, c.facing_z,
		]
	if command is DeployCommand:
		var c: DeployCommand = command
		var ids: PackedStringArray = PackedStringArray()
		for type_id: StringName in c.type_ids:
			ids.append(String(type_id))
		return [
			Kind.DEPLOY, c.tick, ids, c.soldier_ids.duplicate(), c.kills.duplicate(), c.hp.duplicate(),
			c.x, c.z, c.facing_x, c.facing_z, int(c.formation), int(c.faction),
		]
	if command is SpawnHerbPlantCommand:
		var c: SpawnHerbPlantCommand = command
		return [Kind.SPAWN_HERB_PLANT, c.tick, c.x, c.z]
	if command is SpawnEntityCommand:
		var c: SpawnEntityCommand = command
		return [Kind.SPAWN_ENTITY, c.tick, c.x, c.y, c.z]
	if command is SetVelocityCommand:
		var c: SetVelocityCommand = command
		return [Kind.SET_VELOCITY, c.tick, c.entity_id, c.vx, c.vy, c.vz]
	if command is DespawnEntityCommand:
		var c: DespawnEntityCommand = command
		return [Kind.DESPAWN_ENTITY, c.tick, c.entity_id]
	push_error("CommandCodec.encode: no record kind for %s" % command.get_script().resource_path)
	return []


## The command a record describes, or null if the record is malformed (see
## the class comment). Says nothing itself: the caller knows which file or
## peer the record came from and reports that.
static func decode(record: Array) -> SimCommand:
	if record.size() < 2 or not record[0] is int or not record[1] is int:
		return null
	var kind: int = record[0]
	var tick: int = record[1]
	if not LAYOUTS.has(kind) or tick < 0 or tick >= MAX_MAGNITUDE or not _fits(record, LAYOUTS[kind]):
		return null
	var f: Array = record.slice(2)
	match kind:
		Kind.MOVE:
			if not _is_formation(f[3]):
				return null
			return MoveUnitsCommand.new(tick, f[0], f[1], f[2], f[3], _tail(f, 4), _tail(f, 5))
		Kind.ATTACK_MOVE:
			if not _is_formation(f[3]):
				return null
			return AttackMoveCommand.new(tick, f[0], f[1], f[2], f[3], _tail(f, 4), _tail(f, 5))
		Kind.STOP:
			return StopUnitsCommand.new(tick, f[0])
		Kind.GROUND_ATTACK:
			return GroundAttackCommand.new(tick, f[0], f[1], f[2])
		Kind.USE_SPECIAL:
			return UseSpecialCommand.new(tick, f[0])
		Kind.HEAL:
			return HealCommand.new(tick, f[0], f[1])
		Kind.INTERACT:
			return InteractCommand.new(tick, f[0], f[1])
		Kind.APPLY_STATUS:
			if not StatusEffects.Kind.values().has(f[1]):
				return null
			return ApplyStatusCommand.new(tick, f[0], f[1] as StatusEffects.Kind, f[2])
		Kind.SET_WEATHER:
			return SetWeatherCommand.new(tick, f[0], f[1], f[2], f[3], f[4], f[5])
		Kind.SPAWN_UNIT:
			var names: PackedStringArray = f[0]
			if names.size() != 1 or not _is_faction(f[1]):
				return null
			return SpawnUnitCommand.new(
				tick, StringName(names[0]), f[1] as UnitType.Faction, f[2], f[3], f[4], f[5]
			)
		Kind.DEPLOY:
			if not _is_formation(f[8]) or not _is_faction(f[9]):
				return null
			var count: int = (f[0] as PackedStringArray).size()
			for k: int in range(1, 4):
				if (f[k] as PackedInt32Array).size() != count:
					return null
			var type_ids: Array[StringName] = []
			for type_name: String in f[0] as PackedStringArray:
				type_ids.append(StringName(type_name))
			return DeployCommand.new(
				tick, type_ids, f[1], f[2], f[3], f[4], f[5], f[6], f[7],
				f[8] as Formations.Kind, f[9] as UnitType.Faction
			)
		Kind.SPAWN_HERB_PLANT:
			return SpawnHerbPlantCommand.new(tick, f[0], f[1])
		Kind.SPAWN_ENTITY:
			return SpawnEntityCommand.new(tick, f[0], f[1], f[2])
		Kind.SET_VELOCITY:
			return SetVelocityCommand.new(tick, f[0], f[1], f[2], f[3])
		Kind.DESPAWN_ENTITY:
			return DespawnEntityCommand.new(tick, f[0])
	return null


## Whether the fields after kind and tick match `layout` exactly, in number
## and type: the fields before its optional tail, or all of them.
static func _fits(record: Array, layout: String) -> bool:
	var parts: PackedStringArray = layout.split("|")
	var full: String = layout.replace("|", "")
	if record.size() == 2 + parts[0].length():
		full = parts[0]
	elif record.size() != 2 + full.length():
		return false
	for i: int in full.length():
		var value: Variant = record[2 + i]
		match full[i]:
			"I":
				# Both bounds explicitly: absi(INT64_MIN) is INT64_MIN.
				if not value is int or value <= -MAX_MAGNITUDE or value >= MAX_MAGNITUDE:
					return false
			"U":
				if not value is PackedInt32Array or (value as PackedInt32Array).size() > MAX_LIST:
					return false
			"S":
				if not value is PackedStringArray or (value as PackedStringArray).size() > MAX_LIST:
					return false
	return true


# Field i of a decoded record's fields, or 0 where an old record has no tail.
static func _tail(fields: Array, i: int) -> int:
	return fields[i] if i < fields.size() else 0


static func _is_formation(value: int) -> bool:
	return Formations.Kind.values().has(value)


static func _is_faction(value: int) -> bool:
	return UnitType.Faction.values().has(value)
