class_name UnitArtSet
extends RefCounted
## The unit art one game draws with (docs/specs/2026-10-15-art-a4-loading-design.md
## §5). MainView builds it from the types its launch can bring on
## (MissionLaunch.unit_types), which load and validate before the first frame,
## so a battle never stops to load. A type the list missed that the catalog
## has art for loads on its first sprite, with one warning: a hitch, never a
## missing body. Art that fails UnitArt.validate() is left out with a warning
## per reason, and its unit stays a placeholder. Each type is tried once. The
## MainView owns the set, so leaving a game frees its sheets.

## How long the first load took, in ms.
var load_ms: int = 0

var _catalog: UnitArtCatalog
var _arts: Dictionary[StringName, UnitArt] = {}
## Types tried that have no usable art.
var _none: Dictionary[StringName, bool] = {}


## The art of type_ids from catalog, loaded now.
static func for_types(type_ids: Array[StringName], catalog: UnitArtCatalog) -> UnitArtSet:
	var arts: UnitArtSet = UnitArtSet.new()
	arts._catalog = catalog
	var started_ms: int = Time.get_ticks_msec()
	for type_id: StringName in type_ids:
		arts._load(type_id)
	arts.load_ms = Time.get_ticks_msec() - started_ms
	return arts


## Art already in memory, with no catalog behind it: tests, and art built in
## code. Art that fails validation is left out, with a warning per reason.
static func of(arts: Array[UnitArt]) -> UnitArtSet:
	var out: UnitArtSet = UnitArtSet.new()
	for art: UnitArt in arts:
		out._keep(art.unit_id, art)
	return out


## The type's art, or null to draw it as a placeholder. A type not loaded yet
## that the catalog has art for loads now, with a warning.
func find(type_id: StringName) -> UnitArt:
	if _arts.has(type_id):
		return _arts[type_id]
	if _none.has(type_id) or _catalog == null or not _catalog.has(type_id):
		return null
	push_warning("UnitArtSet: %s's art loaded late, on its first sprite; MissionLaunch.unit_types() should list it" % type_id)
	return _load(type_id)


## The types whose art is loaded, sorted.
func loaded_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(_arts.keys())
	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return out


## The loaded art, by type id.
func arts() -> Array[UnitArt]:
	var out: Array[UnitArt] = []
	for type_id: StringName in loaded_ids():
		out.append(_arts[type_id])
	return out


## GPU bytes of every loaded sheet (UnitArt.sheet_bytes).
func sheet_bytes() -> int:
	var total: int = 0
	for art: UnitArt in _arts.values():
		total += art.sheet_bytes()
	return total


func _load(type_id: StringName) -> UnitArt:
	if _arts.has(type_id):
		return _arts[type_id]
	if _none.has(type_id):
		return null
	var art: UnitArt = _catalog.load_art(type_id) if _catalog != null else null
	if art == null:
		if _catalog != null and _catalog.has(type_id):
			push_warning("UnitArtSet: unit art left out: %s: %s is not a UnitArt" % [type_id, _catalog.path_of(type_id)])
		_none[type_id] = true
		return null
	return _keep(type_id, art)


func _keep(type_id: StringName, art: UnitArt) -> UnitArt:
	var reasons: PackedStringArray = art.validate()
	if not reasons.is_empty():
		for reason: String in reasons:
			push_warning("UnitArtSet: unit art left out: %s" % reason)
		_none[type_id] = true
		return null
	_arts[type_id] = art
	return art
