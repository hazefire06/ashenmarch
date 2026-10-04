class_name CampaignFixtures
extends RefCounted
## Builders for campaign data written in code, shared by the campaign tests so
## each one pins only the roster rules it depends on. Missions here use the
## shipped unit catalog (TestTerrains.catalog()) and a script with one idle
## Husk group, which validates against it; none of them starts the mission
## unless a test does.

const M: int = 1000


## Five short given names, so a test reaches the wrap (and its numerals) in a
## few soldiers. A CampaignDef's real list is much longer.
static func names(count: int = 5) -> PackedStringArray:
	var all: PackedStringArray = PackedStringArray(["Ada", "Bram", "Cole", "Dara", "Eben", "Finn", "Gale"])
	var out: PackedStringArray = PackedStringArray()
	for i: int in count:
		out.append(all[i % all.size()])
	return out


## A roster entry for `type_id` with these per-tier counts.
static func entry(
	type_id: StringName, counts: PackedInt32Array = PackedInt32Array([1]), carryover: bool = true
) -> RosterEntry:
	var e: RosterEntry = RosterEntry.new()
	e.type_id = type_id
	e.counts = counts
	e.carryover = carryover
	return e


## A soldier record. hp 0 is full health.
static func soldier(id: int, type_id: StringName, kills: int = 0, hp: int = 0) -> Soldier:
	var s: Soldier = Soldier.new(id, type_id, "Soldier %d" % id)
	s.kills = kills
	s.hp = hp
	return s


## A campaign state at this tier whose alive pool is `soldiers`, with
## next_soldier_id past the highest id among them.
static func state(soldiers: Array[Soldier], tier: int = 2, campaign_seed: int = 1) -> CampaignState:
	var s: CampaignState = CampaignState.new_campaign(campaign_seed, tier)
	for member: Soldier in soldiers:
		s.soldiers.append(member)
		s.next_soldier_id = maxi(s.next_soldier_id, member.id + 1)
	return s


## A mission over the shipped Riverside map that validates against the shipped
## catalog, deploying at (deploy_x, deploy_z) metres. The default point is
## inside the flat 120 m terrain the world tests build.
static func mission(
	mission_id: StringName, roster: Array[RosterEntry], deploy_x: int = 60, deploy_z: int = 60
) -> MissionDef:
	var m: MissionDef = MissionDef.new()
	m.id = mission_id
	m.display_name = String(mission_id).capitalize()
	m.briefing = "Hold the line.\nLose no one."
	m.map = load("res://maps/riverside/riverside.tres") as MapInfo
	m.rules = MissionFixtures.script([MissionFixtures.group(&"husks")], [])
	m.roster = roster
	m.deploy = PackedInt32Array([deploy_x * M, deploy_z * M])
	m.camera_start = PackedInt32Array([deploy_x * M, deploy_z * M])
	return m


## A campaign of these missions with `name_count` distinct names.
static func campaign(missions: Array[MissionDef], name_count: int = CampaignDef.MIN_NAMES) -> CampaignDef:
	var c: CampaignDef = CampaignDef.new()
	c.missions = missions
	for i: int in name_count:
		c.soldier_names.append("Name%d" % i)
	return c


## A flat 120 m world with the plan's deploy applied (one step taken, so the
## soldiers stand in it) and no mission started.
static func deployed_world(plan: DeployPlan, deployed_mission: MissionDef) -> World:
	var w: World = World.new(1, TestTerrains.flat(120, 120), TestTerrains.catalog())
	w.enqueue(plan.command(0, deployed_mission))
	w.step()
	return w


## The unit playing this campaign soldier, or null.
static func unit_of(w: World, soldier_id: int) -> Unit:
	for u: Unit in w.units:
		if u.soldier_id == soldier_id:
			return u
	return null
