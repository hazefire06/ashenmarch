class_name PadRumble
extends RefCounted
## Rumble on the pads, from what each tick did (after_step): a blast pulses by
## how big it was and how near the camera's focus, and one of your units dying
## gives a short, weak tick. Strength (Settings > Controller) scales it all; 0
## is off. View-only, like the sound: the sim never hears of it.
##
## Only where it works: a pad whose driver says it can't vibrate is left alone
## (Input.has_joy_vibration). macOS can't vibrate Xbox One and Series pads
## plugged in by USB (Godot's Input.start_joy_vibration note); should a driver
## claim it can anyway, those pads, by vendor and USB product id, are left
## alone too. Over Bluetooth they rumble.

## Meters from the camera's focus beyond which a blast is felt no more.
const BLAST_REACH: float = 45.0
## A blast of this radius (meters) or more pulses at full strength.
const BIG_BLAST: float = 6.0
const BLAST_SECONDS: float = 0.3
const DEATH_WEAK: float = 0.35
const DEATH_SECONDS: float = 0.12
## Milliseconds between pulses, so a chain of satchels is one long shake
## rather than a buzz.
const GAP_MSEC: int = 90
## Microsoft's vendor id, and its Xbox pads' product ids over USB (over
## Bluetooth they report others).
const XBOX_VENDOR: int = 0x045E
const XBOX_USB_PRODUCTS: Array[int] = [0x02D1, 0x02DD, 0x02E3, 0x02EA, 0x0B00, 0x0B12]

## 0 (off) .. 1.
var strength: float = 0.7
## The pulses sent, newest last, as [device, weak, strong, seconds], for a
## test to read (the headless engine has no pad to feel them).
var sent: Array[Array] = []
var _next_msec: int = 0


## Pulses for what this tick did: blasts near `focus` (meters), and deaths
## among `side`'s units.
func after_step(world: World, focus: Vector3, side: UnitType.Faction) -> void:
	if strength <= 0.0:
		return
	var felt: Vector3 = felt(world, focus, side)
	if felt.z > 0.0 and (felt.y > 0.02 or felt.x > 0.02):
		pulse(felt.x * strength, felt.y * strength, felt.z)


## What this tick did, as a pulse at full strength: (weak motor, strong
## motor, seconds); seconds 0 for nothing.
static func felt(world: World, focus: Vector3, side: UnitType.Faction) -> Vector3:
	var strong: float = 0.0
	var weak: float = 0.0
	var seconds: float = 0.0
	for event: ProjectileEvent in world.projectile_events:
		if event.kind != ProjectileEvent.Kind.EXPLODE or event.radius <= 0:
			continue
		var at: Vector3 = Vector3(event.x, event.y, event.z) / float(World.UNITS_PER_METER)
		var near: float = clampf(1.0 - at.distance_to(focus) / BLAST_REACH, 0.0, 1.0)
		var size: float = clampf(event.radius / float(World.UNITS_PER_METER) / BIG_BLAST, 0.2, 1.0)
		strong = maxf(strong, near * size)
		weak = maxf(weak, near * size * 0.6)
		seconds = BLAST_SECONDS
	for event: CombatEvent in world.combat_events:
		if event.kind != CombatEvent.Kind.KILL:
			continue
		var dead: Unit = world.get_unit(event.target_id)
		if dead != null and dead.faction == side:
			weak = maxf(weak, DEATH_WEAK)
			seconds = maxf(seconds, DEATH_SECONDS)
	return Vector3(weak, strong, seconds)


## Vibrates every connected pad that can, at most once per GAP_MSEC.
func pulse(weak: float, strong: float, seconds: float) -> void:
	var now: int = Time.get_ticks_msec()
	if now < _next_msec:
		return
	_next_msec = now + GAP_MSEC
	for device: int in Input.get_connected_joypads():
		if supported(device):
			Input.start_joy_vibration(device, clampf(weak, 0.0, 1.0), clampf(strong, 0.0, 1.0), seconds)
			sent.append([device, weak, strong, seconds])


## True if the pad can rumble here.
static func supported(device: int) -> bool:
	if not Input.has_joy_vibration(device):
		return false
	return not denied(Input.get_joy_info(device), OS.has_feature("macos"))


## True for a pad known not to rumble although its driver may say it does: an
## Xbox One or Series pad on USB, on macOS. `info` is Input.get_joy_info's.
static func denied(info: Dictionary, on_macos: bool) -> bool:
	if not on_macos:
		return false
	var vendor: Variant = info.get("vendor_id")
	var product: Variant = info.get("product_id")
	if not (vendor is int and product is int):
		return false
	return vendor == XBOX_VENDOR and XBOX_USB_PRODUCTS.has(product)


## A line for Settings: whether the connected pads can rumble.
static func status() -> String:
	var pads: Array[int] = Input.get_connected_joypads()
	if pads.is_empty():
		return "No controller connected." + (" (In a browser, press a button on it.)" if OS.has_feature("web") else "")
	for device: int in pads:
		if supported(device):
			return "%s can rumble." % Input.get_joy_name(device)
	for device: int in pads:
		if denied(Input.get_joy_info(device), OS.has_feature("macos")):
			return "Rumble isn't available for this controller on USB here; it works over Bluetooth."
	return "Rumble isn't available for this controller."
