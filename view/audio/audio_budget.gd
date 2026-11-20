class_name AudioBudget
extends RefCounted
## The audio memory arithmetic (spec §4.5). Audio is held to its own cap beside
## the tab's 1,000 MB: what Web decodes (stereo float32 at the browser's rate),
## plus the compressed files held twice, plus a per-play allowance. Pure; view only.

const CAP_MB: int = 270
## Voices that can play at once: 24 SFX and 3 bark.
const PLAY_VOICES: int = 27
## Stereo float32.
const BYTES_PER_FRAME: int = 8


## What a sound of this many seconds weighs once decoded.
static func decoded_bytes(seconds: float, mix_rate: float) -> float:
	return seconds * mix_rate * BYTES_PER_FRAME


## Every play copies its buffer, so: the decoded size of the PLAY_VOICES longest
## variants, as if each voice were playing its longest sound.
static func play_allowance_bytes(lengths: PackedFloat32Array, mix_rate: float) -> float:
	var sorted: PackedFloat32Array = lengths.duplicate()
	sorted.sort()
	var total: float = 0.0
	for i: int in mini(PLAY_VOICES, sorted.size()):
		total += sorted[sorted.size() - 1 - i]
	return total * mix_rate * BYTES_PER_FRAME


## PASS within CAP_MB, FAIL over it.
static func verdict(audio_mb: float) -> String:
	return "PASS" if audio_mb <= CAP_MB else "FAIL"
