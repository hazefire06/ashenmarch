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

## Tooling

Homebrew's ffmpeg has no libvorbis; its native `vorbis` encoder is experimental. Tim installed `vorbis-tools` (`oggenc` 1.4.3) on 2026-11-10, so `process.py` encodes Ogg Vorbis with `oggenc`. The synthetic Oggs above used ffmpeg's native encoder at 96 kbps. Their compressed sizes are therefore only indicative, but the decoded sizes are exact.
