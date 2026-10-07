class_name UiSounds
extends Node
## A click for every button pressed anywhere in the game: menus, the HUD, the
## replay bar. The App adds one; it watches the tree for buttons as they are
## added rather than every screen wiring its own, so a new screen clicks with
## no change here.

var _player: AudioStreamPlayer


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.stream = SfxBank.stream(&"ui_click")
	_player.volume_db = SfxBank.level_db(&"ui_click")
	_player.bus = &"Interface"
	add_child(_player)
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node is BaseButton and not (node as BaseButton).pressed.is_connected(_click):
		(node as BaseButton).pressed.connect(_click)


func _click() -> void:
	_player.play()
