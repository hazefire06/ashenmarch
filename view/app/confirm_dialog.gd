class_name ConfirmDialog
extends MenuScreen
## A yes-or-no question over whatever is beneath it (a dim layer takes the
## mouse). Used where an answer destroys something: a new campaign over a save,
## and restarting a mission. The keyboard starts on the safe answer, and Esc
## is that answer: a stray Enter or Esc never destroys anything.
## Whoever asked removes the dialog after either signal.

## The yes answer.
signal confirmed
## The no answer, or Esc.
signal cancelled

var _cancel_button: Button
var _confirm_button: Button


func _init() -> void:
	super(false)


## Fills the dialog: the question, and the two answers' labels.
func setup(message: String, confirm_text: String = "Yes", cancel_text: String = "No") -> void:
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel: PanelContainer = MenuKit.panel()
	center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	panel.add_child(column)
	var question: Label = MenuKit.paragraph(message, MenuKit.BODY_SIZE + 2, MenuKit.TEXT_COLOR)
	question.name = "Question"
	question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	question.custom_minimum_size.x = 380.0
	column.add_child(question)
	var answers: HBoxContainer = HBoxContainer.new()
	answers.add_theme_constant_override("separation", 12)
	answers.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(answers)
	_cancel_button = MenuKit.button("CancelButton", cancel_text, 160.0)
	_cancel_button.pressed.connect(func() -> void: cancelled.emit())
	answers.add_child(_cancel_button)
	_confirm_button = MenuKit.button("ConfirmButton", confirm_text, 160.0)
	_confirm_button.pressed.connect(func() -> void: confirmed.emit())
	answers.add_child(_confirm_button)
	if is_inside_tree():
		_focus_default()


func _focus_default() -> void:
	_focus(_cancel_button)


func _cancel() -> bool:
	cancelled.emit()
	return true
