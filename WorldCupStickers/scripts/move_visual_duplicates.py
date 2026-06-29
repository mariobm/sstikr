#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import shutil
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image


@dataclass(frozen=True)
class ImageHash:
    path: Path
    bits: int


def dct_matrix(size: int) -> np.ndarray:
    matrix = np.zeros((size, size), dtype=np.float64)
    factor = np.pi / (2 * size)
    for row in range(size):
        scale = np.sqrt(1 / size) if row == 0 else np.sqrt(2 / size)
        for col in range(size):
            matrix[row, col] = scale * np.cos((2 * col + 1) * row * factor)
    return matrix


DCT_32 = dct_matrix(32)


def phash(path: Path) -> int:
    with Image.open(path) as image:
        gray = image.convert("L").resize((32, 32), Image.Resampling.LANCZOS)
    pixels = np.asarray(gray, dtype=np.float64)
    dct = DCT_32 @ pixels @ DCT_32.T
    block = dct[:8, :8].copy()
    values = block.flatten()[1:]
    median = float(np.median(values))
    bits = 0
    for value in values:
        bits = (bits << 1) | int(value > median)
    return bits


def hamming(left: int, right: int) -> int:
    return (left ^ right).bit_count()


def is_duplicate_file(path: Path) -> bool:
    return "__dup" in path.stem


def all_images(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("*.jpg")
        if "duplicates" not in path.relative_to(root).parts
    )


def destination_for(root: Path, source: Path) -> Path:
    relative = source.relative_to(root)
    destination = root / "duplicates" / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        return destination
    suffix = 2
    while True:
        candidate = destination.with_name(f"{destination.stem}__moved{suffix}{destination.suffix}")
        if not candidate.exists():
            return candidate
        suffix += 1


def base_stem_for_dup(path: Path) -> str:
    return path.stem.split("__dup", 1)[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--threshold", type=int, default=10)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    root = args.root
    images = all_images(root)
    non_dups = [path for path in images if not is_duplicate_file(path)]
    dupes = [path for path in images if is_duplicate_file(path)]

    hashes = {str(path): ImageHash(path=path, bits=phash(path)) for path in images}
    non_dup_by_parent_and_stem = {
        (path.parent, path.stem): hashes[str(path)]
        for path in non_dups
    }
    non_dups_by_parent: dict[Path, list[ImageHash]] = {}
    for path in non_dups:
        non_dups_by_parent.setdefault(path.parent, []).append(hashes[str(path)])

    rows: list[dict[str, object]] = []
    moved = 0
    kept = 0
    for source in dupes:
        source_hash = hashes[str(source)]
        base_stem = base_stem_for_dup(source)
        candidates: list[ImageHash] = []
        exact_base = non_dup_by_parent_and_stem.get((source.parent, base_stem))
        if exact_base is not None:
            candidates.append(exact_base)
        else:
            candidates.extend(non_dups_by_parent.get(source.parent, []))

        best: ImageHash | None = None
        distance: int | None = None
        for candidate in candidates:
            candidate_distance = hamming(source_hash.bits, candidate.bits)
            if distance is None or candidate_distance < distance:
                best = candidate
                distance = candidate_distance

        similar = distance is not None and distance <= args.threshold
        destination = ""
        action = "keep"
        if similar:
            target = destination_for(root, source)
            destination = str(target)
            action = "move"
            moved += 1
            if not args.dry_run:
                shutil.move(str(source), str(target))
        else:
            kept += 1

        rows.append(
            {
                "source": str(source),
                "matched_non_dup": str(best.path) if best is not None else "",
                "distance": distance if distance is not None else "",
                "threshold": args.threshold,
                "action": action,
                "destination": destination,
            }
        )

    manifest = root / "duplicates" / "duplicate-move-manifest.csv"
    summary = root / "duplicates" / "duplicate-move-summary.json"
    if not args.dry_run:
        manifest.parent.mkdir(parents=True, exist_ok=True)
        with manifest.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()) if rows else [])
            if rows:
                writer.writeheader()
                writer.writerows(rows)
        summary.write_text(
            json.dumps(
                {
                    "threshold": args.threshold,
                    "non_dup_count": len(non_dups),
                    "dup_count": len(dupes),
                    "moved": moved,
                    "kept": kept,
                    "manifest": str(manifest),
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    print(
        json.dumps(
            {
                "threshold": args.threshold,
                "non_dup_count": len(non_dups),
                "dup_count": len(dupes),
                "moved": moved,
                "kept": kept,
                "dry_run": args.dry_run,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
