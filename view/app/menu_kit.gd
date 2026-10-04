class_name MenuKit
extends RefCounted
## The look of the front-end screens, as static builders. There is no Theme
## resource in this project (the HUD overrides per control), so the menus follow
## the HUD's palette and the pause menu's panel: warm cream text, a near-black
## panel, outlined titles. Placeholder styling by design (CLAUDE.md: no art
## time yet); one place to change when there is some.
##
## Also the small formatting rules the screens share: tier names, mm:ss, and a
## veterancy bonus as a percentage.

## The palette: the HUD's cream for titles and names, softer text for the rest,
## and green, red and amber for good, bad and wounded.
const TEXT_COLOR: Color = Color(1.0, 0.95, 0.7)
const BODY_COLOR: Color = Color(0.86, 0.85, 0.8)
const MUTED_COLOR: Color = Color(0.62, 0.62, 0.6)
const GOOD_COLOR: Color = Color(0.6, 1.0, 0.55)
const BAD_COLOR: Color = Color(1.0, 0.4, 0.35)
const WARN_COLOR: Color = Color(1.0, 0.75, 0.35)
const OUTLINE_COLOR: Color = Color(0.05, 0.05, 0.05, 0.9)
## Opaque (the pause menu's panel is 0.96): Settings and the dialogs sit over
## other menus, whose text must not ghost through.
const PANEL_COLOR: Color = Color(0.09, 0.09, 0.1, 1.0)
const BACKDROP_TOP: Color = Color(0.15, 0.14, 0.13)
const BACKDROP_BOTTOM: Color = Color(0.035, 0.035, 0.04)
const DIM_COLOR: Color = Color(0.0, 0.0, 0.0, 0.6)

## Font sizes and widths.
const BODY_SIZE: int = 16
const HEADING_SIZE: int = 22
const TITLE_SIZE: int = 40
const BUTTON_WIDTH: float = 280.0
const PANEL_MARGIN: float = 24.0
## The side of a check box's square, in pixels.
const CHECK_SIZE: int = 18
## The fill of a toggle button that is on.
const SELECTED_COLOR: Color = Color(0.3, 0.26, 0.12)

static var _check_off: ImageTexture
static var _check_on: ImageTexture

## The five difficulty tiers by name, tier 0 first (Difficulty.TIERS of them).
## Normal, tier 2, is the default.
const TIER_NAMES: PackedStringArray = ["Easy", "Moderate", "Normal", "Hard", "Brutal"]
const DEFAULT_TIER: int = 2


## The name of a tier; anything outside 0..4 is called "Tier n".
static func tier_name(tier: int) -> String:
	if tier < 0 or tier >= TIER_NAMES.size():
		return "Tier %d" % tier
	return TIER_NAMES[tier]


## Whole seconds as m:ss ("1:05"), minutes unbounded.
static func clock(seconds: int) -> String:
	@warning_ignore("integer_division")
	var minutes: int = seconds / 60
	return "%d:%02d" % [minutes, seconds % 60]


## A veterancy bonus for display: "+12.5%" for 125 permille, "+30%" for a whole
## number of percent, and "-" for a type whose cap is 0 (it never improves at
## that, so a "0%" would suggest it might).
static func bonus_text(cap_permille: int, kills: int) -> String:
	if cap_permille <= 0:
		return "-"
	var bonus: int = Veterancy.bonus_permille(cap_permille, kills)
	if bonus % 10 == 0:
		@warning_ignore("integer_division")
		var whole: int = bonus / 10
		return "+%d%%" % whole
	return "+%.1f%%" % (bonus / 10.0)


## A text label.
static func label(text: String, size: int = BODY_SIZE, color: Color = BODY_COLOR) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## A label that wraps to the width it is given instead of asking for the width
## of its longest line.
static func paragraph(text: String, size: int = BODY_SIZE, color: Color = BODY_COLOR) -> Label:
	var l: Label = label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Without a minimum a wrapping label collapses to one word wide.
	l.custom_minimum_size.x = 120.0
	return l


## A heading or title: outlined, in the HUD's cream.
static func title(text: String, size: int = TITLE_SIZE, color: Color = TEXT_COLOR) -> Label:
	var l: Label = label(text, size, color)
	l.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	l.add_theme_constant_override("outline_size", 8)
	return l


## A menu button. Unlike the battlefield's HUD buttons it takes keyboard focus:
## this is a menu, and Enter and the arrow keys should work.
static func button(button_name: String, text: String, width: float = BUTTON_WIDTH) -> Button:
	var b: Button = Button.new()
	b.name = button_name
	b.text = text
	b.custom_minimum_size.x = width
	return b


## The pause menu's dark rounded panel, with room inside.
static func panel(margin: float = PANEL_MARGIN) -> PanelContainer:
	var p: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.set_content_margin_all(margin)
	style.set_corner_radius_all(6)
	p.add_theme_stylebox_override("panel", style)
	return p


## An opaque background for a whole screen: a slow dark gradient, so the 3D
## world's clear colour never shows through between missions.
static func backdrop() -> TextureRect:
	var gradient: Gradient = Gradient.new()
	gradient.set_color(0, BACKDROP_TOP)
	gradient.set_color(1, BACKDROP_BOTTOM)
	var texture: GradientTexture2D = GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.5, 0.0)
	texture.fill_to = Vector2(0.5, 1.0)
	var rect: TextureRect = TextureRect.new()
	rect.texture = texture
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_STOP
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return rect


## A dim layer over whatever is under an overlay, taking the mouse so nothing
## beneath is clicked.
static func dim() -> ColorRect:
	var rect: ColorRect = ColorRect.new()
	rect.color = DIM_COLOR
	rect.mouse_filter = Control.MOUSE_FILTER_STOP
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return rect


## Makes a check box readable on the dark panels: the default theme's squares
## are dark on dark. A cream outline, filled in when ticked.
static func style_check(box: CheckBox) -> void:
	if _check_off == null:
		_check_off = _check_icon(false)
		_check_on = _check_icon(true)
	for icon_name: String in ["unchecked", "unchecked_disabled"]:
		box.add_theme_icon_override(icon_name, _check_off)
	for icon_name: String in ["checked", "checked_disabled"]:
		box.add_theme_icon_override(icon_name, _check_on)
	box.add_theme_color_override("font_color", BODY_COLOR)


## Makes a toggle button show that it is on: a warm fill and a cream border
## (the default theme only darkens it, which reads as "off" on these panels).
static func style_selected(toggle: Button) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = SELECTED_COLOR
	style.set_border_width_all(2)
	style.border_color = TEXT_COLOR
	style.set_corner_radius_all(3)
	style.set_content_margin_all(6.0)
	for style_name: String in ["pressed", "hover_pressed"]:
		toggle.add_theme_stylebox_override(style_name, style)
	toggle.add_theme_color_override("font_pressed_color", TEXT_COLOR)
	toggle.add_theme_color_override("font_hover_pressed_color", TEXT_COLOR)


## A vertical scroll area that fills what it is given and never scrolls sideways.
static func scroller() -> ScrollContainer:
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return scroll


## Removes and frees every child. Removed first, so the node count is right at
## once rather than after the frame's deferred frees.
static func clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()


# The square of a check box: a cream border round a dark inside, with a cream
# block in the middle when ticked.
static func _check_icon(ticked: bool) -> ImageTexture:
	var image: Image = Image.create(CHECK_SIZE, CHECK_SIZE, false, Image.FORMAT_RGBA8)
	var inside: Color = Color(0.06, 0.06, 0.07)
	for x: int in CHECK_SIZE:
		for y: int in CHECK_SIZE:
			var edge: bool = x < 2 or y < 2 or x >= CHECK_SIZE - 2 or y >= CHECK_SIZE - 2
			var block: bool = x >= 5 and y >= 5 and x < CHECK_SIZE - 5 and y < CHECK_SIZE - 5
			image.set_pixel(x, y, TEXT_COLOR if edge or (ticked and block) else inside)
	return ImageTexture.create_from_image(image)
