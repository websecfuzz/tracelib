#!/usr/bin/env python3
"""Compare paired per-request reference feedback and TraceLib feedback.

The input directory is produced by evaluate_feedback_quality.sh and contains:

  ast/map.<request-id>       PHP AST edge map for one request, for PHP apps
  tracelib/<request-id>      65536-byte TraceLib bitmap for the same request
  requests.jsonl             request order and basic metadata from WebFuzz

For PHP apps, Native AST coverage is the reference and exact pairwise
equivalence metrics are computed. For non-PHP apps, the current integrations
only expose cumulative language-native line coverage during a run; the script
therefore reports sequential line-novelty agreement and marks exact pairwise
classification unsupported. When a runtime report includes a covered-code hash,
sequential novelty uses hash changes rather than only count increases.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, FrozenSet, Iterable, List, Mapping, Optional, Sequence, Tuple

BITMAP_SIZE = 65536
DEFAULT_MAX_REQUESTS = 20_000

@dataclass
class RequestFeedback:
    ordinal: int
    request_id: str
    method: str
    url: str
    http_status: Any
    ast_edges: FrozenSet[int]
    ast_edge_buckets: FrozenSet[Tuple[int, int]]
    tracelib_edges: FrozenSet[int]
    language_covered: Optional[int] = None
    language_total: Optional[int] = None
    language_pct: Optional[float] = None
    language_covered_hash: str = ""
    language_reference_error: str = ""

def select_request_prefix(
    requests: Sequence[RequestFeedback], max_requests: int
) -> List[RequestFeedback]:
    if max_requests < 0:
        raise ValueError("max_requests must be non-negative")
    if max_requests == 0:
        return list(requests)
    return list(requests[:max_requests])

def choose2(value: int) -> int:
    return value * (value - 1) // 2

def safe_div(numerator: float, denominator: float) -> Optional[float]:
    return numerator / denominator if denominator else None

def hit_bucket(hit_count: int) -> int:
    """Match webFuzz.misc.to_bucket without requiring the WebFuzz venv."""
    if hit_count <= 0:
        raise ValueError("hit count must be positive")
    return math.ceil(math.log2(hit_count)) if hit_count < 256 else 8

def parse_ast_map(path: Path) -> Tuple[FrozenSet[int], FrozenSet[Tuple[int, int]]]:
    edges = set()
    buckets = set()
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for line_number, raw in enumerate(source, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                label_text, count_text = line.rsplit("-", 1)
                label = int(label_text)
                count = int(count_text)
                if count <= 0:
                    continue
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid AST map line {line!r}") from exc
            edges.add(label)
            buckets.add((label, hit_bucket(count)))
    return frozenset(edges), frozenset(buckets)

def parse_tracelib_bitmap(path: Path) -> FrozenSet[int]:
    data = path.read_bytes()
    if len(data) < BITMAP_SIZE:
        raise ValueError(
            f"{path}: short TraceLib bitmap ({len(data)} bytes, expected {BITMAP_SIZE})"
        )
    return frozenset(index for index, value in enumerate(data[:BITMAP_SIZE]) if value)

def signature_hash(values: Iterable[Any]) -> str:
    digest = hashlib.sha256()
    for value in sorted(values):
        if isinstance(value, tuple):
            encoded = ":".join(str(part) for part in value)
        else:
            encoded = str(value)
        digest.update(encoded.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()

def read_metadata(path: Path) -> Dict[str, str]:
    result: Dict[str, str] = {}
    if not path.is_file():
        return result
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key, separator, value = raw.partition("=")
        if separator:
            result[key] = value
    return result

def read_manifest(path: Path) -> Tuple[List[Dict[str, Any]], int]:
    records: List[Dict[str, Any]] = []
    malformed = 0
    if not path.is_file():
        return records, malformed
    seen = set()
    with path.open("r", encoding="utf-8", errors="replace") as source:
        for raw in source:
            try:
                record = json.loads(raw)
                request_id = str(record["request_id"])
                if request_id in seen:
                    continue
                seen.add(request_id)
                record["request_id"] = request_id
                records.append(record)
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                malformed += 1
    records.sort(key=lambda item: (int(item.get("ordinal", 0)), int(item.get("timestamp_ns", 0))))
    return records, malformed

def parse_language_reference(record: Mapping[str, Any]) -> Tuple[Optional[int], Optional[int], Optional[float], str, str]:
    feedback = record.get("reference_feedback")
    if not isinstance(feedback, Mapping):
        return None, None, None, "", "missing"
    if "error" in feedback:
        return None, None, None, "", str(feedback.get("error", "error"))
    try:
        covered = int(feedback["covered"])
        total = int(feedback.get("total", 0))
        pct = float(feedback.get("pct", 0.0))
    except (KeyError, TypeError, ValueError) as exc:
        return None, None, None, "", f"invalid:{exc}"
    covered_hash = feedback.get("covered_hash", "")
    if covered_hash is not None and not isinstance(covered_hash, str):
        return None, None, None, "", "invalid:covered_hash"
    return covered, total, pct, covered_hash or "", ""

def load_capture(capture_dir: Path) -> Tuple[List[RequestFeedback], Dict[str, Any]]:
    metadata = read_metadata(capture_dir / "metadata.env")
    reference_kind = metadata.get("reference_kind", "php_ast")
    is_php_reference = reference_kind == "php_ast"

    ast_dir = capture_dir / "ast"
    tracelib_dir = capture_dir / "tracelib"
    if is_php_reference and not ast_dir.is_dir():
        raise ValueError(f"AST directory not found: {ast_dir}")
    if not tracelib_dir.is_dir():
        raise ValueError(f"TraceLib directory not found: {tracelib_dir}")

    ast_files = {}
    if ast_dir.is_dir():
        ast_files = {
            path.name[len("map."):]: path
            for path in ast_dir.glob("map.wf-*")
            if path.is_file()
        }
    tracelib_files = {
        path.name: path
        for path in tracelib_dir.glob("wf-*")
        if path.is_file()
    }
    manifest, malformed_manifest_lines = read_manifest(capture_dir / "requests.jsonl")

    if manifest:
        ordered_metadata = manifest
    else:
        all_ids = set(ast_files) | set(tracelib_files)
        ordered_ids = sorted(
            all_ids,
            key=lambda rid: (
                ast_files.get(rid, tracelib_files.get(rid)).stat().st_mtime_ns,
                rid,
            ),
        )
        ordered_metadata = [
            {"request_id": rid, "ordinal": index + 1, "method": "", "url": ""}
            for index, rid in enumerate(ordered_ids)
        ]

    paired: List[RequestFeedback] = []
    missing_ast = []
    missing_tracelib = []
    invalid_ast: Dict[str, str] = {}
    invalid_tracelib: Dict[str, str] = {}
    invalid_language_reference: Dict[str, str] = {}

    for position, record in enumerate(ordered_metadata, 1):
        request_id = str(record["request_id"])
        ast_path = ast_files.get(request_id)
        tracelib_path = tracelib_files.get(request_id)
        if is_php_reference and ast_path is None:
            missing_ast.append(request_id)
            continue
        if tracelib_path is None:
            missing_tracelib.append(request_id)
            continue

        ast_edges: FrozenSet[int] = frozenset()
        ast_edge_buckets: FrozenSet[Tuple[int, int]] = frozenset()
        language_covered: Optional[int] = None
        language_total: Optional[int] = None
        language_pct: Optional[float] = None
        language_covered_hash = ""
        language_error = ""

        if is_php_reference:
            try:
                ast_edges, ast_edge_buckets = parse_ast_map(ast_path)
            except ValueError as exc:
                invalid_ast[request_id] = str(exc)
                continue
        else:
            (
                language_covered,
                language_total,
                language_pct,
                language_covered_hash,
                language_error,
            ) = parse_language_reference(record)
            if language_error:
                invalid_language_reference[request_id] = language_error
                continue

        try:
            tracelib_edges = parse_tracelib_bitmap(tracelib_path)
        except ValueError as exc:
            invalid_tracelib[request_id] = str(exc)
            continue

        paired.append(
            RequestFeedback(
                ordinal=int(record.get("ordinal", position)),
                request_id=request_id,
                method=str(record.get("method", "")),
                url=str(record.get("url", "")),
                http_status=record.get("http_status", ""),
                ast_edges=ast_edges,
                ast_edge_buckets=ast_edge_buckets,
                tracelib_edges=tracelib_edges,
                language_covered=language_covered,
                language_total=language_total,
                language_pct=language_pct,
                language_covered_hash=language_covered_hash,
                language_reference_error=language_error,
            )
        )

    manifest_ids = {str(record["request_id"]) for record in manifest}
    diagnostics = {
        "reference_kind": reference_kind,
        "manifest_present": bool(manifest),
        "manifest_requests": len(manifest),
        "malformed_manifest_lines": malformed_manifest_lines,
        "ast_files": len(ast_files),
        "tracelib_files": len(tracelib_files),
        "paired_requests": len(paired),
        "pairing_rate": safe_div(len(paired), len(manifest)) if manifest else None,
        "missing_ast_count": len(missing_ast),
        "missing_tracelib_count": len(missing_tracelib),
        "invalid_ast_count": len(invalid_ast),
        "invalid_tracelib_count": len(invalid_tracelib),
        "invalid_language_reference_count": len(invalid_language_reference),
        "zero_ast_requests": sum(not request.ast_edges for request in paired),
        "zero_tracelib_requests": sum(not request.tracelib_edges for request in paired),
        "orphan_ast_files": len(set(ast_files) - manifest_ids) if manifest else 0,
        "orphan_tracelib_files": len(set(tracelib_files) - manifest_ids) if manifest else 0,
        "missing_ast_examples": missing_ast[:20],
        "missing_tracelib_examples": missing_tracelib[:20],
        "invalid_ast_examples": dict(list(invalid_ast.items())[:5]),
        "invalid_tracelib_examples": dict(list(invalid_tracelib.items())[:5]),
        "invalid_language_reference_examples": dict(list(invalid_language_reference.items())[:5]),
    }
    return paired, diagnostics

def confusion_metrics(tp: int, tn: int, fp: int, fn: int) -> Dict[str, Any]:
    total = tp + tn + fp + fn
    precision = safe_div(tp, tp + fp)
    recall = safe_div(tp, tp + fn)
    f1 = None if precision is None or recall is None or not (precision + recall) \
        else 2 * precision * recall / (precision + recall)
    specificity = safe_div(tn, tn + fp)
    recalls = [value for value in (recall, specificity) if value is not None]
    return {
        "true_positive": tp,
        "true_negative": tn,
        "false_positive": fp,
        "false_negative": fn,
        "total": total,
        "accuracy": safe_div(tp + tn, total),
        "precision": precision,
        "recall": recall,
        "specificity": specificity,
        "balanced_accuracy": sum(recalls) / len(recalls) if recalls else None,
        "f1": f1,
    }

def pairwise_metrics(reference: Sequence[FrozenSet[Any]],
                     predicted: Sequence[FrozenSet[Any]]) -> Dict[str, Any]:
    """Compare two equivalence partitions without enumerating O(n^2) pairs."""
    if len(reference) != len(predicted):
        raise ValueError("reference and predicted sequences have different lengths")
    count_reference = Counter(reference)
    count_predicted = Counter(predicted)
    count_joint = Counter(zip(reference, predicted))

    total_pairs = choose2(len(reference))
    same_reference = sum(choose2(count) for count in count_reference.values())
    same_predicted = sum(choose2(count) for count in count_predicted.values())
    same_both = sum(choose2(count) for count in count_joint.values())

    tn = same_both
    fp = same_reference - same_both
    fn = same_predicted - same_both
    tp = total_pairs - tn - fp - fn
    result = confusion_metrics(tp, tn, fp, fn)
    result.update(
        {
            "pairs": total_pairs,
            "reference_same_pairs": same_reference,
            "reference_different_pairs": total_pairs - same_reference,
            "ast_same_pairs": same_reference,
            "ast_different_pairs": total_pairs - same_reference,
            "tracelib_same_pairs": same_predicted,
            "tracelib_different_pairs": total_pairs - same_predicted,
            "false_merge_count": fn,
            "false_split_count": fp,
            "false_merge_rate": safe_div(fn, total_pairs - same_reference),
            "false_split_rate": safe_div(fp, same_reference),
            "different_coverage_recall": safe_div(tp, tp + fn),
            "same_coverage_consistency": safe_div(tn, tn + fp),
            "reference_equivalence_classes": len(count_reference),
            "ast_equivalence_classes": len(count_reference),
            "tracelib_equivalence_classes": len(count_predicted),
        }
    )

    if total_pairs == 0:
        adjusted_rand = None
    else:
        expected = same_reference * same_predicted / total_pairs
        maximum = 0.5 * (same_reference + same_predicted)
        denominator = maximum - expected
        if denominator:
            adjusted_rand = (same_both - expected) / denominator
        else:
            adjusted_rand = 1.0 if fp == 0 and fn == 0 else 0.0
    result["adjusted_rand_index"] = adjusted_rand
    return result

def sequential_metrics(reference: Sequence[FrozenSet[Any]],
                       predicted: Sequence[FrozenSet[Any]]) -> Tuple[Dict[str, Any], List[Tuple[bool, bool, str]]]:
    """Compare global-new-item decisions in a fixed request order."""
    seen_reference = set()
    seen_predicted = set()
    outcomes: List[Tuple[bool, bool, str]] = []
    tp = tn = fp = fn = 0
    for reference_signal, predicted_signal in zip(reference, predicted):
        reference_unique = bool(reference_signal - seen_reference)
        predicted_unique = bool(predicted_signal - seen_predicted)
        seen_reference.update(reference_signal)
        seen_predicted.update(predicted_signal)
        if reference_unique and predicted_unique:
            tp += 1
            outcome = "TP"
        elif not reference_unique and not predicted_unique:
            tn += 1
            outcome = "TN"
        elif not reference_unique and predicted_unique:
            fp += 1
            outcome = "FP"
        else:
            fn += 1
            outcome = "FN"
        outcomes.append((reference_unique, predicted_unique, outcome))
    result = confusion_metrics(tp, tn, fp, fn)
    result.update(
        {
            "reference_unique_requests": tp + fn,
            "ast_unique_requests": tp + fn,
            "tracelib_unique_requests": tp + fp,
            "missed_reference_unique_requests": fn,
            "missed_ast_unique_requests": fn,
            "extra_tracelib_unique_requests": fp,
        }
    )
    return result, outcomes

def sequential_cumulative_count_metrics(counts: Sequence[int],
                                        predicted: Sequence[FrozenSet[Any]]) -> Tuple[Dict[str, Any], List[Tuple[bool, bool, str]]]:
    """Sequential novelty for cumulative counters without materializing line sets."""
    seen_predicted = set()
    previous_count = 0
    outcomes: List[Tuple[bool, bool, str]] = []
    tp = tn = fp = fn = 0
    for count, predicted_signal in zip(counts, predicted):
        if count < previous_count:
            count = previous_count
        reference_unique = count > previous_count
        previous_count = count
        predicted_unique = bool(predicted_signal - seen_predicted)
        seen_predicted.update(predicted_signal)
        if reference_unique and predicted_unique:
            tp += 1
            outcome = "TP"
        elif not reference_unique and not predicted_unique:
            tn += 1
            outcome = "TN"
        elif not reference_unique and predicted_unique:
            fp += 1
            outcome = "FP"
        else:
            fn += 1
            outcome = "FN"
        outcomes.append((reference_unique, predicted_unique, outcome))
    result = confusion_metrics(tp, tn, fp, fn)
    result.update(
        {
            "reference_unique_requests": tp + fn,
            "ast_unique_requests": tp + fn,
            "tracelib_unique_requests": tp + fp,
            "missed_reference_unique_requests": fn,
            "missed_ast_unique_requests": fn,
            "extra_tracelib_unique_requests": fp,
        }
    )
    return result, outcomes

def sequential_cumulative_signature_metrics(signatures: Sequence[str],
                                            predicted: Sequence[FrozenSet[Any]]) -> Tuple[Dict[str, Any], List[Tuple[bool, bool, str]]]:
    """Sequential novelty for cumulative covered-code signatures."""
    seen_predicted = set()
    previous_signature = ""
    outcomes: List[Tuple[bool, bool, str]] = []
    tp = tn = fp = fn = 0
    for signature, predicted_signal in zip(signatures, predicted):
        reference_unique = bool(signature) and signature != previous_signature
        if signature:
            previous_signature = signature
        predicted_unique = bool(predicted_signal - seen_predicted)
        seen_predicted.update(predicted_signal)
        if reference_unique and predicted_unique:
            tp += 1
            outcome = "TP"
        elif not reference_unique and not predicted_unique:
            tn += 1
            outcome = "TN"
        elif not reference_unique and predicted_unique:
            fp += 1
            outcome = "FP"
        else:
            fn += 1
            outcome = "FN"
        outcomes.append((reference_unique, predicted_unique, outcome))
    result = confusion_metrics(tp, tn, fp, fn)
    result.update(
        {
            "reference_unique_requests": tp + fn,
            "ast_unique_requests": tp + fn,
            "tracelib_unique_requests": tp + fp,
            "missed_reference_unique_requests": fn,
            "missed_ast_unique_requests": fn,
            "extra_tracelib_unique_requests": fp,
        }
    )
    return result, outcomes

def disagreement_examples(requests: Sequence[RequestFeedback],
                          reference_attr: str,
                          profile: str,
                          maximum: int) -> List[Dict[str, Any]]:
    examples: List[Dict[str, Any]] = []

    def add_examples(primary_attr: str, secondary_attr: str, kind: str) -> None:
        groups: Dict[Any, Dict[Any, List[RequestFeedback]]] = defaultdict(lambda: defaultdict(list))
        for request in requests:
            groups[getattr(request, primary_attr)][getattr(request, secondary_attr)].append(request)
        for subgroups in groups.values():
            if len(subgroups) < 2 or len(examples) >= maximum:
                continue
            representatives = [members[0] for members in subgroups.values()]
            first, second = representatives[0], representatives[1]
            examples.append(
                {
                    "profile": profile,
                    "type": kind,
                    "request_a": first.request_id,
                    "request_b": second.request_id,
                    "method_a": first.method,
                    "method_b": second.method,
                    "url_a": first.url,
                    "url_b": second.url,
                    "ast_edges_a": len(first.ast_edges),
                    "ast_edges_b": len(second.ast_edges),
                    "tracelib_edges_a": len(first.tracelib_edges),
                    "tracelib_edges_b": len(second.tracelib_edges),
                }
            )

    add_examples(reference_attr, "tracelib_edges", "false_split")
    add_examples("tracelib_edges", reference_attr, "false_merge")
    return examples[:maximum]

def percent(value: Optional[float]) -> str:
    return "N/A" if value is None else f"{100.0 * value:.2f}%"

def build_profiles(requests: Sequence[RequestFeedback],
                   reference_kind: str) -> Tuple[Dict[str, Dict[str, Any]], str, str, str]:
    tracelib_edges = [request.tracelib_edges for request in requests]
    if reference_kind == "php_ast":
        profiles: Dict[str, Dict[str, Any]] = {}
        for name, description, reference, reference_attr in (
            (
                "edge_set",
                "AST edge presence versus TraceLib non-zero bitmap indexes",
                [request.ast_edges for request in requests],
                "ast_edges",
            ),
            (
                "feedback_policy",
                "Native AST edge+hit-count buckets versus TraceLib index presence",
                [request.ast_edge_buckets for request in requests],
                "ast_edge_buckets",
            ),
        ):
            sequential, outcomes = sequential_metrics(reference, tracelib_edges)
            profiles[name] = {
                "description": description,
                "pairwise": pairwise_metrics(reference, tracelib_edges),
                "pairwise_supported": True,
                "sequential_novelty": sequential,
                "_outcomes": outcomes,
                "_reference_attr": reference_attr,
            }
        return profiles, "Native PHP AST feedback", "AST unique", "Missed AST-unique"

    signatures = [request.language_covered_hash for request in requests]
    if reference_kind == "language_line_set" and any(signatures):
        reference = [
            frozenset([signature]) if signature else frozenset()
            for signature in signatures
        ]
        sequential, outcomes = sequential_metrics(reference, tracelib_edges)
        profiles = {
            "language_line_set": {
                "description": "Reset per-request language-native covered-code hash versus TraceLib non-zero bitmap indexes",
                "pairwise": pairwise_metrics(reference, tracelib_edges),
                "pairwise_supported": True,
                "sequential_novelty": sequential,
                "_outcomes": outcomes,
                "_reference_attr": "language_covered_hash",
            }
        }
        return profiles, "Reset per-request language-native covered-code hash", "Language-line-set unique", "Missed language-line-set unique"

    if any(signatures):
        sequential, outcomes = sequential_cumulative_signature_metrics(signatures, tracelib_edges)
        description = "Cumulative language-native covered-code hash versus TraceLib non-zero bitmap indexes"
        reference_name = "Cumulative language-native covered-code hash"
    else:
        counts = [request.language_covered or 0 for request in requests]
        sequential, outcomes = sequential_cumulative_count_metrics(counts, tracelib_edges)
        description = "Cumulative language-native line coverage versus TraceLib non-zero bitmap indexes"
        reference_name = "Cumulative language-native line coverage"
    profiles = {
        "language_line_union": {
            "description": description,
            "pairwise": None,
            "pairwise_supported": False,
            "sequential_novelty": sequential,
            "_outcomes": outcomes,
            "_reference_attr": "",
        }
    }
    return profiles, reference_name, "Language-line unique", "Missed language-line unique"

def write_outputs(capture_dir: Path,
                  output_dir: Path,
                  requests: Sequence[RequestFeedback],
                  diagnostics: Mapping[str, Any],
                  maximum_examples: int) -> Dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    metadata = read_metadata(capture_dir / "metadata.env")
    reference_kind = metadata.get("reference_kind", str(diagnostics.get("reference_kind", "php_ast")))
    profiles, reference_name, reference_unique_label, missed_label = build_profiles(requests, reference_kind)

    examples: List[Dict[str, Any]] = []
    for name, profile in profiles.items():
        if profile["pairwise_supported"]:
            examples.extend(
                disagreement_examples(
                    requests,
                    profile["_reference_attr"],
                    name,
                    maximum_examples - len(examples),
                )
            )

    result_profiles = {
        name: {
            key: value
            for key, value in profile.items()
            if not key.startswith("_")
        }
        for name, profile in profiles.items()
    }
    result: Dict[str, Any] = {
        "schema_version": 2,
        "reference": reference_name,
        "capture_directory": str(capture_dir.resolve()),
        "metadata": metadata,
        "diagnostics": dict(diagnostics),
        "profiles": result_profiles,
    }

    (output_dir / "feedback_quality.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    with (output_dir / "per_request.csv").open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output)
        writer.writerow(
            [
                "ordinal", "request_id", "method", "url", "http_status",
                "reference_kind", "ast_edges", "ast_edge_buckets",
                "language_covered", "language_total", "language_pct",
                "language_covered_hash", "language_new_covered_lines", "tracelib_edges",
                "ast_edge_signature", "ast_bucket_signature", "tracelib_signature",
                "edge_set_ast_unique", "edge_set_tracelib_unique", "edge_set_outcome",
                "policy_ast_unique", "policy_tracelib_unique", "policy_outcome",
                "language_line_unique", "language_tracelib_unique", "language_outcome",
            ]
        )

        def outcome_value(profile_name: str, index: int) -> Tuple[str, str, str]:
            if profile_name not in profiles:
                return "", "", ""
            outcome = profiles[profile_name]["_outcomes"][index]
            return str(outcome[0]).lower(), str(outcome[1]).lower(), outcome[2]

        previous_language_covered = 0
        previous_language_hash = ""
        language_profile_name = "language_line_set" if "language_line_set" in profiles else "language_line_union"
        for index, request in enumerate(requests):
            edge_outcome = outcome_value("edge_set", index)
            policy_outcome = outcome_value("feedback_policy", index)
            language_outcome = outcome_value(language_profile_name, index)
            language_new = ""
            if request.language_covered is not None:
                language_new = str(max(0, request.language_covered - previous_language_covered))
                previous_language_covered = max(previous_language_covered, request.language_covered)
            if request.language_covered_hash:
                language_new = "hash_changed" if request.language_covered_hash != previous_language_hash else "0"
                previous_language_hash = request.language_covered_hash
            writer.writerow(
                [
                    request.ordinal,
                    request.request_id,
                    request.method,
                    request.url,
                    request.http_status,
                    reference_kind,
                    len(request.ast_edges),
                    len(request.ast_edge_buckets),
                    "" if request.language_covered is None else request.language_covered,
                    "" if request.language_total is None else request.language_total,
                    "" if request.language_pct is None else request.language_pct,
                    request.language_covered_hash,
                    language_new,
                    len(request.tracelib_edges),
                    signature_hash(request.ast_edges),
                    signature_hash(request.ast_edge_buckets),
                    signature_hash(request.tracelib_edges),
                    edge_outcome[0],
                    edge_outcome[1],
                    edge_outcome[2],
                    policy_outcome[0],
                    policy_outcome[1],
                    policy_outcome[2],
                    language_outcome[0],
                    language_outcome[1],
                    language_outcome[2],
                ]
            )

    example_fields = [
        "profile", "type", "request_a", "request_b", "method_a", "method_b",
        "url_a", "url_b", "ast_edges_a", "ast_edges_b",
        "tracelib_edges_a", "tracelib_edges_b",
    ]
    with (output_dir / "pair_disagreements.csv").open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=example_fields)
        writer.writeheader()
        writer.writerows(examples)

    available_paired = int(diagnostics.get("available_paired_requests", len(requests)))
    request_limit = int(diagnostics.get("analysis_request_limit", 0))
    limit_text = "unlimited" if request_limit == 0 else str(request_limit)
    lines = [
        "# Per-request feedback quality",
        "",
        f"Application: `{metadata.get('app', 'unknown')}`  ",
        f"TraceLib mode: `{metadata.get('tracelib_coverage_mode', metadata.get('mode', 'unknown'))}`  ",
        f"Reference: `{reference_name}`  ",
        f"Analyzed paired requests: **{len(requests)}** / {available_paired} available "
        f"(limit: {limit_text})  ",
        f"Captured request manifest entries: "
        f"{diagnostics['manifest_requests'] or max(diagnostics['ast_files'], diagnostics['tracelib_files'])}",
        "",
        "## Pairwise classification",
        "",
    ]
    if reference_kind == "php_ast":
        lines.extend(
            [
                "A pair is positive when Native AST says its two requests have different coverage. "
                "A false merge means TraceLib collapses a reference-different pair; a false split means "
                "TraceLib separates a reference-identical pair.",
                "",
                "| Profile | Agreement | Different-coverage recall | Same-coverage consistency | False-merge rate | False-split rate | ARI |",
                "|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for name in ("edge_set", "feedback_policy"):
            metrics = profiles[name]["pairwise"]
            ari = metrics["adjusted_rand_index"]
            lines.append(
                f"| {name} | {percent(metrics['accuracy'])} | "
                f"{percent(metrics['different_coverage_recall'])} | "
                f"{percent(metrics['same_coverage_consistency'])} | "
                f"{percent(metrics['false_merge_rate'])} | "
                f"{percent(metrics['false_split_rate'])} | "
                f"{'N/A' if ari is None else f'{ari:.4f}'} |"
            )
    else:
        lines.append(
            "Exact pairwise classification is not reported for this app. "
            "The current non-PHP integrations expose cumulative language-line coverage, "
            "not the exact set of lines executed by each individual request."
        )

    lines.extend(
        [
            "",
            "## Sequential corpus-novelty classification",
            "",
            f"| Profile | Agreement | {reference_unique_label} | TraceLib unique | {missed_label} | Extra TraceLib-unique |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for name, profile in profiles.items():
        metrics = profile["sequential_novelty"]
        lines.append(
            f"| {name} | {percent(metrics['accuracy'])} | "
            f"{metrics['reference_unique_requests']} | {metrics['tracelib_unique_requests']} | "
            f"{metrics['missed_reference_unique_requests']} | {metrics['extra_tracelib_unique_requests']} |"
        )

    lines.extend(
        [
            "",
            "## Capture diagnostics",
            "",
            f"- Missing AST maps: {diagnostics['missing_ast_count']}",
            f"- Missing TraceLib bitmaps: {diagnostics['missing_tracelib_count']}",
            f"- Invalid AST maps: {diagnostics['invalid_ast_count']}",
            f"- Invalid TraceLib bitmaps: {diagnostics['invalid_tracelib_count']}",
            f"- Invalid language-reference samples: {diagnostics['invalid_language_reference_count']}",
            f"- Zero-edge AST requests: {diagnostics['zero_ast_requests']}",
            f"- Zero-edge TraceLib requests: {diagnostics['zero_tracelib_requests']}",
            "",
        ]
    )
    if reference_kind == "php_ast":
        lines.extend(
            [
                "The `edge_set` row is the primary answer to the coverage-equivalence question. "
                "The `feedback_policy` row additionally includes Native's hit-count buckets, "
                "matching the current WebFuzz corpus policy more closely.",
                "",
            ]
        )
    else:
        lines.extend(
            (
                [
                    "For non-PHP reset captures, `language_line_set` compares the "
                    "platform per-request covered-code hash against TraceLib's "
                    "per-request bitmap hash.",
                    "",
                ]
                if reference_kind == "language_line_set"
                else [
                    "For non-PHP cumulative captures, `language_line_union` answers a weaker question: "
                    "when the language-native cumulative covered-code hash changes "
                    "(or, for runtimes without that hash, when the line counter grows), does TraceLib "
                    "also mark the request as novel?",
                    "",
                ]
            )
        )
    (output_dir / "feedback_quality_summary.md").write_text("\n".join(lines), encoding="utf-8")
    return result

def create_bitmap(path: Path, indexes: Iterable[int]) -> None:
    data = bytearray(BITMAP_SIZE)
    for index in indexes:
        data[index] = 1
    path.write_bytes(data)

def aggregate_outputs(root: Path) -> None:
    result_files = sorted(root.glob("*/feedback_quality.json"))
    if not result_files:
        raise ValueError(f"no per-application feedback_quality.json files found under {root}")

    rows: List[Dict[str, Any]] = []
    pooled: Dict[str, Dict[str, Counter]] = defaultdict(
        lambda: {"pairwise": Counter(), "sequential_novelty": Counter()}
    )
    for result_file in result_files:
        result = json.loads(result_file.read_text(encoding="utf-8"))
        app = result.get("metadata", {}).get("app", result_file.parent.name)
        reference = result.get("reference", "")
        result_diagnostics = result.get("diagnostics", {})
        paired = result_diagnostics.get(
            "analyzed_paired_requests", result_diagnostics.get("paired_requests", 0)
        )
        for profile, profile_data in result["profiles"].items():
            pairwise = profile_data.get("pairwise")
            sequential = profile_data["sequential_novelty"]
            rows.append(
                {
                    "app": app,
                    "profile": profile,
                    "reference": reference,
                    "paired_requests": paired,
                    "pairwise_supported": bool(pairwise),
                    "pairwise_agreement": None if pairwise is None else pairwise["accuracy"],
                    "different_coverage_recall": None if pairwise is None else pairwise["different_coverage_recall"],
                    "same_coverage_consistency": None if pairwise is None else pairwise["same_coverage_consistency"],
                    "false_merge_rate": None if pairwise is None else pairwise["false_merge_rate"],
                    "false_split_rate": None if pairwise is None else pairwise["false_split_rate"],
                    "adjusted_rand_index": None if pairwise is None else pairwise["adjusted_rand_index"],
                    "sequential_agreement": sequential["accuracy"],
                    "reference_unique_requests": sequential["reference_unique_requests"],
                    "tracelib_unique_requests": sequential["tracelib_unique_requests"],
                }
            )
            if pairwise is not None:
                for key in ("true_positive", "true_negative", "false_positive", "false_negative"):
                    pooled[profile]["pairwise"][key] += int(pairwise[key])
            for key in ("true_positive", "true_negative", "false_positive", "false_negative"):
                pooled[profile]["sequential_novelty"][key] += int(sequential[key])

    csv_path = root / "aggregate_feedback_quality.csv"
    fields = list(rows[0].keys())
    with csv_path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    lines = [
        "# Feedback quality across previous applications",
        "",
        "Pairwise metrics are computed within each application when an exact per-request "
        "reference exists. Non-PHP rows use cumulative language-line novelty and do not "
        "claim exact pairwise equivalence.",
        "",
        "| Application | Profile | Paired requests | Pairwise agreement | False-merge rate | False-split rate | Sequential agreement |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['app']} | {row['profile']} | {row['paired_requests']} | "
            f"{percent(row['pairwise_agreement'])} | {percent(row['false_merge_rate'])} | "
            f"{percent(row['false_split_rate'])} | {percent(row['sequential_agreement'])} |"
        )
    lines.extend(
        [
            "",
            "## Pooled within-application confusion counts",
            "",
            "| Profile | Pairwise agreement | False-merge rate | False-split rate | Sequential agreement |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    for profile in sorted(pooled):
        pair_counts = pooled[profile]["pairwise"]
        seq_counts = pooled[profile]["sequential_novelty"]
        pair_metrics = None
        false_merge_rate = None
        false_split_rate = None
        if sum(pair_counts.values()):
            pair_metrics = confusion_metrics(
                pair_counts["true_positive"], pair_counts["true_negative"],
                pair_counts["false_positive"], pair_counts["false_negative"],
            )
            false_merge_rate = safe_div(
                pair_counts["false_negative"],
                pair_counts["true_positive"] + pair_counts["false_negative"],
            )
            false_split_rate = safe_div(
                pair_counts["false_positive"],
                pair_counts["true_negative"] + pair_counts["false_positive"],
            )
        seq_metrics = confusion_metrics(
            seq_counts["true_positive"], seq_counts["true_negative"],
            seq_counts["false_positive"], seq_counts["false_negative"],
        )
        lines.append(
            f"| {profile} | {percent(None if pair_metrics is None else pair_metrics['accuracy'])} | "
            f"{percent(false_merge_rate)} | {percent(false_split_rate)} | "
            f"{percent(seq_metrics['accuracy'])} |"
        )
    (root / "aggregate_feedback_quality_summary.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )
    print(f"analyze_feedback_quality: aggregated {len(result_files)} applications under {root}")

def self_test() -> None:
    reference = [frozenset({1}), frozenset({1}), frozenset({2})]
    predicted = [frozenset({10}), frozenset({11}), frozenset({10})]
    metrics = pairwise_metrics(reference, predicted)
    assert metrics["true_positive"] == 1
    assert metrics["false_split_count"] == 1
    assert metrics["false_merge_count"] == 1

    with tempfile.TemporaryDirectory(prefix="feedback-quality-test-") as temporary:
        root = Path(temporary)
        php_root = root / "php"
        php_root.mkdir()
        (php_root / "ast").mkdir()
        (php_root / "tracelib").mkdir()
        (php_root / "metadata.env").write_text("app=wordpress\nreference_kind=php_ast\n", encoding="utf-8")
        (php_root / "ast" / "map.wf-a").write_text("1-1\n", encoding="utf-8")
        (php_root / "ast" / "map.wf-b").write_text("1-2\n", encoding="utf-8")
        create_bitmap(php_root / "tracelib" / "wf-a", [10])
        create_bitmap(php_root / "tracelib" / "wf-b", [11])
        php_manifest = [
            {"ordinal": 1, "request_id": "wf-a", "method": "GET", "url": "/a"},
            {"ordinal": 2, "request_id": "wf-b", "method": "GET", "url": "/b"},
        ]
        (php_root / "requests.jsonl").write_text(
            "".join(json.dumps(record) + "\n" for record in php_manifest), encoding="utf-8"
        )
        requests, diagnostics = load_capture(php_root)
        assert len(requests) == 2
        assert len(select_request_prefix(requests, 1)) == 1
        assert select_request_prefix(requests, 0) == requests
        result = write_outputs(php_root, php_root, requests, diagnostics, 10)
        assert result["profiles"]["edge_set"]["pairwise"]["false_split_count"] == 1
        assert result["profiles"]["feedback_policy"]["pairwise"]["false_split_count"] == 0

        nonphp_root = root / "ghost"
        nonphp_root.mkdir()
        (nonphp_root / "tracelib").mkdir()
        (nonphp_root / "metadata.env").write_text(
            "app=ghost\nruntime=node\nreference_kind=language_line_union\n", encoding="utf-8"
        )
        create_bitmap(nonphp_root / "tracelib" / "wf-c", [20])
        create_bitmap(nonphp_root / "tracelib" / "wf-d", [20])
        create_bitmap(nonphp_root / "tracelib" / "wf-e", [21])
        nonphp_manifest = [
            {
                "ordinal": 1, "request_id": "wf-c", "method": "GET", "url": "/c",
                "reference_feedback": {
                    "reference_kind": "language_line_union",
                    "covered": 1,
                    "total": 5,
                    "pct": 20.0,
                    "covered_hash": "hash-a",
                },
            },
            {
                "ordinal": 2, "request_id": "wf-d", "method": "GET", "url": "/d",
                "reference_feedback": {
                    "reference_kind": "language_line_union",
                    "covered": 1,
                    "total": 5,
                    "pct": 20.0,
                    "covered_hash": "hash-a",
                },
            },
            {
                "ordinal": 3, "request_id": "wf-e", "method": "GET", "url": "/e",
                "reference_feedback": {
                    "reference_kind": "language_line_union",
                    "covered": 1,
                    "total": 5,
                    "pct": 20.0,
                    "covered_hash": "hash-b",
                },
            },
        ]
        (nonphp_root / "requests.jsonl").write_text(
            "".join(json.dumps(record) + "\n" for record in nonphp_manifest), encoding="utf-8"
        )
        requests, diagnostics = load_capture(nonphp_root)
        result = write_outputs(nonphp_root, nonphp_root, requests, diagnostics, 10)
        assert result["profiles"]["language_line_union"]["pairwise"] is None
        assert result["profiles"]["language_line_union"]["sequential_novelty"]["accuracy"] == 1.0

        aggregate_outputs(root)
        assert (root / "aggregate_feedback_quality.csv").is_file()
        assert (root / "aggregate_feedback_quality_summary.md").is_file()

    print("analyze_feedback_quality: self-test passed")

def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare paired per-request reference feedback and TraceLib feedback."
    )
    parser.add_argument("capture_dir", nargs="?", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--max-examples", type=int, default=100)
    parser.add_argument(
        "--max-requests",
        type=int,
        default=DEFAULT_MAX_REQUESTS,
        metavar="N",
        help=(
            f"analyze only the first N paired requests (default: {DEFAULT_MAX_REQUESTS}; "
            "0 means unlimited)"
        ),
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--aggregate", type=Path, metavar="RUN_DIRECTORY")
    args = parser.parse_args(argv)
    selected_modes = int(args.self_test) + int(args.aggregate is not None) + int(args.capture_dir is not None)
    if selected_modes != 1:
        parser.error("choose exactly one of capture_dir, --aggregate, or --self-test")
    if args.max_examples < 0:
        parser.error("--max-examples must be non-negative")
    if args.max_requests < 0:
        parser.error("--max-requests must be non-negative")
    return args

def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.aggregate is not None:
        try:
            aggregate_outputs(args.aggregate.resolve())
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
            print(f"analyze_feedback_quality: {exc}", file=sys.stderr)
            return 1
        return 0

    capture_dir = args.capture_dir.resolve()
    output_dir = (args.output_dir or capture_dir).resolve()
    try:
        available_requests, diagnostics = load_capture(capture_dir)
        if not available_requests:
            raise ValueError("no valid paired requests were found")
        requests = select_request_prefix(available_requests, args.max_requests)
        diagnostics = dict(diagnostics)
        diagnostics["available_paired_requests"] = len(available_requests)
        diagnostics["analyzed_paired_requests"] = len(requests)
        diagnostics["analysis_request_limit"] = args.max_requests
        diagnostics["truncated_paired_requests"] = len(available_requests) - len(requests)
        result = write_outputs(capture_dir, output_dir, requests, diagnostics, args.max_examples)
    except (OSError, ValueError) as exc:
        print(f"analyze_feedback_quality: {exc}", file=sys.stderr)
        return 1

    profile_name = "edge_set" if "edge_set" in result["profiles"] else next(iter(result["profiles"]))
    profile = result["profiles"][profile_name]
    sequential = profile["sequential_novelty"]
    limit_text = "unlimited" if args.max_requests == 0 else str(args.max_requests)
    print(
        "analyze_feedback_quality: paired requests available={} analyzed={} limit={}".format(
            diagnostics["available_paired_requests"],
            diagnostics["analyzed_paired_requests"],
            limit_text,
        )
    )
    if profile.get("pairwise") is None:
        print(f"analyze_feedback_quality: pairwise classification unsupported for {profile_name}")
    else:
        pairwise = profile["pairwise"]
        print(
            "analyze_feedback_quality: pairwise agreement={} false-merge={} false-split={}".format(
                percent(pairwise["accuracy"]),
                percent(pairwise["false_merge_rate"]),
                percent(pairwise["false_split_rate"]),
            )
        )
    print(
        "analyze_feedback_quality: sequential novelty agreement={}".format(
            percent(sequential["accuracy"])
        )
    )
    print(f"analyze_feedback_quality: wrote {output_dir / 'feedback_quality_summary.md'}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
