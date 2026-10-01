class_name HerbPlant
extends SimEntity
## A herb plant growing on the map (MapInfo.herb_plants): struck once by a
## unit sent to it (Interactions), it drops ROOTS herbs at its foot and is
## spent for the rest of the mission. It never moves, and nothing else
## touches it: blasts, fire, and bodies pass it by.

## Milli-units: how wide it is, for reach.
const RADIUS: int = 400
## Herbs a strike knocks loose.
const ROOTS: int = 2
## Projectile id of what it drops.
const ROOT_PROJECTILE: StringName = &"herb"
## Milli-units from its center to where the herbs land.
const DROP_SPREAD: int = 700

## Struck already: nothing left to give.
var spent: bool = false


func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = super()
	fields.append(1 if spent else 0)
	return fields
