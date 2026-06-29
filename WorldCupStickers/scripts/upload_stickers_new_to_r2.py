#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import csv
import shlex
import subprocess
import sys
from pathlib import Path


def build_command(wrangler: list[str], row: dict[str, str]) -> tuple[str, list[str]]:
    object_path = f"{row['bucket']}/{row['object_key']}"
    command = [
        *wrangler,
        "r2",
        "object",
        "put",
        object_path,
        f"--file={row['source_path']}",
        f"--content-type={row['content_type']}",
        "--cache-control=public, max-age=31536000, immutable",
        "--remote",
    ]
    return object_path, command


def upload_one(index: int, total: int, wrangler: list[str], row: dict[str, str]) -> str:
    object_path, command = build_command(wrangler, row)
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        details = "\n".join(part for part in [result.stdout, result.stderr] if part)
        raise RuntimeError(f"[{index}/{total}] failed {object_path}\n{details}")
    return f"[{index}/{total}] uploaded {object_path}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--wrangler", default="npx wrangler")
    parser.add_argument("--jobs", type=int, default=1)
    args = parser.parse_args()

    with args.manifest.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    if args.limit is not None:
        rows = rows[: args.limit]

    wrangler = shlex.split(args.wrangler)
    if args.dry_run:
        for index, row in enumerate(rows, start=1):
            object_path, command = build_command(wrangler, row)
            print(f"[{index}/{len(rows)}] {object_path}")
            print(" ".join(shlex.quote(part) for part in command))
        return 0

    jobs = max(1, args.jobs)
    if jobs == 1:
        for index, row in enumerate(rows, start=1):
            print(upload_one(index, len(rows), wrangler, row), flush=True)
        return 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
        futures = [
            executor.submit(upload_one, index, len(rows), wrangler, row)
            for index, row in enumerate(rows, start=1)
        ]
        for future in concurrent.futures.as_completed(futures):
            print(future.result(), flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
