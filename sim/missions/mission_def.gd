class_name MissionDef
extends Resource
## A campaign mission as data, one .tres each: the map, the opposition
## and rules (a MissionScript), the fixed roster the player deploys, where, and
## how the camera first looks at it. Adding a mission is adding one of these
## and a map, not engine code.
##
## Each mission has a FIXED roster: survivors of earlier missions fill the
## slots of their own type (CampaignState.plan_deploy), and an empty slot gets a
## fresh recruit, so the player never has fewer soldiers than the mission is
## balanced for. Read-only at runtime: load() hands every world the same
## instance.
##
## The View group holds fields only the view reads, on a sim resource because
## they belong to the mission's data: `atmosphere` is a view class (a pure data
## Resource with no Nodes), following the UnitType.placeholder_color
## precedent. Nothing that steps a World (the AI, the triggers, the combat)
## reads these fields; only validate() checks them and the view uses them.
##
## Facing defaults to 1 south (0, 1), not 0, 0 (which means north), and the
## camera distance to 75000, because those are the common case; Godot leaves
## defaults out of the .tres.

## Stable key: what a CampaignState's history and a soldier's fallen_in name,
## and what a DeployPlan is checked against. Unique within a CampaignDef.
@export var id: StringName = &""
## The name the menus show.
@export var display_name: String = ""
## The briefing text, several lines.
@export_multiline var briefing: String = ""
## The ground the mission is played on.
@export var map: MapInfo
## The Dark side's groups, the triggers, the objectives, and the outcome.
@export var rules: MissionScript
## Who deploys, in order; see RosterEntry.
@export var roster: Array[RosterEntry] = []
## Where the roster block is centered, as one x, z pair in milli-units.
@export var deploy: PackedInt32Array = PackedInt32Array()
## The way the roster block faces, as a direction; 0, 0 would mean north, the
## default (0, 1) is south.
@export var deploy_facing_x: int = 0
## See deploy_facing_x.
@export var deploy_facing_z: int = 1
## The shape the roster block is laid out in, front to back in roster order.
@export var deploy_formation: Formations.Kind = Formations.Kind.BOX

@export_group("View")
## Where the camera is looking at the start, as one x, z pair in milli-units.
@export var camera_start: PackedInt32Array = PackedInt32Array()
## How far the camera starts from that point, in milli-units.
@export var camera_distance: int = 75000
## The mission's look; null leaves the view's own default (Atmosphere's
## defaults are that look).
@export var atmosphere: Atmosphere


## Problems that make the mission unusable, or an empty array. Every one is
## listed. `catalog` is what the roster's and the script's unit types are
## checked against.
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if id == &"":
		errors.append("id is empty")
	if display_name.is_empty():
		errors.append("display_name is empty")
	if map == null:
		errors.append("map is missing")
	if rules == null:
		errors.append("rules is missing")
	else:
		for problem: String in rules.validate(catalog):
			errors.append("rules: " + problem)
	if deploy.size() != 2 or deploy[0] < 0 or deploy[1] < 0:
		errors.append("deploy must be one non-negative x, z pair")
	if camera_start.size() != 2:
		errors.append("camera_start must be one x, z pair")
	if camera_distance <= 0:
		errors.append("camera_distance must be positive")
	if not Formations.Kind.values().has(deploy_formation):
		errors.append("deploy_formation is not a Formations.Kind")
	errors.append_array(_validate_roster(catalog))
	if atmosphere != null:
		for problem: String in atmosphere.validate():
			errors.append("atmosphere: " + problem)
	return errors


# Every roster entry names a type the player can command, its counts have the
# per-tier shape, and every tier deploys someone (an empty tier would leave
# the Light side unseen, so PLAYER_ELIMINATED could never fire).
func _validate_roster(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	# Per tier, how many the well-formed entries deploy.
	var deployed: PackedInt32Array = PackedInt32Array()
	deployed.resize(Difficulty.TIERS)
	for i: int in roster.size():
		var entry: RosterEntry = roster[i]
		if entry == null:
			errors.append("roster entry %d is null" % i)
			continue
		var where: String = "roster entry %d (%s)" % [i, entry.type_id]
		var problem: String = _type_problem(catalog, entry.type_id)
		if problem != "":
			errors.append("%s: %s" % [where, problem])
		if not Difficulty.is_valid(entry.counts):
			errors.append("%s: counts needs 1 or %d entries" % [where, Difficulty.TIERS])
			continue
		var negative: bool = false
		for tier: int in Difficulty.TIERS:
			var count: int = Difficulty.pick(entry.counts, tier)
			negative = negative or count < 0
			deployed[tier] += maxi(0, count)
		if negative:
			errors.append("%s: counts can't be negative" % where)
	for tier: int in Difficulty.TIERS:
		if deployed[tier] == 0:
			errors.append("the roster deploys no one at tier %d" % tier)
	return errors


# Why a roster can't hold this type, or "". It must exist, be the player's
# (Light), and fight or do something: the Villager is the only Light type that
# never does, and is led, not commanded, so it never belongs to a roster.
func _type_problem(catalog: UnitCatalog, type_id: StringName) -> String:
	var type: UnitType = catalog.find(type_id)
	if type == null:
		return "unknown unit type"
	if type.faction != UnitType.Faction.LIGHT:
		return "not a Light unit"
	if type.melee_damage == 0 and not type.has_ranged() and type.special_ability == UnitType.Special.NONE:
		return "a non-combatant can't be rostered"
	return ""
