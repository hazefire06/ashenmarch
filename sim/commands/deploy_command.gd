class_name DeployCommand
extends SimCommand
## A campaign roster entering the world as one command, at tick 0: the
## soldiers a mission starts with, each carrying who it is (soldier_id), what
## it has killed, and how hurt it is, so veterancy and wounds carry over from
## one mission to the next. Entry i of every array is one soldier. Mismatched
## array lengths are a bug in whatever built the command: it says so and does
## nothing.
##
## The roster goes in front to back, so list the melee entries first, as a
## group spec does: the formation puts the first entries at its front.
## apply() lays out the block with World.spawn_block, so the layout and the
## entity ids are the ones an AI group of the same types gets, and a mission's
## starting groups, spawned right after the commands, are numbered after it.

## Catalog ids of the soldiers, in roster order. An id the catalog doesn't know
## is skipped (its entry in every array with it), not an error.
var type_ids: Array[StringName]
## The campaign soldier each entry is (Unit.soldier_id).
var soldier_ids: PackedInt32Array
## Kills each entry has made; negative counts as none.
var kills: PackedInt32Array
## Hit points each entry has, kept between 1 and its type's maximum. 0 or less
## means full health, so a recruit needs no number.
var hp: PackedInt32Array
## Where the block is centered and the way it faces; a facing of 0, 0 is north.
var x: int
var z: int
var facing_x: int
var facing_z: int
var formation: Formations.Kind
## The side the units fight for.
var faction: UnitType.Faction


func _init(
	at_tick: int, ids: Array[StringName], soldiers: PackedInt32Array, kill_counts: PackedInt32Array,
	hit_points: PackedInt32Array, at_x: int, at_z: int, face_x: int, face_z: int,
	form: Formations.Kind = Formations.Kind.BOX, side: UnitType.Faction = UnitType.Faction.LIGHT
) -> void:
	super(at_tick)
	type_ids = ids.duplicate()
	soldier_ids = soldiers.duplicate()
	kills = kill_counts.duplicate()
	hp = hit_points.duplicate()
	x = at_x
	z = at_z
	facing_x = face_x
	facing_z = face_z
	formation = form
	faction = side


func apply(world: World) -> void:
	var count: int = type_ids.size()
	if soldier_ids.size() != count or kills.size() != count or hp.size() != count:
		push_error(
			"DeployCommand: %d types, %d soldier ids, %d kill counts and %d hit points don't line up"
			% [count, soldier_ids.size(), kills.size(), hp.size()]
		)
		return
	if world.catalog == null:
		return
	# Unknown types go first, with their entries in the other arrays, so what
	# is left stays aligned and the formation has no gaps.
	var type_indices: Array[int] = []
	var entries: Array[int] = []
	for i: int in count:
		var type_index: int = world.catalog.index_of(type_ids[i])
		if type_index >= 0:
			type_indices.append(type_index)
			entries.append(i)
	var block: Array[Unit] = world.spawn_block(type_indices, faction, x, z, facing_x, facing_z, formation)
	for k: int in block.size():
		var unit: Unit = block[k]
		var i: int = entries[k]
		unit.soldier_id = soldier_ids[i]
		unit.kills = maxi(0, kills[i])
		unit.hp = unit.type.max_hp if hp[i] <= 0 else clampi(hp[i], 1, unit.type.max_hp)
