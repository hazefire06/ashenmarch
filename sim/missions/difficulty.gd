class_name Difficulty
extends RefCounted
## The five difficulty tiers (CLAUDE.md), 0 easiest to 4 hardest. Mission data
## that varies by tier (unit counts, spawn points, timer lengths) is stored
## as a PackedInt32Array with either one entry, used at every tier, or one
## per tier, so a mission only spells out the tiers it changes.

const TIERS: int = 5


## True if values has the shape pick() needs: one entry or one per tier.
static func is_valid(values: PackedInt32Array) -> bool:
	return values.size() == 1 or values.size() == TIERS


## The value for tier (0..TIERS-1). Callers validate first with is_valid().
static func pick(values: PackedInt32Array, tier: int) -> int:
	return values[0] if values.size() == 1 else values[tier]
