class_name BarkLine
extends Resource
## One spoken line: its text (shown over the speaker, so barks work before any
## voice is bought) and the voiced stream of each voice that has one. View only.

## Seconds a line shows before its length is known, per 14 characters.
const CHARS_PER_SECOND: float = 14.0
const LEAD_SECONDS: float = 0.4

@export var id: StringName
## The unit type that says it, or &"_clan" for a clan-wide line.
@export var unit: StringName
## &"" for a clan line, which can replace any trigger.
@export var trigger: StringName
@export var text: String = ""
@export var clan: bool = false
## Voice id to its voiced stream. A voice with no entry is unvoiced.
@export var streams: Dictionary[StringName, AudioStream] = {}


## How long a line's text takes to say, for the floating text and the stand-ins.
static func estimate_seconds(line_text: String) -> float:
	return LEAD_SECONDS + line_text.length() / CHARS_PER_SECOND


## The voiced stream's length, else the text's estimate.
func seconds(voice: StringName) -> float:
	var stream: AudioStream = streams.get(voice)
	return stream.get_length() if stream != null else estimate_seconds(text)
