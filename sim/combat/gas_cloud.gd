class_name GasCloud
extends SimEntity
## A cloud of paralyzing gas left by a burst (ProjectileType.gas_radius: a
## Blightbag, a gas packet). It hangs where it burst for its time and
## paralyzes every living unit inside it, either side, undead included,
## every tick (StatusEffects): a unit stays paralyzed paralysis_ticks after it
## was last in it. It neither drifts nor spreads.

## Milli-units above and below its center a body can be and still be in it.
const HEIGHT: int = 3000

## Milli-units, measured to a body's edge.
var radius: int
## Ticks it still acts; it is gone after the tick this reaches 0.
var ticks_left: int
var paralysis_ticks: int
## Whoever set off the burst that left it (0 for none). Gas never kills, so
## this is for the view and the record.
var instigator_id: int
## Flagged once spent; World drops it at the end of the tick.
var removed: bool = false


func _init(
	entity_id: int, pos_x: int, pos_y: int, pos_z: int,
	cloud_radius: int, ticks: int, paralysis: int, instigator: int
) -> void:
	super(entity_id, pos_x, pos_y, pos_z)
	radius = cloud_radius
	ticks_left = ticks
	paralysis_ticks = paralysis
	instigator_id = instigator


## True if the unit's body is in the cloud: its edge within radius of the
## center horizontally, and its feet within HEIGHT of it.
func contains(unit: Unit) -> bool:
	if absi(unit.y - y) > HEIGHT:
		return false
	var reach: int = radius + unit.type.body_radius
	var dx: int = unit.x - x
	var dz: int = unit.z - z
	return dx * dx + dz * dz <= reach * reach


func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = super()
	fields.append_array(PackedInt64Array([radius, ticks_left, paralysis_ticks, instigator_id, 1 if removed else 0]))
	return fields
