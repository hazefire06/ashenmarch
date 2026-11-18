# A2 measurements

Raw `BUDGET` lines from the budget check (`view/budget/budget_run.gd`), plus the Web audio facts that A2's design waited on (spec §4.2–§4.5, §11 step 2). Every run is on this Mac (M4 Max), in Chrome through the chrome-devtools MCP, against `scripts/serve_web.py` (cross-origin isolated, no compression).

## Step 2: Web facts, with synthetic audio (2026-11-10)

The build was `feature/PHASE-A2-audio` at 5ac5430, with the synthetic bank from `make audio-synthetic`:
- every one-shot cue has 3 variants of 3.2 s each (about 518 s);
- every loop is 12 s;
- each music layer is 110 s.

This audio is never committed. The pck was 152.2 MB (A4's was 141.7 MB). Each run was clicked once, so the AudioContext could start.

### With and without audio

- `?budget=1`: `BUDGET tab=586 limit=1000 PASS js_wasm=199 (measured) video=191 textures=168 art=138 types=10 art_load=151 pck=152 wire=152 s3tc=yes ticks=1800 seconds=63 on=web audio=249 audio_cap=270 PASS decoded=195 files=10 play=33 mix=48000 audio_load=397 audio_in_tab=added`
- `?budget=1&audio=0`: `BUDGET tab=384 limit=1000 PASS js_wasm=193 (measured) video=191 textures=168 art=138 types=10 art_load=321 pck=152 wire=152 s3tc=yes ticks=1800 seconds=60 on=web audio=21 audio_cap=270 PASS decoded=0 files=10 play=0 mix=48000 audio_load=1 audio_in_tab=added`

**Chrome doesn't count decoded audio.**
- `js_wasm` rose by 6 MB with audio on (193 to 199). The computed decoded figure is 195 MB.
- So `measureUserAgentSpecificMemory` doesn't see Web Audio's AudioBuffers. `BudgetRun.AUDIO_IN_TAB` stays `false`, and the tab verdict adds the computed decoded figure (spec §4.5).
- Registration did run: `audio_load` is 397 ms with audio on, against 1 ms with it off.
- The browser's mix rate is 48000, the rate spec §4.4 assumed.

### Streams under load

The trace was a devtools performance trace of the `?budget=1` run, at `output_latency.web` = 200. It covered 115 s: load, the 60 s of play, and the measurement.

| Main-thread tasks | Count |
|---|---|
| over 43 ms (the 50 ms setting's buffer) | 6 |
| over 100 ms | 1 |
| over 200 ms | 1 |

**When the long tasks ran:**
- **At load:** the longest task, 259 ms, came at the start of the trace (mission load and registration).
- **During play:** the longest were 57, 55 and 53 ms, all in one 10 s window. Every other 10 s window of play peaked at 12 to 35 ms.
- **After play:** two tasks of 96 and 51 ms came after the run finished, during measurement and trace capture.

**Reading:**
- At 200 ms, no task during play comes near the buffer: the worst is 57 ms, so there's about 3.5 times headroom.
- At 50 ms (43 ms of buffer), the same three tasks would each drop audio for a moment. The long-task pattern doesn't depend on the latency setting, so the 50 ms export wasn't rerun.
- `output_latency.web` stays at 200.

### Tim's listen (2026-11-10)

Tim played a skirmish in Chrome on the same synthetic build, with `output_latency.web` at 200. He reported "sounds fine": no dropouts in the streamed drone or the beds, and the 3D samples pan as the camera orbits.

**Decision:** streaming stands, so the fallback options in spec §4.3.3 aren't needed. `[playback]` in `cues.toml` is unchanged.

## Step 5: the probes (Task 19)

Tim ran both probes in Terminal.app, with the `ashenmarch` key (scoped, quota 100).

**First attempt (2026-11-13). Nothing was charged:**
- **SFX probe:** HTTP 401 `invalid_api_key`, meaning the key value itself was wrong. A missing scope returns `missing_permissions` instead. Tim made a new key.
- **Music probe:** HTTP 422. `wav_32000` isn't an allowed `output_format` for `/v1/music`. This check comes before the key check.
- Both are recorded FAILED, at 0 credits.

**The docs** (elevenlabs.io, through Context7, 2026-11-13):
- `/v1/music` allows only `mp3_*`, `pcm_*`, `opus_48000_*`, `ulaw_8000` and `alaw_8000`, and its `auto` means `mp3_48000_192` for v2 models.
- `/v1/sound-generation` and `/v1/text-to-speech` allow `wav_8000` to `wav_48000`. WAV and PCM at 44.1 kHz and above need Pro.

**The decision:**
- Music buys `mp3_48000_192`, and everything else stays `wav_32000` (commits e5ee2d9, 0653415, 74b654b; security-reviewed).
- `format.txt` was not written.

**Second attempt (2026-11-16), with the new key. Both accepted:**
- `probe/wav_32000`: DONE. The reply passed the WAV check (RIFF header and size).
- `probe/music/mp3_48000_192`: DONE. The reply passed the MP3 check.
- Assumed cost: 40 + 45 = 85 credits.
- Tim's account showed 73,000 credits available after the probes. The spec's 90,000 was from 2026-11-09. A key capped at 100 credits can't account for the gap.
- Still to record: what the usage page shows these two calls cost, and whether in credits or dollars.

## Step 6: Tim's first Riverside listen (2026-11-17)

The build was the worktree at 8518e61 (every cue picked, Riverside's music built), run with `make run` on this Mac. Tim played Riverside at tier 2.

**What he heard, and the causes:**
- **Groans from the first second, too loud over the music.** Groans needed only a seen undead within 40 m of the camera focus. Riverside's `camera_start` (285, 240) m looks at `field_patrol_w`: 7 Husks looping 13 to 27 m from the focus, about 70 m from the deploy at (290, 180). The listener stands at the focus (`UNIT_SIZE` 12), so they played near full level, peak-normalised, over -23 LUFS music on a 70 % bus.
- **Marching all the time.** A headless probe of the first 20 s showed the same 7 Husks moving within 40 m of the focus nearly nonstop (1 to 5 at their turns), with the squad standing still. The march counted every visible mover, so `march_grass` sat at sqrt(7/12) = 0.76.

**Changes:**
- Groans also need a living unit of another side within 20 m (`SfxPlayer.GROAN_NEAR`), commit 6ab6dbe. Tim confirmed the start was quiet afterwards.
- Only living movers march, since the loops are men in boots (a904139).

**Constants, unchanged so far:** `GROAN_RADIUS` 40 m, `GROAN_GAP_TICKS` 90, `GROAN_CHANCE` 0.03, `UNIT_SIZE` 12, `MARCH_RADIUS` 40 m, `MARCH_FULL` 12, the loudness targets (one-shots peak, beds and music -23 LUFS, barks -18 LUFS), and the bus defaults (Music 70 %, Ambient 100 %).

**Still to judge by ear:** the beds against the calm music at a mission's start, now that the groans and marching are gone.

## Step 7: Tim's second Riverside listen (2026-11-17)

The build was the worktree at 9b029d3, then c8e2cca and 53f85c2 after each fix, with `make run` on this Mac at tier 2. Tim confirmed the start was quiet and the beds sat well against the calm music; the bus defaults stay as they are.

**What he heard, and the causes (headless probes, dummy audio):**
- **The march petered out slowly and wasn't tied to the men moving.** In a scripted 30 m move, all 14 started together and the march was at full level in about 1.5 s. But the squad reached its formation spots over about 7 s (14 still moving at 28.5 s, 2 at 31.5 s, none at 36 s), and one straggler walked alone for the last 4.5 s. At sqrt(movers / 12) the last one or two held the march at 0.29 to 0.41 (-11 to -8 dB). The beds' 1.5 a second ease then took about 2.5 s more to silence.
- **Combat music didn't start in combat.** The opening fight is two or three longbows shooting `field_patrol_w` from range, and the patrol died before reaching melee. Counted fighters stayed at 1 to 3 from the first arrow at 13 s, and reached the threshold of 4 only when a sapper joined at 35 s. Combat came in at 37 s. A 6-against-6 melee on a flat field counted 12 on contact, so melee was never the problem.

**Changes:**
- The march level is movers / 12, and the march eases at 4 a second (the beds stay at 1.5), commit c8e2cca. In the same probe it drops to -15 dB within half a second of most men stopping, plays one straggler at -22 dB, and is silent half a second after the last man stops. Tim confirmed the march now stops with the squad.
- `Music.COMBAT_IN_UNITS` went from 4 to 2 (held 1.5 s; going out is unchanged), commit 53f85c2. In the same probe combat comes in at 14.6 s, holds through the lulls in the shooting, and fades 10 s after the last shot. Tim approved it.

## Step 8: the gate's Web budget, with the bought bank (2026-11-17)

Run with `make export-web serve-web` and `?budget=1` in Chrome through the chrome-devtools MCP, on this Mac. Every cue is bought, and the 202 unvoiced bark recordings run as silent stand-ins sized by their text (0.4 s plus 14 characters a second).

| | Mix | Tab (1,000 MB) | Audio (270 MB) | Decoded | Files | Play | Registration |
|---|---|---|---|---|---|---|---|
| 53f85c2 + docs, browser's rate | 48 kHz | 657 PASS | **315 FAIL** | 258 | 8 | 42 | 333 ms |
| `mix_rate.web` = 32000 | 32 kHz | 560 PASS | **215 PASS** | 172 | 8 | 28 | 248 ms |

- **Where the decoded size goes:** 124 SFX files of 163 s (about 62 MB at 48 kHz), and 513 s of bark stand-ins (about 195 MB). The spec estimated 345 s for barks.
- **The lever:** levers 1 and 2 (trims, two variants) are worth about 10 to 25 MB, so getting under 270 MB would have needed lever 3, cutting about 30 of the recordings Tim had just approved. Tim chose the 32 kHz lever instead. Every SFX, loop and voice is bought at 32 kHz, so only the music's band above 16 kHz goes. Chrome honoured the setting (`mix=32000` is read back from the browser).
- **Full lines:**
  - `BUDGET tab=657 limit=1000 PASS js_wasm=195 (measured) video=204 textures=168 art=138 types=10 art_load=100 pck=150 wire=150 s3tc=yes ticks=1800 seconds=60 on=web audio=315 audio_cap=270 FAIL decoded=258 files=8 play=42 mix=48000 audio_load=333 audio_in_tab=added`
  - `BUDGET tab=560 limit=1000 PASS js_wasm=191 (measured) video=197 textures=168 art=138 types=10 art_load=104 pck=150 wire=150 s3tc=yes ticks=1800 seconds=60 on=web audio=215 audio_cap=270 PASS decoded=172 files=8 play=28 mix=32000 audio_load=248 audio_in_tab=added`

## Tooling

Homebrew's ffmpeg has no libvorbis; its native `vorbis` encoder is experimental. Tim installed `vorbis-tools` (`oggenc` 1.4.3) on 2026-11-10, so `process.py` encodes Ogg Vorbis with `oggenc`. The synthetic Oggs above used ffmpeg's native encoder at 96 kbps. Their compressed sizes are therefore only indicative, but the decoded sizes are exact.
