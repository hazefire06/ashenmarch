"""World art import: CC0 ground textures and 3D kit models from art-src/world/ into assets/world/, and their rows in assets/LICENSES.md.

    python3 scripts/art/world_assets.py import   # build the files and the licence rows from art-src/world/world.toml
    python3 scripts/art/world_assets.py check    # report whether every listed source exists and is not a symlink; writes nothing

The repo is public, so only CC0 sources from the sites below are accepted. Source packs are untrusted downloads: every path is checked to
sit under art-src/world/ with no symlink on the way, and ffmpeg is given argument lists (no shell) and only the file protocol.
Images are resized and stacked by ffmpeg (no PIL); nothing here uses the network. Everything is validated before anything is written.
"""
from __future__ import annotations

import datetime
import json
import os
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

LAYERS: tuple[str, ...] = ("grass", "brush", "forest", "sand", "rock", "mud")
SITES: dict[str, str] = {"ambientcg": "ambientCG", "polyhaven": "Poly Haven", "quaternius": "Quaternius", "kenney": "Kenney"}
LAYER_SIZE: int = 1024
IMAGE_SUFFIXES: tuple[str, ...] = (".png", ".jpg")  # the types the LFS globs cover; .jpeg would commit as plain git
EXTRA_SUFFIXES: tuple[str, ...] = (".png", ".jpg", ".bin")  # all a .gltf may pull in
MODEL_SUFFIXES: tuple[str, ...] = (".glb", ".gltf")
BEGIN: str = "<!-- world:begin -->"
END: str = "<!-- world:end -->"
SITE_SENTENCE_OLD: str = "Kenney (CC0)"
SITE_SENTENCE_NEW: str = "Kenney, ambientCG, Poly Haven and Quaternius (all CC0)"
TERMS: str = "CC0 1.0"


class WorldError(Exception):
    """A config or source problem. The message is printed and nothing is written."""


@dataclass(frozen=True)
class Source:
    ident: str
    name: str
    url: str
    site: str


@dataclass(frozen=True)
class Layer:
    name: str
    source: Source
    albedo: Path
    normal: Path


@dataclass(frozen=True)
class Model:
    name: str
    source: Source
    file: Path
    extras: tuple[tuple[Path, str], ...]  # (file on disk, path relative to the model's output folder) for a .gltf's buffers and images
    folder: str = ""  # the output folder under assets/world/models/, shared by the models that name it; "" is the model's own name

    @property
    def out_folder(self) -> str:
        return self.folder or self.name

    def shipped(self) -> list[tuple[Path, str]]:
        """(source file, path under assets/world/models/) for every file the model ships."""
        if self.file.suffix.lower() == ".glb":
            return [(self.file, f"{self.name}.glb")]
        return [(self.file, f"{self.out_folder}/{self.file.name}")] + [(src, f"{self.out_folder}/{rel}") for src, rel in self.extras]


@dataclass(frozen=True)
class Plan:
    layers: tuple[Layer, ...]
    models: tuple[Model, ...]


def _text(table: dict[str, object], key: str, where: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value.strip():
        raise WorldError(f"{where}: `{key}` must be a non-empty string")
    return value


def _checked(world: Path, relative: str, where: str) -> Path:
    """The file `relative` names under `world`, or WorldError: absolute paths, `..` out of the folder and any symlink on the way are refused."""
    if "\0" in relative or Path(relative).is_absolute():
        raise WorldError(f"{where}: `{relative}` must be a relative path under art-src/world/")
    current = world
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            raise WorldError(f"{where}: `{relative}` passes through a symlink ({part}); symlinks are refused")
    resolved = (world / relative).resolve()
    if not resolved.is_relative_to(world.resolve()):
        raise WorldError(f"{where}: `{relative}` is outside art-src/world/")
    if not resolved.is_file():
        raise WorldError(f"{where}: `{relative}` doesn't exist under art-src/world/")
    return resolved


def _plain_name(text: str) -> bool:
    return text.isascii() and text.replace("_", "").isalnum()


def _shared_files(models: list[Model]) -> None:
    """WorldError when two models would write different source files to one place (models sharing a folder share files only when they
    are the same file)."""
    seen: dict[str, tuple[Path, str]] = {}
    for model in models:
        for source, dest in model.shipped():
            if dest in seen and seen[dest][0] != source:
                raise WorldError(f"models.{model.name}: `assets/world/models/{dest}` is already written from another file by "
                                 f"models.{seen[dest][1]}; models sharing folder `{model.out_folder}` must share that file")
            seen.setdefault(dest, (source, model.name))


def _look_for_links(root: Path, world: Path) -> None:
    for folder in (root / "art-src", world):
        if folder.is_symlink():
            raise WorldError(f"{folder.relative_to(root)} is a symlink; symlinks are refused")


def _gltf_extras(world: Path, gltf: Path, where: str) -> tuple[tuple[Path, str], ...]:
    try:
        doc = json.loads(gltf.read_text(encoding="utf-8"))
        uris = [str(x["uri"]) for key in ("buffers", "images") for x in doc.get(key, []) if isinstance(x, dict) and "uri" in x]
    except (ValueError, AttributeError, TypeError, OSError):
        raise WorldError(f"{where}: {gltf.name} isn't readable glTF JSON") from None
    extras: list[tuple[Path, str]] = []
    base = gltf.parent.relative_to(world.resolve())
    for uri in uris:
        if uri.startswith("data:"):
            continue
        rel = unquote(uri)
        if Path(rel).is_absolute() or ".." in Path(rel).parts or "\\" in rel:
            raise WorldError(f"{where}: {gltf.name} uri `{rel}` must stay inside the model's folder (no `..`, no absolute path)")
        if Path(rel).suffix.lower() not in EXTRA_SUFFIXES:
            raise WorldError(f"{where}: {gltf.name} uri `{rel}` isn't a .png, .jpg or .bin")
        extras.append((_checked(world, str(base / rel), f"{where} ({gltf.name} uri)"), rel))
    return tuple(extras)


def load_plan(root: Path) -> tuple[Plan, Path]:
    world = root / "art-src" / "world"
    _look_for_links(root, world)
    config = world / "world.toml"
    if not config.is_file() or config.is_symlink():
        raise WorldError("art-src/world/world.toml is missing")
    try:
        data = tomllib.loads(config.read_text(encoding="utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as err:
        raise WorldError(f"world.toml: {err}") from None
    sources: dict[str, Source] = {}
    raw_sources = data.get("source", {})
    for ident, table in (raw_sources.items() if isinstance(raw_sources, dict) else []):
        where = f"source.{ident}"
        if not isinstance(table, dict):
            raise WorldError(f"{where}: must be a table")
        if table.get("licence") != "CC0":
            raise WorldError(f'{where}: licence must be "CC0" (the repo is public), not {table.get("licence")!r}')
        site = table.get("site")
        if site not in SITES:
            raise WorldError(f"{where}: site must be one of {', '.join(SITES)}, not {site!r}")
        sources[ident] = Source(ident, _text(table, "name", where), _text(table, "url", where), str(site))

    def source_of(table: dict[str, object], where: str) -> Source:
        ident = _text(table, "source", where)
        if ident not in sources:
            raise WorldError(f"{where}: source `{ident}` is not listed under [source.*]")
        return sources[ident]

    ground = data.get("ground", {})
    ground = ground if isinstance(ground, dict) else {}
    layers: list[Layer] = []
    for name in LAYERS:
        table = ground.get(name)
        if not isinstance(table, dict):
            raise WorldError(f"ground.{name}: the layer is missing from world.toml (layers are {', '.join(LAYERS)})")
        where = f"ground.{name}"
        paths = [_checked(world, _text(table, key, where), f"{where}.{key}") for key in ("albedo", "normal")]
        for path in paths:
            if path.suffix.lower() not in IMAGE_SUFFIXES:
                raise WorldError(f"{where}: {path.name} isn't a .png or .jpg")
        layers.append(Layer(name, source_of(table, where), paths[0], paths[1]))
    unknown = sorted(set(ground) - set(LAYERS))
    if unknown:
        raise WorldError(f"ground.{unknown[0]}: not a layer ({', '.join(LAYERS)})")

    models: list[Model] = []
    raw_models = data.get("models", {})
    for name, table in (raw_models.items() if isinstance(raw_models, dict) else []):
        where = f"models.{name}"
        if not isinstance(table, dict) or not _plain_name(name):
            raise WorldError(f"{where}: the name must be letters, digits and underscores, with a table of source and file")
        path = _checked(world, _text(table, "file", where), where)
        if path.suffix.lower() not in MODEL_SUFFIXES:
            raise WorldError(f"{where}: {path.name} isn't a .glb or .gltf")
        folder = ""
        if "folder" in table:
            folder = _text(table, "folder", where)
            if not _plain_name(folder):
                raise WorldError(f"{where}: folder `{folder}` must be letters, digits and underscores")
            if path.suffix.lower() != ".gltf":
                raise WorldError(f"{where}: a folder is only for .gltf models ({path.name} is not one)")
        extras = _gltf_extras(world, path, where) if path.suffix.lower() == ".gltf" else ()
        models.append(Model(name, source_of(table, where), path, extras, folder))
    _shared_files(models)
    return Plan(tuple(layers), tuple(models)), world


def _ffmpeg_strip(paths: list[Path], dest: Path) -> None:
    """The six images, each lanczos-resized to LAYER_SIZE square, stacked top to bottom into one PNG at `dest` (written as .part, then renamed)."""
    if shutil.which("ffmpeg") is None:
        raise WorldError("ffmpeg not found (brew install ffmpeg)")
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    for path in paths:
        cmd += ["-protocol_whitelist", "file", "-f", "image2", "-i", str(path)]
    chains = "".join(f"[{i}:v]scale={LAYER_SIZE}:{LAYER_SIZE}:flags=lanczos,format=rgb24[v{i}];" for i in range(len(paths)))
    stack = "".join(f"[v{i}]" for i in range(len(paths))) + f"vstack=inputs={len(paths)}"
    part = dest.with_name(dest.name + ".part")
    cmd += ["-filter_complex", chains + stack, "-frames:v", "1", "-f", "image2", "-c:v", "png", str(part)]
    try:
        done = subprocess.run(cmd, capture_output=True, check=False)
        if done.returncode != 0:
            tail = done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:]
            raise WorldError(f"ffmpeg failed building {dest.name}: {tail[0][:120] if tail else 'no message'}")
        os.replace(part, dest)
    except OSError as err:
        raise WorldError(f"{dest.name}: {err.strerror}") from None
    finally:
        part.unlink(missing_ok=True)


# The ground strips' settings, every key in the order Godot writes them back (the 2d_array importer has no normal_map key: Godot would
# drop it, and the next run would differ from the committed file).
ARRAY_IMPORTER: tuple[str, str] = ("2d_array_texture", "CompressedTexture2DArray")
ARRAY_PARAMS: dict[str, str] = {
    "compress/mode": "2", "compress/high_quality": "false", "compress/lossy_quality": "0.7", "compress/uastc_level": "0",
    "compress/rdo_quality_loss": "0.0", "compress/hdr_compression": "1", "compress/channel_pack": "0", "mipmaps/generate": "true",
    "mipmaps/limit": "-1", "slices/horizontal": "1", "slices/vertical": str(len(LAYERS)),
}
# A model's images: VRAM compressed with mipmaps, decided here rather than by Godot's detect-3D guess (whose default is lossless, about
# 4 MB of video memory per 1K image, and no mipmaps). Godot fills in the importer's other keys.
IMAGE_IMPORTER: tuple[str, str] = ("texture", "CompressedTexture2D")
IMAGE_PARAMS: dict[str, str] = {"compress/mode": "2", "mipmaps/generate": "true", "detect_3d/compress_to": "0"}


def import_settings(existing: str | None, importer: tuple[str, str], params: dict[str, str]) -> str:
    """The .import file to write. An existing one for the same importer is kept as Godot wrote it (its uid, imported paths and
    dependencies) with only `params` set in its [params] section, so a re-run changes nothing; otherwise a fresh file, keeping any uid,
    which Godot completes on its next import."""
    if existing is not None:
        lines = existing.splitlines()
        head = existing.split("[deps]")[0]
        if f'importer="{importer[0]}"' in head and "[params]" in lines:
            start = lines.index("[params]") + 1
            body = lines[start:]
            where = {line.split("=", 1)[0]: n for n, line in enumerate(body) if "=" in line}
            for key, value in params.items():
                if key in where:
                    body[where[key]] = f"{key}={value}"
                else:
                    body.append(f"{key}={value}")
            return "\n".join(lines[:start] + body) + "\n"
    uid = [line for line in (existing or "").splitlines() if line.startswith("uid=")][:1]
    remap = [f'importer="{importer[0]}"', f'type="{importer[1]}"'] + uid
    return "[remap]\n\n" + "\n".join(remap) + "\n\n[params]\n\n" + "".join(f"{k}={v}\n" for k, v in params.items())


def _write_import(dest: Path, importer: tuple[str, str], params: dict[str, str]) -> None:
    """Writes dest's import settings, only when they change."""
    if dest.is_symlink():
        raise WorldError(f"{dest.name} is a symlink; symlinks are refused")
    existing = dest.read_text(encoding="utf-8") if dest.is_file() else None
    text = import_settings(existing, importer, params)
    if text != existing:
        _write(dest, text)


def _write(dest: Path, data: str | bytes) -> None:
    part = dest.with_name(dest.name + ".part")
    try:
        if isinstance(data, str):
            part.write_text(data, encoding="utf-8")
        else:
            part.write_bytes(data)
        os.replace(part, dest)
    finally:
        part.unlink(missing_ok=True)


def _copy(source: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    try:
        shutil.copyfile(source, part)
        os.replace(part, dest)
    finally:
        part.unlink(missing_ok=True)


def _site_name(source: Source) -> str:
    return f"{SITES[source.site]} ({source.name})"


def _date(path: Path) -> str:
    return datetime.datetime.fromtimestamp(path.stat().st_mtime, datetime.timezone.utc).strftime("%Y-%m-%d")


def _cell(text: str) -> str:
    return text.replace("|", "/").replace("\n", " ")


def licence_rows(plan: Plan) -> list[str]:
    """One row per shipped file (the import files share one row, as the art and audio rows do)."""
    rows: list[str] = []
    for kind, pick in (("albedo", lambda x: x.albedo), ("normal", lambda x: x.normal)):
        sources = sorted({_site_name(x.source) for x in plan.layers})
        made = "; ".join(f"{x.name}: {x.source.name} ({x.source.url}) {pick(x).name}" for x in plan.layers)
        rows.append(f"| `assets/world/textures/ground_{kind}.png` | {_cell(', '.join(sources))} | {TERMS} | "
                    f"{max(_date(pick(x)) for x in plan.layers)} | {_cell(f'Six {kind} layers resized to {LAYER_SIZE} px and stacked by scripts/art/world_assets.py; {made}')} |")
    newest = max([_date(x.albedo) for x in plan.layers] + [_date(x.file) for x in plan.models])
    rows.append(f"| `assets/world/**/*.import` | Generated by `scripts/art/world_assets.py` | Ours | {newest} | Godot import settings for the ground textures and model images above |")
    # One row per file: a file models share in their folder names every model that uses it.
    users: dict[str, list[Model]] = {}
    for model in sorted(plan.models, key=lambda m: m.name):
        for _, dest in model.shipped():
            users.setdefault(dest, []).append(model)
    for dest, models in sorted(users.items(), key=lambda x: x[1][0].name):  # stable: a model's files stay in shipped() order
        first = models[0]
        names = ", ".join(m.name for m in models)
        what = f"Model `{names}`" if len(models) == 1 else f"Shared by models {names}"
        rows.append(f"| `assets/world/models/{dest}` | {_cell(_site_name(first.source))} | {TERMS} | {_date(first.file)} | "
                    f"{what} from {_cell(first.source.name)} ({_cell(first.source.url)}), copied unchanged by scripts/art/world_assets.py |")
    return rows


def update_licences(text: str, rows: list[str]) -> str:
    """Replaces what lies between the world markers (adding them at the end if missing) and names the world sites in the allowed-sources
    sentence. Everything else, the audio section included, is returned byte for byte."""
    if SITE_SENTENCE_OLD in text and "ambientCG" not in text.split("| File |")[0]:
        text = text.replace(SITE_SENTENCE_OLD, SITE_SENTENCE_NEW, 1)
    block = (f"{BEGIN}\n\nGenerated by `scripts/art/world_assets.py import`; edit nothing between these markers.\n\n"
             "| File | Source | Terms | Date | Made from |\n|---|---|---|---|---|\n" + "\n".join(rows) + f"\n\n{END}")
    if BEGIN not in text and END not in text:
        return text + ("" if text.endswith("\n") else "\n") + "\n" + block + "\n"
    first, last = text.find(BEGIN), text.find(END)
    if first < 0 or last < first or text.count(BEGIN) != 1 or text.count(END) != 1:
        raise WorldError(f"LICENSES.md: the markers {BEGIN} and {END} must each appear once, begin first")
    return text[:first] + block + text[last + len(END):]


def _out_dir(root: Path, *parts: str) -> Path:
    folder = root
    for part in ("assets", "world", *parts):
        folder = folder / part
        if folder.is_symlink():
            raise WorldError(f"{folder.relative_to(root)} is a symlink; symlinks are refused")
    return folder


def run_import(root: Path) -> None:
    plan, _ = load_plan(root)
    licences = root / "assets" / "LICENSES.md"
    if licences.is_symlink() or not licences.is_file():
        raise WorldError("assets/LICENSES.md is missing or a symlink")
    new_text = update_licences(licences.read_text(encoding="utf-8"), licence_rows(plan))  # validated before any file is written
    textures, models = _out_dir(root, "textures"), _out_dir(root, "models")
    textures.mkdir(parents=True, exist_ok=True)
    _ffmpeg_strip([x.albedo for x in plan.layers], textures / "ground_albedo.png")
    _ffmpeg_strip([x.normal for x in plan.layers], textures / "ground_normal.png")
    for name in ("ground_albedo.png", "ground_normal.png"):
        _write_import(textures / f"{name}.import", ARRAY_IMPORTER, ARRAY_PARAMS)
    for model in plan.models:
        if model.file.suffix.lower() == ".glb":
            _copy(model.file, models / f"{model.name}.glb")
        else:
            folder = models / model.out_folder
            if (folder / model.file.name).is_symlink() or folder.is_symlink():
                raise WorldError(f"assets/world/models/{model.out_folder} is a symlink; symlinks are refused")
            _copy(model.file, folder / model.file.name)
            for source, rel in model.extras:
                target = (folder / rel).resolve()
                if not target.is_relative_to(folder.resolve()):
                    raise WorldError(f"assets/world/models/{model.out_folder}: `{rel}` would be written outside the model's folder")
                _copy(source, target)
                if target.suffix.lower() in IMAGE_SUFFIXES:
                    _write_import(target.with_name(target.name + ".import"), IMAGE_IMPORTER, IMAGE_PARAMS)
    _write(licences, new_text)


def run_check(root: Path) -> list[str]:
    """What is wrong with the listed sources, one line each; empty when all are present."""
    try:
        load_plan(root)
    except WorldError as err:
        return [str(err)]
    return []


def main(argv: list[str], root: Path | None = None) -> int:
    root = (root or Path(__file__).resolve().parents[2]).resolve()
    if len(argv) != 1 or argv[0] not in ("import", "check"):
        print("usage: world_assets.py import | check", file=sys.stderr)
        return 2
    try:
        if argv[0] == "import":
            run_import(root)
            print("world assets imported")
        else:
            problems = run_check(root)
            if problems:
                raise WorldError("\n".join(problems))
            print("ok: every listed world source exists and is not a symlink")
    except WorldError as err:
        print(f"world_assets: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
