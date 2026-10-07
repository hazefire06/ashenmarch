class_name MissionLaunch
extends RefCounted
## What MainView needs to play one mission: which mission, at what difficulty,
## the seed its dice come from, and the roster to put on the field. The App
## builds one from a CampaignState (plan_deploy, mission_seed) and hands it to
## MainView.launch before the scene enters the tree; a MainView with no launch
## is the sandbox the demos use. A plain data holder, so nothing here is
## checked: MissionSetup.create_world refuses what it can't use.
##
## A skirmish is a launch too (for_skirmish): `skirmish` holds the whole setup,
## `mission` and `deploy` are null, and SkirmishSetup.create_world builds the
## world instead.

## The mission to play.
var mission: MissionDef
## The difficulty tier, 0..Difficulty.TIERS - 1.
var tier: int = 0
## The world's seed (CampaignState.mission_seed for a campaign). A Retry passes
## the same one, so the waves come the same.
var world_seed: int = 0
## The player's roster, built for tick 0 (DeployPlan.command(0, mission)).
var deploy: DeployCommand
## True in the campaign and in a skirmish: the debug side switch (F9 and the
## bar's button) and the debug weather key (F6) are off, and losing the
## window's focus pauses. Development launches leave it false to keep them.
var campaign_mode: bool = true
## The skirmish to play, or null for a campaign mission.
var skirmish: SkirmishSetup


func _init(
	mission_def: MissionDef = null, mission_tier: int = 0, seed_value: int = 0,
	deploy_command: DeployCommand = null, campaign: bool = true
) -> void:
	mission = mission_def
	tier = mission_tier
	world_seed = seed_value
	deploy = deploy_command
	campaign_mode = campaign


## A launch for a skirmish: the setup's seed, tier SkirmishSetup.TIER, and
## campaign_mode on (no debug keys; a lost focus pauses).
static func for_skirmish(setup: SkirmishSetup) -> MissionLaunch:
	var launch: MissionLaunch = MissionLaunch.new(null, SkirmishSetup.TIER, setup.world_seed, null, true)
	launch.skirmish = setup
	return launch


## True for a skirmish.
func is_skirmish() -> bool:
	return skirmish != null


## The side the player commands: the skirmish's choice, Light in the campaign.
func player_faction() -> UnitType.Faction:
	return skirmish.player_faction() if skirmish != null else UnitType.Faction.LIGHT
