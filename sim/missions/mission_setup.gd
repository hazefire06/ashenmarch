class_name MissionSetup
extends RefCounted
## The one place a World is built from a MissionDef. The view (MainView) and
## the headless playtester both go through it, so a mission is set up the same
## way wherever it is played; it is static because it holds nothing. No file IO
## here beyond the map the MissionDef names (Terrain.load_map), and no clock.


## A world ready to step for `mission` at `tier` (0..Difficulty.TIERS-1),
## seeded with `world_seed` (CampaignState.mission_seed for a campaign), with
## everything the first tick needs queued, in this order so the entity ids are
## stable: the player's roster (`deploy`, built for tick 0 by
## DeployPlan.command), then a herb plant for each of the map's herb_plants
## (like MainView always did), then the mission started, whose starting groups
## spawn inside the first step. Returns null, after push_error, if the mission,
## its map, the deploy or the catalog is missing, the map can't be loaded, or
## the mission's rules won't start (an out-of-range tier, a script that doesn't
## validate against the catalog).
static func create_world(
	mission: MissionDef, tier: int, world_seed: int, deploy: DeployCommand, catalog: UnitCatalog
) -> World:
	var problem: String = ""
	if mission == null:
		problem = "there is no mission"
	elif mission.map == null:
		problem = "mission %s has no map" % mission.id
	elif deploy == null:
		problem = "there is no deploy command"
	elif catalog == null:
		problem = "there is no unit catalog"
	if problem != "":
		push_error("MissionSetup.create_world: " + problem)
		return null
	var terrain: Terrain = Terrain.load_map(mission.map)
	if terrain == null:
		push_error("MissionSetup.create_world: could not load the map of mission %s" % mission.id)
		return null
	var world: World = World.new(world_seed, terrain, catalog)
	world.enqueue(deploy)
	var herbs: PackedInt32Array = mission.map.herb_plants
	for k: int in range(0, herbs.size() - 1, 2):
		world.enqueue(SpawnHerbPlantCommand.new(world.tick, herbs[k], herbs[k + 1]))
	# start_mission says why itself (push_error) when it refuses.
	if not world.start_mission(mission.rules, tier):
		return null
	return world
