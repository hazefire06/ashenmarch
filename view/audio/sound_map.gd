class_name SoundMap
extends Resource
## Which cue each unit type and projectile makes, which voices the light side
## speaks with, and which music each map plays. Written by hand; the bank says
## what a cue sounds like, this says who makes it. View only.

const PATH: String = "res://data/audio/sound_map.tres"
const LIVING: StringName = &"_living"
const UNDEAD: StringName = &"_undead"

@export var units: Array[UnitSound] = []
@export var projectiles: Array[ProjectileSound] = []
@export var music: Array[MusicPair] = []
## Played by a map with no pair of its own.
@export var default_music: MusicPair

## The session's map, loaded once and never freed (an empty one if PATH is missing).
static var _shared: SoundMap = null


static func shared() -> SoundMap:
	if _shared == null:
		if ResourceLoader.exists(PATH):
			_shared = load(PATH) as SoundMap
		if _shared == null:
			push_warning("SoundMap: %s is missing; units and projectiles will be silent" % PATH)
			_shared = SoundMap.new()
	return _shared


## The type's own entry, else the _living or _undead one by nature (null only
## in an empty map).
func for_unit(type: UnitType) -> UnitSound:
	var own: UnitSound = _unit(type.id)
	if own != null:
		return own
	return _unit(UNDEAD if type.nature == UnitType.Nature.UNDEAD else LIVING)


## The type's death cue if the bank has it, else its nature's.
func death_cue(type: UnitType, bank: SoundBank) -> StringName:
	var own: UnitSound = for_unit(type)
	if own == null:
		return &""
	if bank.has(own.death):
		return own.death
	var general: UnitSound = _nature_entry(type)
	return general.death if general != null else &""


## The type's groan if the bank has it, else its nature's; &"" for the living.
func groan_cue(type: UnitType, bank: SoundBank) -> StringName:
	var own: UnitSound = for_unit(type)
	if own == null:
		return &""
	if own.groan != &"" and bank.has(own.groan):
		return own.groan
	var general: UnitSound = _nature_entry(type)
	return general.groan if general != null else &""


## The voice this unit speaks with, or &"" if its type has none.
func voice_for(unit: Unit) -> StringName:
	var entry: UnitSound = for_unit(unit.type)
	if entry == null or entry.voices.is_empty():
		return &""
	return entry.voices[unit.id % entry.voices.size()]


func for_projectile(id: StringName) -> ProjectileSound:
	for p: ProjectileSound in projectiles:
		if p.projectile_id == id:
			return p
	return null


func music_for(map_id: StringName) -> MusicPair:
	for pair: MusicPair in music:
		if pair.map_id == map_id:
			return pair
	return default_music


func _unit(id: StringName) -> UnitSound:
	for u: UnitSound in units:
		if u.type_id == id:
			return u
	return null


func _nature_entry(type: UnitType) -> UnitSound:
	return _unit(UNDEAD if type.nature == UnitType.Nature.UNDEAD else LIVING)
