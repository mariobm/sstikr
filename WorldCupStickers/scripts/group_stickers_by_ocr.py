#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
import unicodedata
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageEnhance, ImageOps


@dataclass(frozen=True)
class CatalogEntry:
    album_index: str | None
    code: str
    number: str
    display_id: str
    title: str
    country: str | None
    search_name: str
    search_country: str
    search_title: str


@dataclass
class MatchResult:
    entry: CatalogEntry | None
    score: float
    reason: str


def normalize(value: str) -> str:
    value = value.translate(
        str.maketrans(
            {
                "ı": "i",
                "İ": "I",
                "đ": "d",
                "Đ": "D",
                "ð": "d",
                "Ð": "D",
                "þ": "th",
                "Þ": "Th",
                "ł": "l",
                "Ł": "L",
            }
        )
    )
    decomposed = unicodedata.normalize("NFKD", value)
    ascii_value = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    ascii_value = ascii_value.replace("ø", "o").replace("Ø", "O")
    return re.sub(r"[^a-z0-9]+", " ", ascii_value.lower()).strip()


def compact(value: str) -> str:
    return normalize(value).replace(" ", "")


def contains_phrase(haystack: str, needle: str) -> bool:
    if not needle:
        return False
    pattern = r"(?<![a-z0-9])" + re.escape(needle) + r"(?![a-z0-9])"
    return re.search(pattern, haystack) is not None


def parse_catalog(path: Path) -> list[CatalogEntry]:
    entries: list[CatalogEntry] = []
    numeric_re = re.compile(r"^(\d+)\s+-\s+([A-Z0-9]{2,4})\s+(\d+)\s+-\s+(.+)$")
    cc_re = re.compile(r"^(CC)(\d+)\s+-\s+(.+)$")

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        numeric = numeric_re.match(line)
        cc = cc_re.match(line)
        if numeric:
            album_index, code, number, rest = numeric.groups()
            parts = [part.strip() for part in rest.split(" - ")]
            title = parts[0]
            country = parts[-1] if len(parts) >= 2 else None
        elif cc:
            code, number, rest = cc.groups()
            album_index = None
            title = rest.strip()
            country = None
        else:
            continue

        search_name = normalize(title)
        search_country = normalize(country or "")
        search_title = normalize(" ".join(part for part in [title, country or ""] if part))
        entries.append(
            CatalogEntry(
                album_index=album_index,
                code=code,
                number=str(int(number)) if number.isdigit() else number,
                display_id=f"{code}-{str(int(number)) if number.isdigit() else number}",
                title=title,
                country=country,
                search_name=search_name,
                search_country=search_country,
                search_title=search_title,
            )
        )
    return entries


def sticker_sources(root: Path) -> list[Path]:
    part_1 = sorted(
        path
        for path in root.glob("page-*/page*-sticker-*.jpg")
        if "/part-2/" not in str(path)
    )
    part_2 = sorted((root / "part-2").glob("page-*/page*-sticker-*.jpg"))
    return part_1 + part_2


def make_variant(source: Path, variant: str, target: Path) -> None:
    image = Image.open(source).convert("RGB")
    width, height = image.size

    if variant == "full":
        crop = image
    elif variant == "bottom":
        crop = image.crop((0, int(height * 0.55), width, height))
    elif variant == "label":
        crop = image.crop((int(width * 0.02), int(height * 0.69), int(width * 0.97), int(height * 0.94)))
    elif variant == "label_gray":
        crop = image.crop((int(width * 0.02), int(height * 0.69), int(width * 0.97), int(height * 0.94)))
        crop = ImageOps.grayscale(crop)
        crop = ImageEnhance.Contrast(crop).enhance(2.2)
        crop = ImageOps.colorize(crop, black="black", white="white")
    elif variant == "rot90":
        crop = image.rotate(90, expand=True)
    elif variant == "rot270":
        crop = image.rotate(270, expand=True)
    else:
        raise ValueError(f"Unknown variant {variant}")

    target.parent.mkdir(parents=True, exist_ok=True)
    crop.save(target, "JPEG", quality=92)


def run_vision(swift_script: Path, paths: list[Path], batch_size: int = 80) -> dict[str, list[dict[str, object]]]:
    output: dict[str, list[dict[str, object]]] = {}
    for start in range(0, len(paths), batch_size):
        batch = paths[start : start + batch_size]
        cmd = ["swift", str(swift_script), *[str(path) for path in batch]]
        result = subprocess.run(cmd, check=True, text=True, capture_output=True)
        decoded = json.loads(result.stdout)
        for item in decoded:
            output[item["path"]] = item.get("lines", [])
    return output


def collect_ocr_text(lines_by_variant: dict[str, list[dict[str, object]]]) -> tuple[str, float]:
    texts: list[str] = []
    confidences: list[float] = []
    for lines in lines_by_variant.values():
        for line in lines:
            text = str(line.get("text", "")).strip()
            if text:
                texts.append(text)
                try:
                    confidences.append(float(line.get("confidence", 0)))
                except (TypeError, ValueError):
                    pass
    deduped = list(dict.fromkeys(texts))
    confidence = max(confidences) if confidences else 0.0
    return "\n".join(deduped), confidence


def token_score(ocr_norm: str, ocr_compact: str, entry: CatalogEntry) -> tuple[float, str]:
    name = entry.search_name
    name_compact = compact(entry.title)
    title = entry.search_title

    if name and contains_phrase(ocr_norm, name):
        return 1.0, "exact-name"
    if len(name_compact) >= 8 and name_compact in ocr_compact:
        return 0.98, "compact-name"

    # Logo/team/special stickers often OCR the country or the event label, not the literal catalog title.
    if entry.title.lower() in {"logo", "team"} and entry.search_country and entry.search_country in ocr_norm:
        return 0.92, f"{entry.title.lower()}-country"
    if entry.code == "FWC" and title and title in ocr_norm:
        return 0.95, "fwc-title"

    name_ratio = SequenceMatcher(None, name_compact, ocr_compact).ratio() if name_compact else 0.0
    if len(name_compact) >= 9 and name_ratio >= 0.78:
        return name_ratio * 0.9, "fuzzy-name"

    # Compare against token windows so OCR typos like VERRY/YERRY or DONVELL/DONYELL
    # are recoverable without letting short names like RODRI match RODRIGO.
    name_tokens = name.split()
    ocr_tokens = ocr_norm.split()
    if len(name_compact) >= 7 and name_tokens and len(ocr_tokens) >= len(name_tokens):
        best_window = 0.0
        token_count = len(name_tokens)
        for index in range(0, len(ocr_tokens) - token_count + 1):
            window = "".join(ocr_tokens[index : index + token_count])
            best_window = max(best_window, SequenceMatcher(None, name_compact, window).ratio())
        if best_window >= 0.82:
            return best_window * 0.94, "window-fuzzy-name"

    return 0.0, "no-match"


def match_entry(ocr_text: str, entries: list[CatalogEntry]) -> MatchResult:
    ocr_norm = normalize(ocr_text)
    ocr_compact = ocr_norm.replace(" ", "")
    best = MatchResult(None, 0.0, "no-match")
    second = 0.0

    for entry in entries:
        score, reason = token_score(ocr_norm, ocr_compact, entry)
        if score > best.score:
            second = best.score
            best = MatchResult(entry, score, reason)
        elif score > second:
            second = score

    # Avoid confident-looking but ambiguous assignments.
    if best.entry and best.score >= 0.76 and best.score - second >= 0.03:
        return best
    if best.entry and best.score >= 0.92:
        return best
    return MatchResult(None, best.score, f"ambiguous:{best.reason}")


def copy_grouped(source: Path, stickers_root: Path, output_root: Path, match: MatchResult, used_names: set[str]) -> Path:
    if match.entry is None:
        relative_name = "__".join(source.relative_to(stickers_root).parts)
        destination = output_root / "unknown" / relative_name
    else:
        entry = match.entry
        folder = output_root / entry.code
        destination = folder / f"{entry.code}-{entry.number}.jpg"
        key = str(destination)
        if key in used_names or destination.exists():
            stem = destination.stem
            suffix = 2
            while True:
                candidate = folder / f"{stem}__dup{suffix}.jpg"
                if str(candidate) not in used_names and not candidate.exists():
                    destination = candidate
                    break
                suffix += 1
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    used_names.add(str(destination))
    return destination


def source_page_key(source: Path, stickers_root: Path) -> tuple[str, str] | None:
    relative = source.relative_to(stickers_root)
    parts = relative.parts
    if parts[0] == "part-2" and len(parts) >= 3:
        return ("part-2", parts[1])
    if parts[0].startswith("page-"):
        return ("part-1", parts[0])
    return None


def is_logo_like(ocr_text: str) -> bool:
    normalized = normalize(ocr_text)
    has_event = "fifa world" in normalized or "panini" in normalized or "pamimi" in normalized or "pakini" in normalized
    has_player_measurements = re.search(r"\b\d{1,2}\s+\d{1,2}\s+19\d{2}\b|\b\d\s+\d{2}\s*m\b|\bkg\b", normalized)
    return has_event and not has_player_measurements


def context_logo_match(
    source: Path,
    stickers_root: Path,
    ocr_text: str,
    page_group_counts: dict[tuple[str, str], dict[str, int]],
    entries_by_id: dict[str, CatalogEntry],
) -> MatchResult | None:
    if not is_logo_like(ocr_text):
        return None
    page_key = source_page_key(source, stickers_root)
    if page_key is None:
        return None
    counts = page_group_counts.get(page_key, {})
    if not counts:
        return None
    ranked = sorted(counts.items(), key=lambda item: item[1], reverse=True)
    code, count = ranked[0]
    total = sum(counts.values())
    if count < 4 or count / max(total, 1) < 0.60:
        return None
    entry = entries_by_id.get(f"{code}-1")
    if entry is None or entry.title.lower() != "logo":
        return None
    return MatchResult(entry, 0.91, "page-context-logo")


def write_manifest(path: Path, rows: Iterable[dict[str, object]]) -> None:
    rows = list(rows)
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stickers-root", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--swift-ocr", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    entries = parse_catalog(args.catalog)
    entries_by_id = {entry.display_id: entry for entry in entries}
    sources = sticker_sources(args.stickers_root)
    variants = ["full", "bottom", "label", "label_gray", "rot90", "rot270"]

    if args.output_root.exists() and args.force:
        shutil.rmtree(args.output_root)
    args.output_root.mkdir(parents=True, exist_ok=True)
    args.work_dir.mkdir(parents=True, exist_ok=True)

    variant_paths: dict[str, dict[str, Path]] = {}
    all_variant_images: list[Path] = []
    for source in sources:
        source_key = str(source)
        variant_paths[source_key] = {}
        for variant in variants:
            target = args.work_dir / source.relative_to(args.stickers_root).with_suffix(f".{variant}.jpg")
            make_variant(source, variant, target)
            variant_paths[source_key][variant] = target
            all_variant_images.append(target)

    cache_path = args.output_root / "ocr-cache.json"
    if cache_path.exists() and not args.force:
        ocr_by_variant_path = json.loads(cache_path.read_text(encoding="utf-8"))
    else:
        ocr_by_variant_path = run_vision(args.swift_ocr, all_variant_images)
        cache_path.write_text(json.dumps(ocr_by_variant_path, indent=2), encoding="utf-8")

    prepared: list[dict[str, object]] = []
    page_group_counts: dict[tuple[str, str], dict[str, int]] = {}
    for source in sources:
        lines_by_variant = {
            variant: ocr_by_variant_path.get(str(path), [])
            for variant, path in variant_paths[str(source)].items()
        }
        ocr_text, ocr_confidence = collect_ocr_text(lines_by_variant)
        match = match_entry(ocr_text, entries)
        page_key = source_page_key(source, args.stickers_root)
        if match.entry and page_key:
            page_group_counts.setdefault(page_key, {})
            page_group_counts[page_key][match.entry.code] = page_group_counts[page_key].get(match.entry.code, 0) + 1
        prepared.append(
            {
                "source": source,
                "match": match,
                "ocr_text": ocr_text,
                "ocr_confidence": ocr_confidence,
            }
        )

    used_names: set[str] = set()
    manifest: list[dict[str, object]] = []
    counts: dict[str, int] = {}
    for item in prepared:
        source = item["source"]
        match = item["match"]
        ocr_text = item["ocr_text"]
        ocr_confidence = item["ocr_confidence"]
        if match.entry is None:
            context_match = context_logo_match(source, args.stickers_root, ocr_text, page_group_counts, entries_by_id)
            if context_match is not None:
                match = context_match
        destination = copy_grouped(source, args.stickers_root, args.output_root, match, used_names)
        group = match.entry.code if match.entry else "unknown"
        counts[group] = counts.get(group, 0) + 1
        manifest.append(
            {
                "source": str(source),
                "destination": str(destination),
                "group": group,
                "matched_id": match.entry.display_id if match.entry else "",
                "matched_title": match.entry.title if match.entry else "",
                "matched_country": match.entry.country or "" if match.entry else "",
                "score": f"{match.score:.3f}",
                "reason": match.reason,
                "ocr_confidence": f"{ocr_confidence:.3f}",
                "ocr_text": ocr_text.replace("\n", " | "),
            }
        )

    write_manifest(args.output_root / "grouping-manifest.csv", manifest)
    (args.output_root / "grouping-summary.json").write_text(
        json.dumps({"total": len(sources), "group_counts": dict(sorted(counts.items()))}, indent=2),
        encoding="utf-8",
    )
    print(json.dumps({"total": len(sources), "group_counts": dict(sorted(counts.items()))}, indent=2))


if __name__ == "__main__":
    main()
