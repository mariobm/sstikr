#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps


@dataclass(frozen=True)
class StickerEntry:
    global_index: int
    page: int
    cell: int
    code: str
    number: str
    filename: str
    title: str
    country: str
    destination: Path


def parse_catalog(path: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    numeric_re = re.compile(r"^(\d+)\s+-\s+([A-Z0-9]{2,4})\s+(\d+)\s+-\s+(.+)$")
    cc_re = re.compile(r"^CC(\d+)\s+-\s+(.+)$")

    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("00 -"):
            entries.append({"code": "00", "number": "", "title": "PANINI", "country": ""})
            continue
        numeric = numeric_re.match(line)
        if numeric:
            _, code, number, rest = numeric.groups()
            parts = [part.strip() for part in rest.split(" - ")]
            title = parts[0]
            country = parts[-1] if len(parts) > 1 else ""
            entries.append({"code": code, "number": str(int(number)), "title": title, "country": country})
            continue
        cc = cc_re.match(line)
        if cc:
            number, title = cc.groups()
            entries.append({"code": "CC", "number": str(int(number)), "title": title.strip(), "country": ""})

    return entries


def expected_sequence(catalog_path: Path) -> list[dict[str, str]]:
    catalog = parse_catalog(catalog_path)
    zero = [entry for entry in catalog if entry["code"] == "00"]
    fwc = [entry for entry in catalog if entry["code"] == "FWC"]
    countries = [entry for entry in catalog if re.fullmatch(r"[A-Z]{3}", entry["code"]) and entry["code"] != "FWC"]
    cc = [entry for entry in catalog if entry["code"] == "CC"]

    country_counts: dict[str, int] = {}
    for entry in countries:
        country_counts[entry["code"]] = country_counts.get(entry["code"], 0) + 1
    bad_country_counts = {code: count for code, count in country_counts.items() if count != 20}
    if len(zero) != 1 or len(fwc) != 19 or len(countries) != 960 or bad_country_counts:
        raise ValueError(
            f"Unexpected catalog shape: zero={len(zero)}, fwc={len(fwc)}, "
            f"countries={len(countries)}, bad_country_counts={bad_country_counts}"
        )

    cc_by_number = {int(entry["number"]): entry for entry in cc}
    for number in (13, 14):
        cc_by_number.setdefault(
            number,
            {"code": "CC", "number": str(number), "title": f"CC{number}", "country": ""},
        )

    first_fwc = [entry for entry in fwc if int(entry["number"]) <= 8]
    later_fwc = [entry for entry in fwc if int(entry["number"]) >= 9]
    ordered_cc = [cc_by_number[number] for number in range(1, 15)]
    sequence = zero + first_fwc + countries + later_fwc + ordered_cc
    if len(sequence) != 994:
        raise ValueError(f"Expected 994 stickers, got {len(sequence)}")
    return sequence


def render_pdf(pdf_path: Path, render_dir: Path, dpi: int, force: bool) -> None:
    render_dir.mkdir(parents=True, exist_ok=True)
    expected = [render_dir / f"page-{page:02d}.png" for page in range(1, 64)]
    if not force and all(path.exists() for path in expected):
        return
    if force:
        shutil.rmtree(render_dir, ignore_errors=True)
        render_dir.mkdir(parents=True, exist_ok=True)
    prefix = render_dir / "page"
    pdftoppm = shutil.which("pdftoppm")
    if pdftoppm is None:
        raise RuntimeError("pdftoppm is required to render the source PDF; install Poppler and add it to PATH")
    command = [
        pdftoppm,
        "-png",
        "-r",
        str(dpi),
        str(pdf_path),
        str(prefix),
    ]
    subprocess.run(command, check=True)
    actual = sorted(render_dir.glob("page-*.png"))
    if len(actual) != 63:
        raise RuntimeError(f"Expected 63 rendered pages, got {len(actual)}")


def page_path(render_dir: Path, page: int) -> Path:
    path = render_dir / f"page-{page:02d}.png"
    if path.exists():
        return path
    path = render_dir / f"page-{page}.png"
    if path.exists():
        return path
    raise FileNotFoundError(render_dir / f"page-{page:02d}.png")


def segments(values: np.ndarray, threshold: float, minimum: int = 20) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    start: int | None = None
    for index, count in enumerate(values):
        if count > threshold and start is None:
            start = index
        elif count <= threshold and start is not None:
            if index - start >= minimum:
                result.append((start, index - 1))
            start = None
    if start is not None and len(values) - start >= minimum:
        result.append((start, len(values) - 1))
    return result


def detect_grid(reference_page: Path) -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
    image = Image.open(reference_page).convert("RGB")
    arr = np.asarray(image)
    mask = np.any(arr < 245, axis=2)
    row_counts = mask.sum(axis=1)
    col_counts = mask.sum(axis=0)
    row_segments = segments(row_counts, image.width * 0.40)
    col_segments = segments(col_counts, image.height * 0.40)
    if len(row_segments) != 4 or len(col_segments) != 4:
        raise RuntimeError(f"Could not detect 4x4 grid: rows={row_segments}, cols={col_segments}")
    return row_segments, col_segments


def output_path_for(output_root: Path, entry: dict[str, str]) -> Path:
    code = entry["code"]
    number = entry["number"]
    if code == "00":
        return output_root / "00.jpg"
    if code == "CC":
        return output_root / "CC" / f"CC{number}.jpg"
    return output_root / code / f"{code}-{number}.jpg"


def crop_cell(image: Image.Image, rows: list[tuple[int, int]], cols: list[tuple[int, int]], cell: int) -> Image.Image:
    row_index = (cell - 1) // 4
    col_index = (cell - 1) % 4
    top, bottom = rows[row_index]
    left, right = cols[col_index]
    return image.crop((left, top, right + 1, bottom + 1))


def create_review_sheet(render_dir: Path, manifest: list[StickerEntry], output_root: Path) -> Path:
    review_dir = output_root / "_review"
    review_dir.mkdir(parents=True, exist_ok=True)
    selected_pages = {1, 61, 62, 63}
    thumb_w = 150
    gap = 12
    label_h = 18
    margin = 16
    for page in sorted(selected_pages):
        page_entries = [entry for entry in manifest if entry.page == page]
        if not page_entries:
            continue
        rows = max((entry.cell - 1) // 4 for entry in page_entries) + 1
        cols = 4
        thumb_h = 200
        sheet = Image.new(
            "RGB",
            (margin * 2 + cols * thumb_w + (cols - 1) * gap, margin * 2 + rows * (label_h + thumb_h) + (rows - 1) * gap),
            "white",
        )
        for entry in page_entries:
            image = Image.open(entry.destination).convert("RGB")
            thumb = ImageOps.contain(image, (thumb_w, thumb_h), Image.Resampling.LANCZOS)
            row = (entry.cell - 1) // 4
            col = (entry.cell - 1) % 4
            x = margin + col * (thumb_w + gap)
            y = margin + row * (label_h + thumb_h + gap)
            sheet.paste(thumb, (x, y + label_h))
        sheet.save(review_dir / f"page-{page:03d}-review.jpg", "JPEG", quality=90)
    return review_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--render-dir", type=Path, required=True)
    parser.add_argument("--dpi", type=int, default=300)
    parser.add_argument("--force-render", action="store_true")
    args = parser.parse_args()

    sequence = expected_sequence(args.catalog)
    if args.output_root.exists():
        shutil.rmtree(args.output_root)
    args.output_root.mkdir(parents=True, exist_ok=True)
    render_pdf(args.pdf, args.render_dir, args.dpi, args.force_render)
    row_segments, col_segments = detect_grid(page_path(args.render_dir, 2))

    manifest: list[StickerEntry] = []
    for index, entry in enumerate(sequence):
        page = index // 16 + 1
        cell = index % 16 + 1
        source = page_path(args.render_dir, page)
        image = Image.open(source).convert("RGB")
        crop = crop_cell(image, row_segments, col_segments, cell)
        destination = output_path_for(args.output_root, entry)
        destination.parent.mkdir(parents=True, exist_ok=True)
        crop.save(destination, "JPEG", quality=95, subsampling=0, optimize=True)
        manifest.append(
            StickerEntry(
                global_index=index,
                page=page,
                cell=cell,
                code=entry["code"],
                number=entry["number"],
                filename=destination.name,
                title=entry["title"],
                country=entry["country"],
                destination=destination,
            )
        )

    with (args.output_root / "_manifest.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["global_index", "page", "cell", "code", "number", "filename", "title", "country", "destination"],
        )
        writer.writeheader()
        for entry in manifest:
            writer.writerow(
                {
                    "global_index": entry.global_index,
                    "page": entry.page,
                    "cell": entry.cell,
                    "code": entry.code,
                    "number": entry.number,
                    "filename": entry.filename,
                    "title": entry.title,
                    "country": entry.country,
                    "destination": str(entry.destination),
                }
            )

    summary: dict[str, object] = {
        "total": len(manifest),
        "grid": {"rows": row_segments, "cols": col_segments},
        "codes": {},
        "special_checks": {
            "page_1_cell_1": manifest[0].filename,
            "page_1_cell_2": manifest[1].filename,
            "page_1_cell_10": manifest[9].filename,
            "page_61_cell_10": manifest[(61 - 1) * 16 + 9].filename,
            "page_62_cell_1": manifest[(62 - 1) * 16].filename,
            "page_62_cell_5": manifest[(62 - 1) * 16 + 4].filename,
            "page_63_cell_1": manifest[(63 - 1) * 16].filename,
            "page_63_cell_2": manifest[(63 - 1) * 16 + 1].filename,
        },
    }
    for entry in manifest:
        summary["codes"][entry.code] = summary["codes"].get(entry.code, 0) + 1
    (args.output_root / "_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    create_review_sheet(args.render_dir, manifest, args.output_root)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
