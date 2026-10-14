class_name Pointer
extends RefCounted
## Where the player is pointing: the pad's cursor while the pad is in use
## (InputDevice), else the mouse. The tooltip and anything else that follows
## the pointer ask here, so they follow whichever is in use.

## The pad's cursor in play, registered by PadController; null for none.
static var pad_cursor: PadCursor


## The pointer's position in the viewport.
static func position_in(viewport: Viewport) -> Vector2:
	if using_pad():
		return pad_cursor.at
	return viewport.get_mouse_position()


## True while the pad's cursor is the pointer.
static func using_pad() -> bool:
	return (
		pad_cursor != null and is_instance_valid(pad_cursor) and pad_cursor.is_inside_tree()
		and pad_cursor.visible
	)
