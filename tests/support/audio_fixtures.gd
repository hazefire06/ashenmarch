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


## One bark line. `voices` must be set or nothing speaks it; `streams` maps a
## voice id to its voiced stream (none: a text-only line).
static func bark_line(
	id: StringName, unit: StringName, trigger: StringName, text: String,
	voices: Array[StringName], streams: Dictionary = {}, clan: bool = false
) -> BarkLine:
	var line: BarkLine = BarkLine.new()
	line.id = id
	line.unit = unit
	line.trigger = trigger
	line.text = text
	line.clan = clan
	line.voices = voices
	for voice: StringName in streams:
		line.streams[voice] = streams[voice]
	return line


static func bark_book(lines: Array[BarkLine]) -> BarkBook:
	var book: BarkBook = BarkBook.new()
	book.lines = lines
	return book
