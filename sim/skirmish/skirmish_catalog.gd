class_name SkirmishCatalog
extends Resource
## Everything the skirmish screen offers, as data (data/skirmish/skirmish.tres):
## the AI's army templates and the budget and time-limit choices. An explicit
## list rather than a directory scan, for the reason UnitCatalog gives
## (exported builds rename .tres files).

## Every AI army template, both sides'; ids are unique.
@export var templates: Array[ArmyTemplate] = []
## The budgets a skirmish may be played at, in points, ascending.
@export var budgets: PackedInt32Array = PackedInt32Array()
## The budget the screen starts on; one of budgets.
@export var default_budget: int = 0
## The time limits a skirmish may be played at, in minutes, ascending.
@export var time_limits_minutes: PackedInt32Array = PackedInt32Array()
## The time limit the screen starts on; one of time_limits_minutes.
@export var default_time_limit_minutes: int = 0


## The template with this id, or null.
func template(template_id: StringName) -> ArmyTemplate:
	for t: ArmyTemplate in templates:
		if t != null and t.id == template_id:
			return t
	return null


## The templates for one side, in list order.
func templates_for(side: UnitType.Faction) -> Array[ArmyTemplate]:
	var out: Array[ArmyTemplate] = []
	for t: ArmyTemplate in templates:
		if t != null and t.faction == side:
			out.append(t)
	return out


## Problems with the catalog or anything in it, or an empty array. Every one
## is listed.
func validate(catalog: UnitCatalog) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	var seen: Dictionary[StringName, bool] = {}
	for i: int in templates.size():
		var t: ArmyTemplate = templates[i]
		if t == null:
			errors.append("template %d is null" % i)
			continue
		errors.append_array(t.validate(catalog))
		if t.id != &"" and seen.has(t.id):
			errors.append("duplicate template id %s" % t.id)
		seen[t.id] = true
	for side: int in UnitType.Faction.size():
		if templates_for(side).is_empty():
			errors.append("no template for faction %d" % side)
	errors.append_array(_validate_choices("budgets", budgets, default_budget))
	errors.append_array(_validate_choices(
		"time_limits_minutes", time_limits_minutes, default_time_limit_minutes
	))
	return errors


static func _validate_choices(field: String, values: PackedInt32Array, default_value: int) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if values.is_empty():
		errors.append("%s is empty" % field)
	for i: int in values.size():
		if values[i] <= 0:
			errors.append("%s[%d] must be positive" % [field, i])
		if i > 0 and values[i] <= values[i - 1]:
			errors.append("%s must ascend" % field)
	if not values.has(default_value):
		errors.append("the default %d is not one of %s" % [default_value, field])
	return errors
