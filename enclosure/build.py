"""Writes STL files: one per printed part (in print orientation) plus assembly.stl for viewing.

Run: .venv/bin/python build.py [--variant NAME ...] [--all]
Output: out/<variant>/{tray,lid,nose}.stl and out/<variant>/assembly.stl
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import trimesh

from params import BUILD_DEFAULT, VARIANT_NOTES, VARIANTS, variant
from parts import PRINT_NOTES, Builder, to_trimesh

OUT = Path(__file__).resolve().parent / "out"


def build_variant(name: str, outdir: Path) -> list[tuple[Path, str]]:
    b = Builder(variant(name))
    outdir.mkdir(parents=True, exist_ok=True)
    written = []
    for part, m in b.print_parts().items():
        path = outdir / f"{part}.stl"
        tm = to_trimesh(m)
        tm.export(path)
        back = trimesh.load(path, force="mesh")
        if not (back.is_watertight and back.is_winding_consistent and back.volume > 0):
            raise RuntimeError(f"{path}: the re-loaded STL is not a closed solid")
        if not np.allclose(back.bounds, tm.bounds, atol=1e-3):
            raise RuntimeError(f"{path}: bounds changed after the round trip")
        size = back.extents
        written.append((path, f"{size[0]:.1f} × {size[1]:.1f} × {size[2]:.1f} mm, "
                              f"{back.volume / 1000:.2f} cm³, {PRINT_NOTES[part]}"))

    a = b.assembly()
    meshes = [to_trimesh(m) for m in a.parts.values()] + [to_trimesh(ph.solid) for ph in a.phantoms]
    path = outdir / "assembly.stl"
    trimesh.util.concatenate(meshes).export(path)
    written.append((path, f"parts and components assembled, nose at {a.angle:.0f}° (for viewing only)"))
    return written


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--variant", action="append", choices=sorted(VARIANTS))
    ap.add_argument("--all", action="store_true", help="build every variant, not only the default set")
    args = ap.parse_args()
    names = args.variant or (list(VARIANTS) if args.all else list(BUILD_DEFAULT))
    for name in names:
        lay = Builder(variant(name)).lay
        print(f"{name}: {VARIANT_NOTES.get(name, '')} — case {lay.L:.1f} × {lay.W:.1f} × {lay.H:.1f} mm")
        for path, info in build_variant(name, OUT / name):
            print(f"  {path}  ({info})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
