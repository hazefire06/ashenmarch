"""The audition page: one self-contained HTML file per batch, opened from disk.

Every take has an audio player, its prompt or text, and a tick box. "Save picks" downloads picks-<batch>.json from a Blob.
Everything that comes from outside (prompts, ids, file names, the batch name) is HTML-escaped, and the page loads nothing from
the network. The picks JSON is one of:

    {"batch": B, "cues":   {cue_id: [take, ...]}}            a cue category, the loops, or the music
    {"batch": B, "lines":  {line_id: {voice: take}}}         a unit's spoken lines
    {"batch": B, "design": {voice: n}}                       the previews of a designed voice
"""
from __future__ import annotations

import html
from dataclasses import dataclass


@dataclass(frozen=True)
class Take:
    id: str  # the cue, layer, line or voice this take belongs to
    take: int
    prompt_or_text: str
    file: str  # relative to the page
    voice: str | None  # a line's voice, or the model of an A/B take


def kind_of(batch: str) -> str:
    if batch == "ab":
        return "ab"
    if batch.startswith("voices-"):
        return "lines"
    if batch.startswith("design-"):
        return "design"
    return "cues"


def _e(value: object) -> str:
    return html.escape(str(value), quote=True)


STYLE: str = """
body{font:15px system-ui,sans-serif;margin:24px;background:#faf8f3;color:#1f2a24}
h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:22px 0 6px;border-bottom:1px solid #c9c2b0}
.take{display:flex;align-items:center;gap:12px;padding:4px 0}.take p{margin:0;flex:1;color:#4a554d}
button{font:inherit;padding:6px 14px;margin:10px 0}
"""

SCRIPT: str = """
const body = document.body;
const kind = body.dataset.kind;
function picks() {
  const out = {batch: body.dataset.batch};
  const boxes = [...document.querySelectorAll('input[type=checkbox]:checked')];
  if (kind === 'cues') {
    out.cues = {};
    for (const b of boxes) (out.cues[b.dataset.id] ||= []).push(Number(b.dataset.take));
    for (const id in out.cues) out.cues[id].sort((a, c) => a - c);
  } else if (kind === 'lines') {
    out.lines = {};
    for (const b of boxes) (out.lines[b.dataset.id] ||= {})[b.dataset.voice] = Number(b.dataset.take);
  } else {
    out.design = {};
    for (const b of boxes) out.design[b.dataset.voice] = Number(b.dataset.take);
  }
  return out;
}
document.addEventListener('change', (e) => {
  const box = e.target;
  if (kind === 'cues' || !box.checked) return;
  const key = kind === 'lines' ? box.dataset.id + '/' + box.dataset.voice : box.dataset.voice;
  for (const other of document.querySelectorAll('input[type=checkbox]')) {
    const k = kind === 'lines' ? other.dataset.id + '/' + other.dataset.voice : other.dataset.voice;
    if (other !== box && k === key) other.checked = false;
  }
});
document.getElementById('save').addEventListener('click', () => {
  const blob = new Blob([JSON.stringify(picks(), null, 1) + '\\n'], {type: 'application/json'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = body.dataset.file;
  a.click();
});
"""


def page(batch: str, takes: list[Take]) -> str:
    kind = kind_of(batch)
    groups: dict[str, list[Take]] = {}
    for t in takes:
        groups.setdefault(t.id, []).append(t)
    parts: list[str] = []
    for group_id, members in groups.items():
        parts.append(f"<h2>{_e(group_id)}</h2>")
        for t in members:
            label = f"take {t.take}" + (f" / {t.voice}" if t.voice else "")
            tick = "" if kind == "ab" else (
                f'<input type="checkbox" data-id="{_e(t.id)}" data-take="{_e(t.take)}" data-voice="{_e(t.voice or "")}" '
                f'aria-label="keep {_e(label)}">')
            parts.append(
                f'<div class="take"><audio controls preload="none" src="{_e(t.file)}"></audio>'
                f'{tick}<span>{_e(label)}</span><p>{_e(t.prompt_or_text)}</p></div>')
    save = "" if kind == "ab" else '<button id="save">Save picks</button>'
    script = "" if kind == "ab" else f"<script>{SCRIPT}</script>"
    return (
        "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
        f"<title>Audition: {_e(batch)}</title><style>{STYLE}</style></head>\n"
        f'<body data-kind="{kind}" data-batch="{_e(batch)}" data-file="picks-{_e(batch)}.json">\n<h1>Audition: {_e(batch)}</h1>\n'
        f"<p>{len(takes)} takes. Tick the keepers" + (", then save the picks." if kind != "ab" else ". Say which model you prefer.") + "</p>\n"
        + save + "\n" + "\n".join(parts) + "\n" + script + "\n</body></html>\n")
