#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


CATALOG_VERSION = "2026.06.29-avif"
DEFAULT_BUCKET = "world-cup-stickers"
COUNTRY_RE = re.compile(r"^[A-Z]{3}$")

GROUPS = {
    "A": ["MEX", "RSA", "KOR", "CZE"],
    "B": ["CAN", "BIH", "QAT", "SUI"],
    "C": ["BRA", "MAR", "HAI", "SCO"],
    "D": ["USA", "PAR", "AUS", "TUR"],
    "E": ["GER", "CUW", "CIV", "ECU"],
    "F": ["NED", "JPN", "SWE", "TUN"],
    "G": ["BEL", "EGY", "IRN", "NZL"],
    "H": ["ESP", "CPV", "KSA", "URU"],
    "I": ["FRA", "SEN", "IRQ", "NOR"],
    "J": ["ARG", "ALG", "AUT", "JOR"],
    "K": ["POR", "COD", "UZB", "COL"],
    "L": ["ENG", "CRO", "GHA", "PAN"],
}

GROUP_BY_CODE = {
    code: group_code
    for group_code, codes in GROUPS.items()
    for code in codes
}

GROUP_COLORS = {
    "A": ("#00866F", "#E7442E"),
    "B": ("#A51D42", "#2D7FF9"),
    "C": ("#14843B", "#F3B61F"),
    "D": ("#174EA6", "#D6264D"),
    "E": ("#1A1A1A", "#F2C94C"),
    "F": ("#E76F1E", "#00A6A6"),
    "G": ("#5D2E8C", "#E4B363"),
    "H": ("#C9342F", "#0B7A75"),
    "I": ("#1D5FA7", "#DB2B39"),
    "J": ("#6BB7D6", "#F2B705"),
    "K": ("#0E7C66", "#C31E39"),
    "L": ("#3851A3", "#F0A202"),
}

FLAGS = {
    "MEX": "🇲🇽",
    "RSA": "🇿🇦",
    "KOR": "🇰🇷",
    "CZE": "🇨🇿",
    "CAN": "🇨🇦",
    "BIH": "🇧🇦",
    "QAT": "🇶🇦",
    "SUI": "🇨🇭",
    "BRA": "🇧🇷",
    "MAR": "🇲🇦",
    "HAI": "🇭🇹",
    "SCO": "🏴󠁧󠁢󠁳󠁣󠁴󠁿",
    "USA": "🇺🇸",
    "PAR": "🇵🇾",
    "AUS": "🇦🇺",
    "TUR": "🇹🇷",
    "GER": "🇩🇪",
    "CUW": "🇨🇼",
    "CIV": "🇨🇮",
    "ECU": "🇪🇨",
    "NED": "🇳🇱",
    "JPN": "🇯🇵",
    "SWE": "🇸🇪",
    "TUN": "🇹🇳",
    "BEL": "🇧🇪",
    "EGY": "🇪🇬",
    "IRN": "🇮🇷",
    "NZL": "🇳🇿",
    "ESP": "🇪🇸",
    "CPV": "🇨🇻",
    "KSA": "🇸🇦",
    "URU": "🇺🇾",
    "FRA": "🇫🇷",
    "SEN": "🇸🇳",
    "IRQ": "🇮🇶",
    "NOR": "🇳🇴",
    "ARG": "🇦🇷",
    "ALG": "🇩🇿",
    "AUT": "🇦🇹",
    "JOR": "🇯🇴",
    "POR": "🇵🇹",
    "COD": "🇨🇩",
    "UZB": "🇺🇿",
    "COL": "🇨🇴",
    "ENG": "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
    "CRO": "🇭🇷",
    "GHA": "🇬🇭",
    "PAN": "🇵🇦",
}


def sql_quote(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def sticker_id(code: str, number: str) -> str:
    if code == "00":
        return "00"
    return f"{code}-{int(number)}"


def display_code(code: str, number: str) -> str:
    if code == "00":
        return "00"
    return f"{code} {int(number)}"


def category(code: str, number: str, title: str) -> str:
    if code == "00":
        return "album"
    if code == "FWC":
        return "fwc"
    if code == "CC":
        return "cc"
    if int(number) == 1 or title.lower() == "logo":
        return "team_logo"
    if int(number) == 13 or title.lower() == "team":
        return "team"
    return "player"


def object_key(code: str, number: str) -> str:
    if code == "00":
        return "stickers-new/00.avif"
    numeric = int(number)
    return f"stickers-new/{code}/{code}-{numeric}.avif"


def source_path(row: dict[str, str]) -> str:
    return str(Path(row["destination"]).with_suffix(".avif"))


def collect_team_names(rows: list[dict[str, str]]) -> dict[str, str]:
    names: dict[str, str] = {}
    for row in rows:
        code = row["code"]
        country = row["country"].strip()
        if COUNTRY_RE.match(code) and code != "FWC" and country:
            names.setdefault(code, country)
    return names


def team_name_for(row: dict[str, str], team_names: dict[str, str]) -> str:
    code = row["code"]
    if code == "00":
        return "Album"
    if code == "FWC":
        return "FIFA World Cup"
    if code == "CC":
        return "Coca-Cola"
    return team_names.get(code, row["country"].strip() or code)


def team_definitions(rows: list[dict[str, str]], team_names: dict[str, str]) -> list[dict[str, object]]:
    seen: list[str] = []
    for row in rows:
        code = row["code"]
        if COUNTRY_RE.match(code) and code != "FWC" and code not in seen:
            seen.append(code)

    teams = []
    for index, code in enumerate(seen, start=1):
        group_code = GROUP_BY_CODE[code]
        primary_color, secondary_color = GROUP_COLORS[group_code]
        teams.append(
            {
                "id": code,
                "code": code,
                "name": team_names.get(code, code),
                "groupCode": group_code,
                "flag": FLAGS[code],
                "primaryColor": primary_color,
                "secondaryColor": secondary_color,
                "sortOrder": index,
                "stickerCount": 20,
            }
        )
    return teams


def catalog_stickers(rows: list[dict[str, str]], team_names: dict[str, str], public_base_url: str | None) -> list[dict[str, object]]:
    stickers: list[dict[str, object]] = []
    for row in rows:
        code = row["code"]
        number = row["number"]
        path = object_key(code, number)
        image_url = f"{public_base_url.rstrip('/')}/{path}" if public_base_url else None
        stickers.append(
            {
                "id": sticker_id(code, number),
                "teamCode": code,
                "teamName": team_name_for(row, team_names),
                "number": int(number) if number else 0,
                "displayCode": display_code(code, number),
                "name": row["title"],
                "category": category(code, number, row["title"]),
                "imagePath": path,
                "imageURL": image_url,
                "sortOrder": int(row["global_index"]) + 1,
            }
        )
    return stickers


def write_catalog_json(path: Path, rows: list[dict[str, str]], public_base_url: str | None) -> None:
    team_names = collect_team_names(rows)
    catalog = {
        "version": CATALOG_VERSION,
        "source": "2026EUAMEXCAN - Para Cortar.pdf, extracted 2026-06-28",
        "stickersPerTeam": 20,
        "teams": team_definitions(rows, team_names),
        "stickers": catalog_stickers(rows, team_names, public_base_url),
    }
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_seed_sql(path: Path, rows: list[dict[str, str]], public_base_url: str | None) -> None:
    team_names = collect_team_names(rows)
    values: list[str] = []
    for row in rows:
        code = row["code"]
        number = row["number"]
        key = object_key(code, number)
        image_url = f"{public_base_url.rstrip('/')}/{key}" if public_base_url else None
        group_code = GROUP_BY_CODE.get(code)
        primary_color, secondary_color = GROUP_COLORS.get(group_code, ("#6B7280", "#111827"))
        values.append(
            "  ("
            + ", ".join(
                [
                    sql_quote(sticker_id(code, number)),
                    sql_quote(code),
                    sql_quote(team_name_for(row, team_names)),
                    str(int(number) if number else 0),
                    sql_quote(display_code(code, number)),
                    sql_quote(row["title"]),
                    sql_quote(category(code, number, row["title"])),
                    sql_quote(key),
                    sql_quote(image_url),
                    sql_quote(group_code),
                    sql_quote(FLAGS.get(code)),
                    sql_quote(primary_color),
                    sql_quote(secondary_color),
                    str(int(row["global_index"]) + 1),
                    sql_quote(CATALOG_VERSION),
                ]
            )
            + ")"
        )

    sql = """insert into public.sticker_catalog (
  id,
  team_code,
  team_name,
  sticker_number,
  display_code,
  name,
  category,
  image_path,
  image_url,
  group_code,
  flag,
  primary_color,
  secondary_color,
  sort_order,
  catalog_version
)
values
"""
    sql += ",\n".join(values)
    sql += """
on conflict (id) do update set
  team_code = excluded.team_code,
  team_name = excluded.team_name,
  sticker_number = excluded.sticker_number,
  display_code = excluded.display_code,
  name = excluded.name,
  category = excluded.category,
  image_path = excluded.image_path,
  image_url = excluded.image_url,
  group_code = excluded.group_code,
  flag = excluded.flag,
  primary_color = excluded.primary_color,
  secondary_color = excluded.secondary_color,
  sort_order = excluded.sort_order,
  catalog_version = excluded.catalog_version;
"""
    path.write_text(sql, encoding="utf-8")


def write_upload_manifest(path: Path, rows: list[dict[str, str]], bucket: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = ["id", "bucket", "object_key", "source_path", "content_type", "bytes"]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            source = Path(source_path(row))
            code = row["code"]
            number = row["number"]
            writer.writerow(
                {
                    "id": sticker_id(code, number),
                    "bucket": bucket,
                    "object_key": object_key(code, number),
                    "source_path": str(source),
                    "content_type": "image/avif",
                    "bytes": source.stat().st_size,
                }
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--catalog-json", type=Path, required=True)
    parser.add_argument("--seed-sql", type=Path, required=True)
    parser.add_argument("--upload-manifest", type=Path, required=True)
    parser.add_argument("--bucket", default=DEFAULT_BUCKET)
    parser.add_argument("--public-base-url")
    args = parser.parse_args()

    with args.manifest.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    if len(rows) != 994:
        raise ValueError(f"Expected 994 stickers, got {len(rows)}")

    write_catalog_json(args.catalog_json, rows, args.public_base_url)
    write_seed_sql(args.seed_sql, rows, args.public_base_url)
    write_upload_manifest(args.upload_manifest, rows, args.bucket)
    print(json.dumps({"stickers": len(rows), "bucket": args.bucket, "version": CATALOG_VERSION}, indent=2))


if __name__ == "__main__":
    main()
