"""Assembles the world kit's structures (houses, a wall section, a gatehouse, the mill) from Quaternius Medieval Village MegaKit pieces.

    python3 -I scripts/art/assemble_world_kit.py KIT_GLTF_DIR OUT_DIR

The MegaKit (CC0) is modular: 2 m wall modules, roofs and gables, no whole buildings. Each recipe below places pieces and merges them into
one glTF with one mesh, one primitive per material, so a structure is a handful of draw calls. Materials keep only what the game's model
shader reads, the base colour texture and factor; the kit's normal, roughness and ORM maps are dropped, and the base colour maps it uses
are resized to 1024 px JPGs beside the models (OUT_DIR). The pack is an untrusted download: this reads its glTF JSON and .bin buffers as
data, refuses uris that leave KIT_GLTF_DIR, and runs nothing from it. ffmpeg gets argument lists and only the file protocol.

Native axes: x across, y up, z the door's axis (+z), one unit a metre. world_assets.py imports OUT_DIR's files; build_world_kit.gd
re-centres them and writes data/world/kit.tres.
"""
from __future__ import annotations

import json
import math
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

Matrix = tuple[tuple[float, ...], ...]  # 4x4, row-major
TEXTURE_SIZE: int = 1024
OPAQUE: str = "OPAQUE"
# The house roofs are squashed to this share of their height, so the eaves sit about two thirds of the way up, as the maps assume.
HOUSE_ROOF_Y: float = 0.4
# How far a roof reaches past its corner posts, metres. The placer fits the roof's bounds to the footprint, so this is about how far
# inside the footprint the walls stand: it must stay well under the spec's 0.5 m.
EAVES_M: float = 0.25
# Corner_Exterior_Wood's half width: the posts are the outermost part of a building's walls.
POST_M: float = 0.11
# How far a Roof_Front_* gable's beams reach out (+z) from its wall.
GABLE_REACH_M: float = 0.79
# Each roof's half span in x and its z extent (from the kit's glTF bounds).
ROOF_SPANS: dict[str, tuple[float, float, float]] = {
    "Roof_RoundTiles_6x6": (4.12, -3.94, 4.09),
    "Roof_RoundTiles_6x8": (4.12, -4.83, 4.85),
    "Roof_RoundTiles_4x6": (2.76, -3.79, 3.79),
    "Roof_RoundTiles_4x8": (2.76, -4.83, 4.85),
    "Roof_RoundTiles_8x8": (4.98, -5.08, 5.25),
}


def _mul(a: Matrix, b: Matrix) -> Matrix:
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)) for i in range(4))


def chain(*ms: Matrix) -> Matrix:
    out: Matrix = IDENTITY
    for m in ms:
        out = _mul(out, m)
    return out


IDENTITY: Matrix = ((1.0, 0.0, 0.0, 0.0), (0.0, 1.0, 0.0, 0.0), (0.0, 0.0, 1.0, 0.0), (0.0, 0.0, 0.0, 1.0))


def move(x: float, y: float, z: float) -> Matrix:
    return ((1.0, 0.0, 0.0, x), (0.0, 1.0, 0.0, y), (0.0, 0.0, 1.0, z), (0.0, 0.0, 0.0, 1.0))


def scale(x: float, y: float, z: float) -> Matrix:
    return ((x, 0.0, 0.0, 0.0), (0.0, y, 0.0, 0.0), (0.0, 0.0, z, 0.0), (0.0, 0.0, 0.0, 1.0))


def yaw(degrees: float) -> Matrix:
    """About +y; yaw(90) turns +z (a wall module's outside) to +x."""
    c, s = round(math.cos(math.radians(degrees)), 12), round(math.sin(math.radians(degrees)), 12)
    return ((c, 0.0, s, 0.0), (0.0, 1.0, 0.0, 0.0), (-s, 0.0, c, 0.0), (0.0, 0.0, 0.0, 1.0))


def pitch(degrees: float) -> Matrix:
    """About +x; pitch(-90) stands a floor tile (in xz) up in the xy plane."""
    c, s = round(math.cos(math.radians(degrees)), 12), round(math.sin(math.radians(degrees)), 12)
    return ((1.0, 0.0, 0.0, 0.0), (0.0, c, -s, 0.0), (0.0, s, c, 0.0), (0.0, 0.0, 0.0, 1.0))


def roll(degrees: float) -> Matrix:
    """About +z."""
    c, s = round(math.cos(math.radians(degrees)), 12), round(math.sin(math.radians(degrees)), 12)
    return ((c, -s, 0.0, 0.0), (s, c, 0.0, 0.0), (0.0, 0.0, 1.0, 0.0), (0.0, 0.0, 0.0, 1.0))


Placement = tuple[str, Matrix]


@dataclass(frozen=True)
class Look:
    """The pieces a building's walls are made of."""
    straight: str
    door: str
    window: str


PLASTER: Look = Look("Wall_Plaster_Straight", "Wall_Plaster_Door_Flat", "Wall_Plaster_Window_Wide_Flat")
TIMBER: Look = Look("Wall_Plaster_WoodGrid", "Wall_Plaster_Door_Flat", "Wall_Plaster_Window_Wide_Flat")
STONE: Look = Look("Wall_UnevenBrick_Straight", "Wall_UnevenBrick_Door_Flat", "Wall_UnevenBrick_Window_Wide_Flat")


def _side(look: Look, at: Matrix, modules: int, door: bool) -> list[Placement]:
    """One side of a building: `modules` 2 m modules along x, outside facing +z, in the frame `at`. A door side has its door in the
    middle module (left of middle for an even count); the other modules alternate window and plain wall from the corners."""
    placed: list[Placement] = []
    middle = (modules - 1) // 2
    for n in range(modules):
        here = chain(at, move(-modules + 1.0 + 2.0 * n, 0.0, 0.0))
        if door and n == middle:
            placed += [(look.door, here), ("DoorFrame_Flat_WoodDark", here), ("Door_2_Flat", chain(here, move(-0.535, 0.0, -0.08)))]
        elif n % 2 == 0:
            placed += [(look.window, here), ("WindowShutters_Wide_Flat_Closed", here)]
        else:
            placed.append((look.straight, here))
    return placed


def building(look: Look, wide: int, deep: int, door: str, roof: str, gable: str, roof_y: float, body: float = 1.0,
             overhang: float = EAVES_M, gable_y: float = 1.0) -> list[Placement]:
    """Walls of `wide` x `deep` 2 m modules (x by z), stretched by `body` in x and z, with corner posts, a gabled roof (ridge along z,
    gables front and back) squashed to roof_y of its height, and a door on the `door` side ("front" is +z, a gable end; "side" is +x,
    under the eaves). The roof is fitted in x and z to reach `overhang` past the corner posts and no further: the placer scales the
    whole bounds, the roof's, to the footprint, so a wide overhang would leave the walls standing well inside it."""
    hx, hz = float(wide), float(deep)
    sides = [
        (move(0.0, 0.0, hz), wide, door == "front"),
        (chain(move(0.0, 0.0, -hz), yaw(180)), wide, False),
        (chain(move(hx, 0.0, 0.0), yaw(90)), deep, door == "side"),
        (chain(move(-hx, 0.0, 0.0), yaw(-90)), deep, False),
    ]
    walls: list[Placement] = []
    for at, modules, has_door in sides:
        walls += _side(look, at, modules, has_door)
    walls += [("Corner_Exterior_Wood", move(x, 0.0, z)) for x in (-hx, hx) for z in (-hz, hz)]
    stretch = scale(body, 1.0, body)
    placed: list[Placement] = [(piece, chain(stretch, m)) for piece, m in walls]
    # The roof spans the corner posts' outsides plus the overhang, in both x and z.
    half_x, half_z = (hx + POST_M) * body + overhang, (hz + POST_M) * body + overhang
    span_x, z0, z1 = ROOF_SPANS[roof]
    fit = chain(scale(half_x / span_x, 1.0, 2.0 * half_z / (z1 - z0)), move(0.0, 0.0, -(z0 + z1) / 2.0))
    top = chain(move(0.0, 3.0, 0.0), scale(1.0, roof_y, 1.0))
    placed.append((roof, chain(top, fit)))
    # The gable front's beams reach GABLE_REACH_M out from the wall; pressed in to stay under the roof's end.
    gable_fit = scale(body, gable_y, min(1.0, (POST_M * body + overhang) / GABLE_REACH_M))
    placed += [(gable, chain(top, move(0.0, 0.0, hz * body), gable_fit)),
               (gable, chain(top, move(0.0, 0.0, -hz * body), yaw(180), gable_fit))]
    return placed


def wall_section() -> list[Placement]:
    """A 2 m run of stone wall, 2 m thick: a module facing out each side and a stone top between them. Runs along x."""
    return [("Wall_UnevenBrick_Straight", move(0.0, 0.0, 0.91)), ("Wall_UnevenBrick_Straight", chain(move(0.0, 0.0, -0.91), yaw(180))),
            ("Floor_UnevenBrick", move(0.0, 3.0, 0.0))]


def gatehouse() -> list[Placement]:
    """A 6 m gate across a 2 m thick wall, open underneath: stone ends facing into the opening (they close the wall's ends) and a timber
    bridge over the top, posts laid as lintels front and back and planks between."""
    return [("Wall_UnevenBrick_Straight", chain(move(-2.69, 0.0, 0.0), yaw(90))),
            ("Wall_UnevenBrick_Straight", chain(move(2.69, 0.0, 0.0), yaw(-90))),
            ("Corner_Exterior_Wood", chain(move(-2.6, 2.95, 0.88), roll(-90), scale(1.0, 5.2 / 3.0, 1.0))),
            ("Corner_Exterior_Wood", chain(move(-2.6, 2.95, -0.88), roll(-90), scale(1.0, 5.2 / 3.0, 1.0))),
            ("Floor_WoodDark", chain(move(0.0, 3.06, 0.0), scale(2.69, 1.0, 1.0)))]


def mill() -> list[Placement]:
    """The Old Mill: 4 x 4 modules of stone wall stretched 1.16 (9.3 m; the shutters then reach 5.0) under the kit's 8 x 8 roof fitted to exactly 10 x 10 m and
    squashed to 6 m tall, with four sails crossed on the front gable above the door."""
    body = 1.16
    # The 8-wide gable is 5.31 tall under a 6.00 roof; stretched to meet it.
    placed = building(STONE, 4, 4, "front", "Roof_RoundTiles_8x8", "Roof_Front_Brick8", 0.5, body, 5.0 - (4.0 + POST_M) * body,
                      6.0 / 5.31)
    hub = move(0.0, 4.05, 4.8)
    placed.append(("Prop_Crate", chain(hub, scale(0.35, 0.35, 0.35), move(0.0, -0.53, 0.0))))
    for angle in (45.0, 135.0, 225.0, 315.0):
        # A blade: a light plank tile stood up in the xy plane, 0.6 m wide and 2.3 m long, out from the hub.
        placed.append(("Floor_WoodLight", chain(hub, roll(angle), move(0.0, 1.3, 0.1), pitch(-90), scale(0.3, 1.0, 1.15))))
    return placed


RECIPES: dict[str, list[Placement]] = {
    "house_square": building(PLASTER, 3, 3, "front", "Roof_RoundTiles_6x6", "Roof_Front_Brick6", HOUSE_ROOF_Y),
    "house_long_side": building(TIMBER, 3, 4, "side", "Roof_RoundTiles_6x8", "Roof_Front_Brick6", HOUSE_ROOF_Y),
    "house_long_front": building(STONE, 3, 4, "front", "Roof_RoundTiles_6x8", "Roof_Front_Brick6", HOUSE_ROOF_Y),
    "house_narrow_side": building(PLASTER, 2, 3, "side", "Roof_RoundTiles_4x6", "Roof_Front_Brick4", HOUSE_ROOF_Y),
    "house_narrow_front": building(STONE, 2, 4, "front", "Roof_RoundTiles_4x8", "Roof_Front_Brick4", HOUSE_ROOF_Y),
    "wall": wall_section(),
    "gate": gatehouse(),
    "mill": mill(),
}


class KitError(Exception):
    pass


@dataclass
class Group:
    """Merged triangles for one material."""
    material: dict[str, object]
    image: str | None
    positions: list[tuple[float, float, float]] = field(default_factory=list)
    normals: list[tuple[float, float, float]] = field(default_factory=list)
    uvs: list[tuple[float, float]] = field(default_factory=list)
    indices: list[int] = field(default_factory=list)


COMPONENTS: dict[int, tuple[str, int]] = {5126: ("f", 4), 5125: ("I", 4), 5123: ("H", 2), 5121: ("B", 1)}
WIDTHS: dict[str, int] = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def _read_accessor(doc: dict, buffers: list[bytes], index: int) -> list[tuple]:
    acc = doc["accessors"][index]
    view = doc["bufferViews"][acc["bufferView"]]
    fmt, size = COMPONENTS[acc["componentType"]]
    width = WIDTHS[acc["type"]]
    stride = view.get("byteStride", size * width)
    data = buffers[view["buffer"]]
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return [struct.unpack_from(f"<{width}{fmt}", data, start + n * stride) for n in range(acc["count"])]


def _load(kit: Path, name: str) -> tuple[dict, list[bytes]]:
    path = kit / f"{name}.gltf"
    doc = json.loads(path.read_text(encoding="utf-8"))
    buffers: list[bytes] = []
    for buf in doc["buffers"]:
        uri = buf["uri"]
        target = (kit / uri).resolve()
        if uri.startswith("data:") or not target.is_relative_to(kit.resolve()) or target.suffix != ".bin" or target.is_symlink():
            raise KitError(f"{name}: buffer uri {uri!r} must be a .bin beside it")
        buffers.append(target.read_bytes())
    return doc, buffers


def _transform(m: Matrix, p: tuple) -> tuple[float, float, float]:
    return tuple(m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] + m[i][3] for i in range(3))  # type: ignore[return-value]


def _normal_matrix(m: Matrix) -> list[list[float]]:
    """The inverse transpose of m's 3x3 part."""
    a = [[m[i][j] for j in range(3)] for i in range(3)]
    det = (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
           + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    if det <= 0.0:
        raise KitError("placements must not mirror (determinant <= 0): it would flip the triangles' winding")
    cof = [[(a[(i + 1) % 3][(j + 1) % 3] * a[(i + 2) % 3][(j + 2) % 3] - a[(i + 1) % 3][(j + 2) % 3] * a[(i + 2) % 3][(j + 1) % 3])
            for j in range(3)] for i in range(3)]
    return [[cof[i][j] / det for j in range(3)] for i in range(3)]  # cofactor / det = inverse transpose


def assemble(kit: Path, placements: list[Placement], groups: dict[str, Group]) -> None:
    for piece, m in placements:
        doc, buffers = _load(kit, piece)
        nm = _normal_matrix(m)
        mesh = doc["meshes"][doc["nodes"][doc["scenes"][doc.get("scene", 0)]["nodes"][0]]["mesh"]]
        if len(doc["nodes"]) != 1 or any(k in doc["nodes"][0] for k in ("translation", "rotation", "scale", "matrix")):
            raise KitError(f"{piece}: expected one untransformed node")
        for prim in mesh["primitives"]:
            if prim.get("mode", 4) != 4:
                raise KitError(f"{piece}: only triangle lists are supported")
            source = doc["materials"][prim["material"]]
            if source.get("alphaMode", OPAQUE) != OPAQUE:
                raise KitError(f"{piece}: material {source['name']} is {source['alphaMode']}; the model shader is opaque only")
            pbr = source.get("pbrMetallicRoughness", {})
            colour = pbr.get("baseColorTexture")
            image = Path(doc["images"][doc["textures"][colour["index"]]["source"]]["uri"]).stem if colour else None
            uv_set = colour.get("texCoord", 0) if colour else 0
            if colour and "extensions" in colour:
                raise KitError(f"{piece}: texture transforms are not supported")
            key = source["name"]
            group = groups.setdefault(key, Group({"name": key, "factor": pbr.get("baseColorFactor")}, image))
            if group.image != image:
                raise KitError(f"material {key} uses {image} in {piece} but {group.image} elsewhere")
            attrs = prim["attributes"]
            base = len(group.positions)
            group.positions += [_transform(m, p) for p in _read_accessor(doc, buffers, attrs["POSITION"])]
            for n in _read_accessor(doc, buffers, attrs["NORMAL"]):
                v = [nm[i][0] * n[0] + nm[i][1] * n[1] + nm[i][2] * n[2] for i in range(3)]
                length = math.sqrt(sum(c * c for c in v)) or 1.0
                group.normals.append((v[0] / length, v[1] / length, v[2] / length))
            group.uvs += [(u[0], u[1]) for u in _read_accessor(doc, buffers, attrs[f"TEXCOORD_{uv_set}"])]
            group.indices += [base + i[0] for i in _read_accessor(doc, buffers, prim["indices"])]


def write_gltf(name: str, groups: dict[str, Group], out: Path) -> None:
    blob = bytearray()
    views: list[dict] = []
    accessors: list[dict] = []

    def add(values: list, fmt: str, width: int, kind: str, component: int, target: int, bounds: bool = False) -> int:
        while len(blob) % 4:
            blob.append(0)
        offset = len(blob)
        for v in values:
            blob.extend(struct.pack(f"<{width}{fmt}", *(v if width > 1 else (v,))))
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(blob) - offset, "target": target})
        acc: dict[str, object] = {"bufferView": len(views) - 1, "componentType": component, "count": len(values), "type": kind}
        if bounds:
            acc["min"] = [min(v[i] for v in values) for i in range(width)]
            acc["max"] = [max(v[i] for v in values) for i in range(width)]
        accessors.append(acc)
        return len(accessors) - 1

    images: list[str] = sorted({g.image for g in groups.values() if g.image})
    materials: list[dict] = []
    primitives: list[dict] = []
    for key in sorted(groups):
        g = groups[key]
        pbr: dict[str, object] = {"metallicFactor": 0.0, "roughnessFactor": 1.0}
        if g.image:
            pbr["baseColorTexture"] = {"index": images.index(g.image)}
        if g.material["factor"] is not None:
            pbr["baseColorFactor"] = g.material["factor"]
        materials.append({"name": key, "pbrMetallicRoughness": pbr})
        primitives.append({"attributes": {"POSITION": add(g.positions, "f", 3, "VEC3", 5126, 34962, True),
                                          "NORMAL": add(g.normals, "f", 3, "VEC3", 5126, 34962),
                                          "TEXCOORD_0": add(g.uvs, "f", 2, "VEC2", 5126, 34962)},
                           "indices": add(g.indices, "I", 1, "SCALAR", 5125, 34963), "material": len(materials) - 1})
    doc = {
        "asset": {"version": "2.0", "generator": "ashenmarch scripts/art/assemble_world_kit.py (Quaternius Medieval Village MegaKit, CC0)"},
        "scene": 0, "scenes": [{"name": name, "nodes": [0]}], "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"name": name, "primitives": primitives}], "materials": materials,
        "samplers": [{"magFilter": 9729, "minFilter": 9987}],
        "textures": [{"sampler": 0, "source": n} for n in range(len(images))],
        "images": [{"name": image, "uri": f"{image}.jpg", "mimeType": "image/jpeg"} for image in images],
        "accessors": accessors, "bufferViews": views, "buffers": [{"uri": f"{name}.bin", "byteLength": len(blob)}],
    }
    (out / f"{name}.bin").write_bytes(bytes(blob))
    (out / f"{name}.gltf").write_text(json.dumps(doc, indent=1) + "\n", encoding="utf-8")


def resize(kit: Path, image: str, out: Path) -> None:
    source = (kit / f"{image}.png").resolve()
    if not source.is_relative_to(kit.resolve()) or not source.is_file() or source.is_symlink():
        raise KitError(f"{image}.png is missing from the kit")
    if shutil.which("ffmpeg") is None:
        raise KitError("ffmpeg not found (brew install ffmpeg)")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file", "-f", "image2", "-i", str(source),
                    "-vf", f"scale={TEXTURE_SIZE}:{TEXTURE_SIZE}:flags=lanczos,format=yuvj444p", "-q:v", "2", "-frames:v", "1",
                    "-f", "image2", "-c:v", "mjpeg", str(out / f"{image}.jpg")], check=True)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.splitlines()[2].strip(), file=sys.stderr)
        return 2
    kit, out = Path(argv[0]), Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    images: set[str] = set()
    try:
        for name, placements in RECIPES.items():
            groups: dict[str, Group] = {}
            assemble(kit, placements, groups)
            write_gltf(name, groups, out)
            images |= {g.image for g in groups.values() if g.image}
            points = [p for g in groups.values() for p in g.positions]
            bounds = " ".join(f"{min(p[i] for p in points):.2f}..{max(p[i] for p in points):.2f}" for i in range(3))
            print(f"{name}: {len(placements)} pieces, {len(groups)} materials, {sum(len(g.indices) for g in groups.values()) // 3} triangles, "
                  f"bounds {bounds}")
        for image in sorted(images):
            resize(kit, image, out)
    except (KitError, OSError, KeyError, ValueError, subprocess.CalledProcessError) as err:
        print(f"assemble_world_kit: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
