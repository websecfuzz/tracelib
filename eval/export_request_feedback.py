#!/usr/bin/env python3
"""Export compact per-request feedback records from a campaign capture."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence
from urllib.parse import urlsplit

BITMAP_SIZE = 65536

def stable_hash(values: Iterable[Any]) -> str:
    digest = hashlib.sha256()
    for value in sorted(values):
        digest.update(str(value).encode("utf-8", errors="replace"))
        digest.update(b"\n")
    return digest.hexdigest()

def json_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()

def request_text(method: str, url: str) -> str:
    parsed = urlsplit(url)
    target = parsed.path or "/"
    if parsed.query:
        target = f"{target}?{parsed.query}"
    return f"{method.upper()} {target}"

def ast_coverage_hash(path: Path) -> Optional[str]:
    if not path.is_file():
        return None
    edges = set()
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for raw in source:
            line = raw.strip()
            if not line:
                continue
            label_text, separator, count_text = line.rpartition("-")
            if not separator:
                continue
            try:
                if int(count_text) > 0:
                    edges.add(int(label_text))
            except ValueError:
                continue
    return stable_hash(edges)

def to_bucket(hit_count: int) -> int:
    """webFuzz's hit-count bucket (webfuzz/webFuzz/misc.py:136).

    9 buckets: 1 | 2 | 3-4 | 5-8 | 9-16 | 17-32 | 33-64 | 65-128 | 129-255.
    Kept byte-identical to the fuzzer so the "index+frequency" relation measured
    here is the one the corpus rule would actually apply."""
    if hit_count >= 256:
        return 8
    return int(math.ceil(math.log2(hit_count)))

def bitmap_coverage_hash(path: Path, mode: str = "index") -> Optional[str]:
    """Hash one request's TraceLib bitmap.

    mode="index"   positional novelty only: the SET of lit cells. Two requests
                   agree when they lit the same cells, however often.
    mode="bucket"  index AND frequency: the set of (cell, hit-count bucket)
                   pairs, i.e. the relation webFuzz's default corpus rule uses.
                   Strictly finer than "index" -- it can only split, never merge.
    """
    if not path.is_file():
        return None
    data = path.read_bytes()
    if len(data) < BITMAP_SIZE:
        return None
    cells = data[:BITMAP_SIZE]
    if mode == "index":
        return stable_hash(index for index, value in enumerate(cells) if value)
    if mode == "bucket":
        return stable_hash(
            f"{index}:{to_bucket(value)}" for index, value in enumerate(cells) if value
        )
    raise ValueError(f"unknown bitmap hash mode: {mode}")

def read_manifest(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    seen = set()
    if not path.is_file():
        return rows
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for raw in source:
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
                request_id = str(row["request_id"])
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                continue
            if request_id in seen:
                continue
            seen.add(request_id)
            row["request_id"] = request_id
            rows.append(row)
    rows.sort(key=lambda item: (int(item.get("ordinal", 0)), int(item.get("timestamp_ns", 0))))
    return rows

def code_coverage_hash(capture_dir: Path, row: Mapping[str, Any]) -> Optional[str]:
    request_id = str(row.get("request_id", ""))
    ast_hash = ast_coverage_hash(capture_dir / "ast" / f"map.{request_id}")
    if ast_hash is not None:
        return ast_hash

    reference_feedback = row.get("reference_feedback")
    if isinstance(reference_feedback, Mapping) and "error" not in reference_feedback:
        covered_hash = reference_feedback.get("covered_hash")
        if isinstance(covered_hash, str) and covered_hash:
            return covered_hash
        return json_hash(reference_feedback)
    return None

BITMAP_HASH_FIELD = {"index": "bitmap_coverage_hash", "bucket": "bitmap_coverage_hash_bucket"}

def export_records(
    capture_dir: Path, phase: str, bitmap_modes: Sequence[str] = ("index", "bucket")
) -> List[Dict[str, Optional[str]]]:
    """One record per request.

    `bitmap_coverage_hash` is always the index-only relation, so every existing
    consumer keeps working. `bitmap_coverage_hash_bucket` carries the
    index+frequency relation when it is requested, so one capture can be scored
    both ways without re-running the campaign.
    """
    records: List[Dict[str, Optional[str]]] = []
    for row in read_manifest(capture_dir / "requests.jsonl"):
        if phase != "all" and row.get("phase", "crawl") != phase:
            continue
        request_id = str(row["request_id"])
        bitmap_path = capture_dir / "tracelib" / request_id
        record: Dict[str, Optional[str]] = {
            "request": request_text(str(row.get("method", "")), str(row.get("url", ""))),
            "code_coverage_hash": code_coverage_hash(capture_dir, row),
        }
        for mode in bitmap_modes:
            record[BITMAP_HASH_FIELD[mode]] = bitmap_coverage_hash(bitmap_path, mode)
        records.append(record)
    return records

def write_json(output: Path, records: List[Dict[str, Optional[str]]]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    temporary.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)

def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="request-feedback-test-") as tmp:
        root = Path(tmp)
        capture = root / "capture"
        (capture / "ast").mkdir(parents=True)
        (capture / "tracelib").mkdir()
        (capture / "requests.jsonl").write_text(
            json.dumps(
                {
                    "ordinal": 1,
                    "timestamp_ns": 1,
                    "request_id": "wf-a",
                    "method": "GET",
                    "url": "http://localhost:8102/index.php?a=1",
                    "phase": "crawl",
                }
            )
            + "\n"
            + json.dumps(
                {
                    "ordinal": 2,
                    "timestamp_ns": 2,
                    "request_id": "wf-b",
                    "method": "POST",
                    "url": "http://localhost:8102/fuzz.php",
                    "phase": "fuzz",
                    "reference_feedback": {
                        "reference_kind": "language_line_union",
                        "covered": 4,
                        "total": 10,
                        "pct": 40.0,
                        "covered_hash": "abc123",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (capture / "ast" / "map.wf-a").write_text("10-1\n11-3\n", encoding="utf-8")
        bitmap = bytearray(BITMAP_SIZE)
        bitmap[7] = 1
        bitmap[13] = 2
        (capture / "tracelib" / "wf-a").write_bytes(bytes(bitmap))
        output = root / "requests.json"
        write_json(output, export_records(capture, "crawl"))
        records = json.loads(output.read_text(encoding="utf-8"))
        assert records == [
            {
                "request": "GET /index.php?a=1",
                "code_coverage_hash": stable_hash([10, 11]),
                "bitmap_coverage_hash": stable_hash([7, 13]),
                "bitmap_coverage_hash_bucket": stable_hash(["7:0", "13:1"]),
            }
        ]

        heavier = bytearray(BITMAP_SIZE)
        heavier[7] = 1
        heavier[13] = 40
        (capture / "tracelib" / "wf-c").write_bytes(bytes(heavier))
        assert bitmap_coverage_hash(capture / "tracelib" / "wf-a", "index") == \
               bitmap_coverage_hash(capture / "tracelib" / "wf-c", "index")
        assert bitmap_coverage_hash(capture / "tracelib" / "wf-a", "bucket") != \
               bitmap_coverage_hash(capture / "tracelib" / "wf-c", "bucket")
        assert [to_bucket(n) for n in (1, 2, 3, 4, 5, 8, 9, 255, 256)] == [0, 1, 2, 2, 3, 3, 4, 8, 8]
        write_json(output, export_records(capture, "crawl", ("index",)))
        records = json.loads(output.read_text(encoding="utf-8"))
        assert "bitmap_coverage_hash_bucket" not in records[0]
        write_json(output, export_records(capture, "all"))
        records = json.loads(output.read_text(encoding="utf-8"))
        assert records[1]["code_coverage_hash"] == "abc123"
        write_json(output, export_records(capture, "fuzz"))
        records = json.loads(output.read_text(encoding="utf-8"))
        assert len(records) == 1
        assert records[0]["request"] == "POST /fuzz.php"
        assert records[0]["code_coverage_hash"] == "abc123"

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Write compact request, code-coverage hash, and TraceLib bitmap hash JSON."
    )
    parser.add_argument("capture_dir", nargs="?")
    parser.add_argument("output_json", nargs="?")
    parser.add_argument(
        "--phase", default="crawl", choices=("crawl", "fuzz", "all")
    )
    parser.add_argument(
        "--bitmap-hash",
        default="both",
        choices=("index", "bucket", "both"),
        help=(
            "which TraceLib relation to hash: 'index' = lit cells only, "
            "'bucket' = lit cells AND their hit-count buckets, "
            "'both' (default) writes bitmap_coverage_hash and "
            "bitmap_coverage_hash_bucket side by side"
        ),
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        print("export_request_feedback: self-test passed")
        return 0
    if not args.capture_dir or not args.output_json:
        parser.error("capture_dir and output_json are required unless --self-test is used")
    modes = ("index", "bucket") if args.bitmap_hash == "both" else (args.bitmap_hash,)
    write_json(
        Path(args.output_json).resolve(),
        export_records(Path(args.capture_dir).resolve(), args.phase, modes),
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
