#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

from PIL import Image, ImageEnhance, ImageOps


COUNTRY_RE = re.compile(r"^[A-Z]{3}$")
NON_COUNTRY_CODES = {"FWC", "CC"}


@dataclass(frozen=True)
class WorkItem:
    code: str
    number: int
    title: str
    source: Path


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


def make_variants(item: WorkItem, work_dir: Path) -> list[Path]:
    with Image.open(item.source) as raw:
        image = raw.convert("RGB")
    width, height = image.size
    crops = {
        "full": image,
        "lower": image.crop((int(width * 0.02), int(height * 0.61), int(width * 0.98), int(height * 0.97))),
        "namebar": image.crop((int(width * 0.04), int(height * 0.69), int(width * 0.94), int(height * 0.85))),
    }
    lower_gray = ImageOps.grayscale(crops["lower"])
    lower_gray = ImageEnhance.Contrast(lower_gray).enhance(2.4)
    crops["lower_bw"] = ImageOps.colorize(lower_gray, black="black", white="white")

    paths: list[Path] = []
    for variant, crop in crops.items():
        if variant != "full":
            crop = crop.resize((crop.width * 2, crop.height * 2), Image.Resampling.LANCZOS)
        target = work_dir / item.code / f"{item.code}-{item.number}.{variant}.jpg"
        target.parent.mkdir(parents=True, exist_ok=True)
        crop.save(target, "JPEG", quality=92)
        paths.append(target)
    return paths


def run_ocr(ocr_command: list[str], paths: list[Path], batch_size: int) -> dict[str, list[dict[str, object]]]:
    output: dict[str, list[dict[str, object]]] = {}
    for start in range(0, len(paths), batch_size):
        batch = paths[start : start + batch_size]
        result = subprocess.run(
            [*ocr_command, *[str(path) for path in batch]],
            check=True,
            text=True,
            capture_output=True,
        )
        decoded = json.loads(result.stdout)
        for item in decoded:
            output[item["path"]] = item.get("lines", [])
    return output


def match_score(expected: str, ocr_text: str) -> tuple[float, str]:
    expected_norm = normalize(expected)
    ocr_norm = normalize(ocr_text)
    expected_compact = expected_norm.replace(" ", "")
    ocr_compact = ocr_norm.replace(" ", "")

    if not expected_norm:
        return 0.0, "empty-expected"
    if re.search(r"(?<![a-z0-9])" + re.escape(expected_norm) + r"(?![a-z0-9])", ocr_norm):
        return 1.0, "exact-name"
    if len(expected_compact) >= 7 and expected_compact in ocr_compact:
        return 0.98, "compact-name"

    tokens = expected_norm.split()
    ocr_tokens = ocr_norm.split()
    best_window = 0.0
    if tokens and len(ocr_tokens) >= len(tokens):
        token_count = len(tokens)
        for index in range(0, len(ocr_tokens) - token_count + 1):
            window = "".join(ocr_tokens[index : index + token_count])
            best_window = max(best_window, SequenceMatcher(None, expected_compact, window).ratio())

    global_ratio = SequenceMatcher(None, expected_compact, ocr_compact).ratio() if expected_compact else 0.0
    best = max(best_window, global_ratio)
    if best >= 0.82:
        return best, "fuzzy-name"
    return best, "no-match"


def read_work_items(manifest: Path) -> list[WorkItem]:
    items: list[WorkItem] = []
    with manifest.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            code = row["code"]
            number = row["number"]
            if not COUNTRY_RE.match(code) or code in NON_COUNTRY_CODES:
                continue
            if not number:
                continue
            numeric = int(number)
            if numeric in {1, 13}:
                continue
            title = row["title"].strip()
            source = Path(row["destination"])
            if not source.is_file():
                raise FileNotFoundError(source)
            items.append(WorkItem(code=code, number=numeric, title=title, source=source))
    return items


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--ocr-command", nargs="+", required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=80)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    manifest = args.output_root / "_manifest.csv"
    items = read_work_items(manifest)
    if args.force and args.work_dir.exists():
        for path in sorted(args.work_dir.rglob("*.jpg")):
            path.unlink()
    args.work_dir.mkdir(parents=True, exist_ok=True)

    variant_map: dict[str, list[Path]] = {}
    all_variants: list[Path] = []
    for item in items:
        key = f"{item.code}-{item.number}"
        paths = make_variants(item, args.work_dir)
        variant_map[key] = paths
        all_variants.extend(paths)

    ocr_by_path = run_ocr(args.ocr_command, all_variants, args.batch_size)
    report_rows: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []
    for item in items:
        key = f"{item.code}-{item.number}"
        lines: list[dict[str, object]] = []
        for path in variant_map[key]:
            lines.extend(ocr_by_path.get(str(path), []))
        texts = [str(line.get("text", "")).strip() for line in lines if str(line.get("text", "")).strip()]
        confidence_values = []
        for line in lines:
            try:
                confidence_values.append(float(line.get("confidence", 0.0)))
            except (TypeError, ValueError):
                pass
        ocr_text = "\n".join(dict.fromkeys(texts))
        score, reason = match_score(item.title, ocr_text)
        passed = score >= 0.82
        row = {
            "id": key,
            "expected_title": item.title,
            "score": f"{score:.3f}",
            "reason": reason,
            "passed": "yes" if passed else "no",
            "max_vision_confidence": f"{max(confidence_values) if confidence_values else 0.0:.3f}",
            "source": str(item.source),
            "ocr_text": ocr_text.replace("\n", " | "),
        }
        report_rows.append(row)
        if not passed:
            failures.append(row)

    csv_path = args.output_root / "_ocr-validation.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(report_rows[0].keys()))
        writer.writeheader()
        writer.writerows(report_rows)

    summary = {
        "eligible_country_player_stickers": len(items),
        "passed": len(items) - len(failures),
        "failed": len(failures),
        "pass_rate": round((len(items) - len(failures)) / max(len(items), 1), 4),
        "report": str(csv_path),
        "failures": failures[:40],
    }
    summary_path = args.output_root / "_ocr-validation-summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if not failures else 2


if __name__ == "__main__":
    sys.exit(main())
