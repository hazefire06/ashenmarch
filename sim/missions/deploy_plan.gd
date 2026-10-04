class_name DeployPlan
extends RefCounted
## What a mission will deploy: for each slot of its roster, in roster order,
## which soldier stands in it. CampaignState.plan_deploy makes one and changes
## nothing, so the player can bench veterans and re-plan as often as they
## like; only CampaignState.apply_victory commits it (the recruits join the
## roll then). The slot arrays are parallel: entry i of each describes slot i.
##
## The menus show the plan (name, type, kills, wounds, new or veteran), and
## command() turns it into the DeployCommand a world starts from.

## The campaign soldier in each slot: a veteran's own id, or a recruit's
## provisional one (the next ids CampaignState hands out, not yet committed).
var soldier_ids: PackedInt32Array = PackedInt32Array()
## The unit type of each slot (Soldier.type_id).
var type_ids: Array[StringName] = []
## True where the slot is a fresh recruit rather than a surviving veteran.
var is_recruit: Array[bool] = []
## Each slot's soldier's given name.
var names: PackedStringArray = PackedStringArray()
## Kills each slot's soldier deploys with: a veteran's count, 0 for a recruit.
var kills: PackedInt32Array = PackedInt32Array()
## Hit points each slot's soldier deploys with, 0 for full health (a recruit,
## or an unhurt veteran): the DeployCommand convention.
var hp: PackedInt32Array = PackedInt32Array()
## The provisional records of the recruits, in slot order: what apply_victory
## adds to the roll if the mission is won.
var recruits: Array[Soldier] = []


## How many slots there are.
func size() -> int:
	return soldier_ids.size()


## Adds a slot filled by this soldier, a veteran (is_new false) or a recruit
## (true, and his record joins `recruits`). A veteran's record is read, not
## kept: later changes to it don't alter the plan.
func add_slot(soldier: Soldier, is_new: bool) -> void:
	soldier_ids.append(soldier.id)
	type_ids.append(soldier.type_id)
	is_recruit.append(is_new)
	names.append(soldier.name)
	kills.append(soldier.kills)
	hp.append(soldier.hp)
	if is_new:
		recruits.append(soldier)


## The tick-`at_tick` command that puts this roster into a world at the
## mission's deploy point, facing, and formation, in roster order (the
## formation's front gets the first entries). The mission must have validated
## (deploy is one x, z pair).
func command(at_tick: int, mission: MissionDef) -> DeployCommand:
	return DeployCommand.new(
		at_tick, type_ids, soldier_ids, kills, hp, mission.deploy[0], mission.deploy[1],
		mission.deploy_facing_x, mission.deploy_facing_z, mission.deploy_formation
	)
