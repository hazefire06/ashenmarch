class_name CombatEvent
extends RefCounted
## Something that happened in a fight during a tick, for the view (flashes,
## gibs, later sound): melee blows, arrows, and blasts alike. attacker_id is
## the unit credited (the shooter or the blast's instigator); it may be 0 or
## a dead unit. Output only: World clears its list at the start of each
## step, and events are never part of state_hash().

enum Kind {
	## A wind-up started; the blow lands melee_windup_ticks later.
	SWING,
	## A blow landed and the target lived.
	HIT,
	## A frontal blow was stopped by the target's shield.
	BLOCK,
	## A blow missed: the accuracy roll failed or the target had stepped out
	## of reach during the wind-up.
	MISS,
	## A blow killed the target.
	KILL,
	## A healer's herb took effect: damage is the hit points given back (0 on
	## an undead target, which the herb killed: a KILL comes with it).
	HEAL,
}

var kind: Kind
var attacker_id: int
var target_id: int
## Hit points the blow removed (HIT and KILL); 0 otherwise.
var damage: int
## KILL only: damage beyond the hit points the target had left.
var overkill: int
## Where the blow came from relative to the target's facing.
var aspect: MeleeCombat.Aspect
## Ground position (milli-units) the blow came from: the attacker in melee,
## the blast center, the arrow's approach. The view throws bodies and gibs
## away from it.
var source_x: int = 0
var source_z: int = 0


func _init(
	event_kind: Kind, attacker: int, target: int,
	blow_aspect: MeleeCombat.Aspect = MeleeCombat.Aspect.FRONT,
	blow_damage: int = 0, blow_overkill: int = 0
) -> void:
	kind = event_kind
	attacker_id = attacker
	target_id = target
	aspect = blow_aspect
	damage = blow_damage
	overkill = blow_overkill
