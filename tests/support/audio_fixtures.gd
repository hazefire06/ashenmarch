class_name AudioFixtures
extends RefCounted
## Silent streams and in-memory sound banks, so audio tests pin the cues they
## depend on instead of the shipped bank.


## 16-bit mono zeros, seconds long.
static func silent(seconds: float, rate: int = 8000) -> AudioStreamWAV:
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = rate
	var data: PackedByteArray = PackedByteArray()
	data.resize(int(rate * seconds) * 2)
	wav.data = data
	return wav


## A bank of the given cues: variants maps each id (StringName) to how many
## silent streams it has. Pool tests pass seconds = 5.0 so voices are still
## playing when checked.
static func bank(variants: Dictionary, max_voices: int = 3, seconds: float = 0.2) -> SoundBank:
	var result: SoundBank = SoundBank.new()
	for id: StringName in variants:
		var c: SoundCue = SoundCue.new()
		c.id = id
		c.max_voices = max_voices
		for i: int in int(variants[id]):
			c.streams.append(silent(seconds))
		result.cues.append(c)
	return result
