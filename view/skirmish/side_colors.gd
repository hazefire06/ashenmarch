class_name SideColors
extends RefCounted
## The colors a skirmish uses for its two sides, in one place so the flags in
## the world, the flags on the overhead map and the scoreboard agree: Light is
## blue, Dark crimson, and a flag nobody holds is grey. Placeholder palette by
## design (CLAUDE.md: no art time yet). Faction ints are the sim's, where
## SkirmishRuntime.NO_SIDE (-1) and CONTESTED (-2) are not factions, so anything
## that isn't LIGHT or DARK reads as neutral.

## Nobody: an unheld flag, or the hill with no one on it.
const NEUTRAL: Color = Color(0.62, 0.62, 0.6)
const LIGHT: Color = Color(0.35, 0.6, 1.0)
const DARK: Color = Color(0.8, 0.18, 0.22)


## The color of a side: LIGHT, DARK, or NEUTRAL for NO_SIDE and anything else.
static func of(side: int) -> Color:
	match side:
		UnitType.Faction.LIGHT:
			return LIGHT
		UnitType.Faction.DARK:
			return DARK
	return NEUTRAL


## "Light" or "Dark"; "Nobody" for NO_SIDE and anything else.
static func side_name(side: int) -> String:
	match side:
		UnitType.Faction.LIGHT:
			return "Light"
		UnitType.Faction.DARK:
			return "Dark"
	return "Nobody"
