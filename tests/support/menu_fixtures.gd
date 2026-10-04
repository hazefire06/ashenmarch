class_name MenuFixtures
extends RefCounted
## Helpers shared by the front-end screen tests: the shipped campaign and
## catalog, a way to read every label under a node, and a finished-mission
## fixture (a world with the plan deployed and some of it dead) so the results
## screen and the App's victory handling can be tested without playing one.

const SHIELDMAN: StringName = &"shieldman"
const LONGBOW: StringName = &"longbow"
const HUSK: StringName = &"husk"


static func campaign() -> CampaignDef:
	return load("res://data/campaign/campaign.tres") as CampaignDef


static func catalog() -> UnitCatalog:
	return load("res://data/units/catalog.tres") as UnitCatalog


## Every Label's text under `node`, in tree order.
static func texts(node: Node) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if node is Label:
		out.append((node as Label).text)
	for child: Node in node.get_children():
		out.append_array(texts(child))
	return out


## True if some label under `node` says exactly this.
static func says(node: Node, text: String) -> bool:
	return texts(node).has(text)


## True if some label under `node` contains this.
static func mentions(node: Node, part: String) -> bool:
	for text: String in texts(node):
		if text.contains(part):
			return true
	return false


## The first node under `root` with this name (an Object-typed handle: cast it).
static func named(root: Node, node_name: String) -> Node:
	return root.find_child(node_name, true, false)


## Presses a button the way a click ends: the `pressed` signal.
static func press(root: Node, button_name: String) -> void:
	var button: Button = named(root, button_name) as Button
	assert(button != null, "no button called %s" % button_name)
	button.pressed.emit()


## Plays a mission out without running one: a flat world with the plan
## deployed (one step, so the soldiers stand in it), `stats` begun on it, then
## what happened is written straight into the units and `stats` is finished.
## `dead_soldiers` are soldier ids killed; `kills_made` adds that many kills to
## a soldier's unit; `wounded` sets a soldier's hp; `dead_husks` Husks are
## spawned and killed. Returns the world, which is what the results screen and
## CampaignState.apply_victory read.
static func play_out(
	plan: DeployPlan, mission: MissionDef, stats: MissionStats, dead_soldiers: Array[int] = [],
	kills_made: Dictionary[int, int] = {}, dead_husks: int = 0, wounded: Dictionary[int, int] = {}
) -> World:
	var world: World = CampaignFixtures.deployed_world(plan, mission)
	stats.begin(world)
	for i: int in dead_husks:
		world.enqueue(SpawnUnitCommand.new(world.tick, HUSK, UnitType.Faction.DARK, (10 + i) * 1000, 10_000, 0, 1))
	world.step()
	for unit: Unit in world.units:
		if unit.faction == UnitType.Faction.DARK:
			unit.state = Unit.State.DEAD
	for id: int in kills_made:
		CampaignFixtures.unit_of(world, id).kills += kills_made[id]
	for id: int in wounded:
		CampaignFixtures.unit_of(world, id).hp = wounded[id]
	for id: int in dead_soldiers:
		CampaignFixtures.unit_of(world, id).state = Unit.State.DEAD
	stats.finish(world)
	return world
