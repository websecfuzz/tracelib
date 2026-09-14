#!/usr/bin/env python3
"""Compare compact request-feedback hashes pairwise."""
from __future__ import annotations

import argparse
import csv
import json
import math
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

DEFAULT_MAX_REQUESTS = 20_000

@dataclass(frozen=True)
class RequestRecord:
    ordinal: int
    request: str
    code_hash: Optional[str]
    bitmap_hash: Optional[str]

    @property
    def complete(self) -> bool:
        return bool(self.code_hash) and bool(self.bitmap_hash)

def choose2(value: int) -> int:
    return value * (value - 1) // 2

def percent(value: Optional[float]) -> str:
    return "N/A" if value is None else f"{100.0 * value:.2f}%"

def safe_div(numerator: int, denominator: int) -> Optional[float]:
    return numerator / denominator if denominator else None

BITMAP_HASH_FIELDS = {
    "index": "bitmap_coverage_hash",
    "bucket": "bitmap_coverage_hash_bucket",
}

def load_records(path: Path, bitmap_hash: str = "index") -> List[RequestRecord]:
    """Load the capture, taking the TraceLib relation from one of two fields.

    bitmap_hash="index"   bitmap_coverage_hash        — lit cells only
    bitmap_hash="bucket"  bitmap_coverage_hash_bucket — lit cells + hit-count bucket

    A capture written before the two-field exporter only carries the index field;
    asking for "bucket" on such a file is an error rather than a silent fallback,
    because scoring an index-only relation as if it were the bucket relation
    would misreport which rule was measured.
    """
    field = BITMAP_HASH_FIELDS.get(bitmap_hash)
    if field is None:
        raise ValueError(f"unknown bitmap hash relation: {bitmap_hash}")
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError(f"{path}: expected a JSON array")
    if raw and isinstance(raw[0], Mapping) and field not in raw[0]:
        raise ValueError(
            f"{path}: no '{field}' field; this capture does not carry the "
            f"'{bitmap_hash}' relation (re-export with --bitmap-hash {bitmap_hash})"
        )
    records: List[RequestRecord] = []
    for index, item in enumerate(raw, 1):
        if not isinstance(item, Mapping):
            raise ValueError(f"{path}: item {index} is not an object")
        request = str(item.get("request", ""))
        records.append(
            RequestRecord(
                ordinal=index,
                request=request,
                code_hash=item.get("code_coverage_hash"),
                bitmap_hash=item.get(field),
            )
        )
    return records

def select_records(records: Sequence[RequestRecord], max_requests: int) -> List[RequestRecord]:
    if max_requests < 0:
        raise ValueError("max_requests must be non-negative")
    if max_requests == 0:
        return list(records)
    return list(records[:max_requests])

def group_counts(records: Iterable[RequestRecord], attr: str) -> Dict[str, int]:
    counts: Dict[str, int] = defaultdict(int)
    for record in records:
        value = getattr(record, attr)
        if value:
            counts[value] += 1
    return counts

def joint_counts(records: Iterable[RequestRecord]) -> Dict[Tuple[str, str], int]:
    counts: Dict[Tuple[str, str], int] = defaultdict(int)
    for record in records:
        if record.code_hash and record.bitmap_hash:
            counts[(record.code_hash, record.bitmap_hash)] += 1
    return counts

def relation_counts(records: Sequence[RequestRecord]) -> Dict[str, int]:
    code_counts = group_counts(records, "code_hash")
    bitmap_counts = group_counts(records, "bitmap_hash")
    both_counts = joint_counts(records)

    same_code_pairs = sum(choose2(count) for count in code_counts.values())
    same_bitmap_pairs = sum(choose2(count) for count in bitmap_counts.values())
    same_both_pairs = sum(choose2(count) for count in both_counts.values())
    comparable_pairs = choose2(len(records))

    false_split = same_code_pairs - same_both_pairs
    false_merge = same_bitmap_pairs - same_both_pairs
    true_negative = same_both_pairs
    true_positive = comparable_pairs - same_code_pairs - same_bitmap_pairs + same_both_pairs
    return {
        "same_code_pairs": same_code_pairs,
        "same_bitmap_pairs": same_bitmap_pairs,
        "same_both_pairs": same_both_pairs,
        "true_positive": true_positive,
        "false_merge": false_merge,
        "false_split": false_split,
        "true_negative": true_negative,
    }

def records_by_request(records: Iterable[RequestRecord]) -> Dict[str, List[RequestRecord]]:
    groups: Dict[str, List[RequestRecord]] = defaultdict(list)
    for record in records:
        groups[record.request].append(record)
    return groups

def pair_outcome(left: RequestRecord, right: RequestRecord) -> Tuple[bool, bool, str]:
    code_same = left.code_hash == right.code_hash
    bitmap_same = left.bitmap_hash == right.bitmap_hash
    if not code_same and not bitmap_same:
        outcome = "true_positive"
    elif not code_same and bitmap_same:
        outcome = "false_merge"
    elif code_same and not bitmap_same:
        outcome = "false_split"
    else:
        outcome = "true_negative"
    return code_same, bitmap_same, outcome

def classification_metrics(tp: int, fn: int, fp: int, tn: int) -> Dict[str, Any]:
    """Standard binary-classification view of the pair partition.

    The positive class is "these two requests are DIFFERENT under the native
    oracle".  TraceLib is the predictor, so:

      TP  native different, TraceLib different  (correct split)
      FN  native different, TraceLib same       (false merge: novelty missed)
      FP  native same,      TraceLib different  (false split: spurious novelty)
      TN  native same,      TraceLib same       (correct merge)
    """
    positives = tp + fn
    negatives = tn + fp
    total = positives + negatives
    tpr = safe_div(tp, positives)
    tnr = safe_div(tn, negatives)
    fnr = safe_div(fn, positives)
    fpr = safe_div(fp, negatives)
    precision = safe_div(tp, tp + fp)
    npv = safe_div(tn, tn + fn)
    recalls = [value for value in (tpr, tnr) if value is not None]
    f1 = (
        2 * precision * tpr / (precision + tpr)
        if precision is not None and tpr is not None and (precision + tpr)
        else None
    )
    jaccard = safe_div(tp, tp + fp + fn)
    mcc_denominator = math.sqrt(
        float(tp + fp) * float(tp + fn) * float(tn + fp) * float(tn + fn)
    )
    mcc = (
        (float(tp) * float(tn) - float(fp) * float(fn)) / mcc_denominator
        if mcc_denominator
        else None
    )

    same_native = tn + fn
    same_tracelib = tn + fp
    if total:
        expected = same_native * same_tracelib / total
        maximum = 0.5 * (same_native + same_tracelib)
        denominator = maximum - expected
        if denominator:
            adjusted_rand = (tn - expected) / denominator
        else:
            adjusted_rand = 1.0 if fp == 0 and fn == 0 else 0.0
    else:
        adjusted_rand = None
    return {
        "positive_class": "native_coverage_differs",
        "true_positive": tp,
        "false_negative": fn,
        "false_positive": fp,
        "true_negative": tn,
        "native_different_pairs": positives,
        "native_same_pairs": negatives,
        "comparable_pairs": total,
        "tpr": tpr,
        "tnr": tnr,
        "fnr": fnr,
        "fpr": fpr,
        "precision": precision,
        "negative_predictive_value": npv,
        "accuracy": safe_div(tp + tn, total),
        "balanced_accuracy": sum(recalls) / len(recalls) if recalls else None,
        "f1": f1,
        "jaccard": jaccard,
        "matthews_corrcoef": mcc,
        "adjusted_rand_index": adjusted_rand,
    }

def summarize(records: Sequence[RequestRecord]) -> Dict[str, Any]:
    complete = [record for record in records if record.complete]
    total_records = len(records)
    complete_records = len(complete)
    total_pairs = choose2(total_records)
    comparable_pairs = choose2(complete_records)
    skipped_pairs = total_pairs - comparable_pairs

    code_counts = group_counts(complete, "code_hash")
    bitmap_counts = group_counts(complete, "bitmap_hash")
    both_counts = joint_counts(complete)

    counts = relation_counts(complete)
    same_code_pairs = counts["same_code_pairs"]
    same_bitmap_pairs = counts["same_bitmap_pairs"]
    false_split = counts["false_split"]
    false_merge = counts["false_merge"]
    true_negative = counts["true_negative"]
    true_positive = counts["true_positive"]
    aligned = true_positive + true_negative
    mismatched = false_merge + false_split

    aligned_same_request_pairs = 0
    mismatched_same_request_pairs = 0
    for request_group in records_by_request(complete).values():
        group_counts_for_request = relation_counts(request_group)
        aligned_same_request_pairs += (
            group_counts_for_request["true_positive"]
            + group_counts_for_request["true_negative"]
        )
        mismatched_same_request_pairs += (
            group_counts_for_request["false_merge"]
            + group_counts_for_request["false_split"]
        )

    same_coverage_records: Set[int] = set()
    different_coverage_records: Set[int] = set()
    false_merge_records: Set[int] = set()
    false_split_records: Set[int] = set()
    for record in complete:
        joint_count = both_counts[(record.code_hash, record.bitmap_hash)]
        if joint_count > 1:
            same_coverage_records.add(record.ordinal)
        different_partner_count = (
            complete_records
            - code_counts[record.code_hash]
            - bitmap_counts[record.bitmap_hash]
            + joint_count
        )
        if different_partner_count > 0:
            different_coverage_records.add(record.ordinal)
        if bitmap_counts[record.bitmap_hash] - joint_count > 0:
            false_merge_records.add(record.ordinal)
        if code_counts[record.code_hash] - joint_count > 0:
            false_split_records.add(record.ordinal)

    by_ordinal = {record.ordinal: record for record in complete}

    def unique_requests(ordinals: Set[int]) -> int:
        return len({by_ordinal[ordinal].request for ordinal in ordinals})

    return {
        "records": total_records,
        "complete_records": complete_records,
        "unique_requests": len({record.request for record in records}),
        "complete_unique_requests": len({record.request for record in complete}),
        "missing_code_hash_records": sum(1 for record in records if not record.code_hash),
        "missing_bitmap_hash_records": sum(1 for record in records if not record.bitmap_hash),
        "total_pairs": total_pairs,
        "comparable_pairs": comparable_pairs,
        "skipped_pairs_due_to_missing_hash": skipped_pairs,
        "unique_code_hashes": len(code_counts),
        "unique_bitmap_hashes": len(bitmap_counts),
        "unique_joint_hashes": len(both_counts),
        "true_positive_code_diff_bitmap_diff": true_positive,
        "false_merge_code_diff_bitmap_same": false_merge,
        "false_split_code_same_bitmap_diff": false_split,
        "true_negative_code_same_bitmap_same": true_negative,
        "aligned_pairs": aligned,
        "mismatched_pairs": mismatched,
        "aligned_same_coverage_pairs": true_negative,
        "aligned_different_coverage_pairs": true_positive,
        "aligned_same_coverage_record_count": len(same_coverage_records),
        "aligned_same_coverage_unique_requests": unique_requests(same_coverage_records),
        "aligned_different_coverage_record_count": len(different_coverage_records),
        "aligned_different_coverage_unique_requests": unique_requests(different_coverage_records),
        "aligned_same_request_pairs": aligned_same_request_pairs,
        "aligned_different_request_pairs": aligned - aligned_same_request_pairs,
        "mismatched_same_request_pairs": mismatched_same_request_pairs,
        "mismatched_different_request_pairs": mismatched - mismatched_same_request_pairs,
        "false_merge_record_count": len(false_merge_records),
        "false_merge_unique_requests": unique_requests(false_merge_records),
        "false_split_record_count": len(false_split_records),
        "false_split_unique_requests": unique_requests(false_split_records),
        "alignment_rate": safe_div(aligned, comparable_pairs),
        "aligned_same_coverage_rate_among_aligned_pairs": safe_div(true_negative, aligned),
        "aligned_different_coverage_rate_among_aligned_pairs": safe_div(true_positive, aligned),
        "aligned_same_request_rate_among_aligned_pairs": safe_div(
            aligned_same_request_pairs, aligned
        ),
        "aligned_different_request_rate_among_aligned_pairs": safe_div(
            aligned - aligned_same_request_pairs, aligned
        ),
        "false_merge_rate_among_code_different_pairs": safe_div(
            false_merge, comparable_pairs - same_code_pairs
        ),
        "false_split_rate_among_code_same_pairs": safe_div(false_split, same_code_pairs),
        "classification": classification_metrics(
            true_positive, false_merge, false_split, true_negative
        ),
    }

def index_by_hash(records: Sequence[RequestRecord], attr: str) -> Dict[str, List[RequestRecord]]:
    groups: Dict[str, List[RequestRecord]] = defaultdict(list)
    for record in records:
        value = getattr(record, attr)
        if value:
            groups[value].append(record)
    return groups

def example_false_merges(records: Sequence[RequestRecord], limit: int) -> List[Dict[str, Any]]:
    examples: List[Dict[str, Any]] = []
    if limit <= 0:
        return examples
    for bitmap_group in index_by_hash(records, "bitmap_hash").values():
        by_code: Dict[str, RequestRecord] = {}
        for record in bitmap_group:
            if record.code_hash and record.code_hash not in by_code:
                by_code[record.code_hash] = record
        if len(by_code) < 2:
            continue
        picked = list(by_code.values())[:2]
        examples.append(example_pair(picked[0], picked[1], "false_merge"))
        if len(examples) >= limit:
            break
    return examples

def example_false_splits(records: Sequence[RequestRecord], limit: int) -> List[Dict[str, Any]]:
    examples: List[Dict[str, Any]] = []
    if limit <= 0:
        return examples
    for code_group in index_by_hash(records, "code_hash").values():
        by_bitmap: Dict[str, RequestRecord] = {}
        for record in code_group:
            if record.bitmap_hash and record.bitmap_hash not in by_bitmap:
                by_bitmap[record.bitmap_hash] = record
        if len(by_bitmap) < 2:
            continue
        picked = list(by_bitmap.values())[:2]
        examples.append(example_pair(picked[0], picked[1], "false_split"))
        if len(examples) >= limit:
            break
    return examples

def example_true_negatives(records: Sequence[RequestRecord], limit: int) -> List[Dict[str, Any]]:
    examples: List[Dict[str, Any]] = []
    if limit <= 0:
        return examples
    groups: Dict[Tuple[str, str], List[RequestRecord]] = defaultdict(list)
    for record in records:
        if record.code_hash and record.bitmap_hash:
            groups[(record.code_hash, record.bitmap_hash)].append(record)
    for group in groups.values():
        if len(group) < 2:
            continue
        examples.append(example_pair(group[0], group[1], "true_negative"))
        if len(examples) >= limit:
            break
    return examples

def example_true_positives(records: Sequence[RequestRecord], limit: int) -> List[Dict[str, Any]]:
    examples: List[Dict[str, Any]] = []
    if limit <= 0:
        return examples
    for index, left in enumerate(records):
        for right in records[index + 1 :]:
            if left.code_hash != right.code_hash and left.bitmap_hash != right.bitmap_hash:
                examples.append(example_pair(left, right, "true_positive"))
                if len(examples) >= limit:
                    return examples
    return examples

def example_pair(left: RequestRecord, right: RequestRecord, outcome: str) -> Dict[str, Any]:
    return {
        "left_ordinal": left.ordinal,
        "right_ordinal": right.ordinal,
        "left_request": left.request,
        "right_request": right.request,
        "outcome": outcome,
        "same_code_coverage_hash": left.code_hash == right.code_hash,
        "same_bitmap_coverage_hash": left.bitmap_hash == right.bitmap_hash,
    }

def write_pairs_csv(records: Sequence[RequestRecord], output: Path) -> int:
    complete = [record for record in records if record.complete]
    output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with output.open("w", newline="", encoding="utf-8") as sink:
        writer = csv.writer(sink)
        writer.writerow(
            [
                "left_ordinal",
                "right_ordinal",
                "left_request",
                "right_request",
                "same_code_coverage_hash",
                "same_bitmap_coverage_hash",
                "outcome",
                "aligned",
            ]
        )
        for index, left in enumerate(complete):
            for right in complete[index + 1 :]:
                code_same, bitmap_same, outcome = pair_outcome(left, right)
                writer.writerow(
                    [
                        left.ordinal,
                        right.ordinal,
                        left.request,
                        right.request,
                        str(code_same).lower(),
                        str(bitmap_same).lower(),
                        outcome,
                        str(code_same == bitmap_same).lower(),
                    ]
                )
                count += 1
    return count

def write_summary(summary: Mapping[str, Any], examples: Mapping[str, Any], output: Optional[Path]) -> None:
    payload = {"summary": dict(summary), "examples": dict(examples)}
    text = json.dumps(payload, indent=2) + "\n"
    if output is None:
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")

def print_summary(input_path: Path, summary: Mapping[str, Any], examples: Mapping[str, Any]) -> None:
    print(f"request feedback alignment: {input_path}")
    request_limit = summary["request_limit"]
    limit_text = "unlimited" if request_limit == 0 else str(request_limit)
    print(
        "records: available={} analyzed={} complete={} limit={} truncated={}".format(
            summary["available_records"],
            summary["records"],
            summary["complete_records"],
            limit_text,
            summary["truncated_records"],
        )
    )
    print(
        "unique requests: total={} complete={}".format(
            summary["unique_requests"], summary["complete_unique_requests"]
        )
    )
    print(
        "missing hashes: code={} bitmap={}".format(
            summary["missing_code_hash_records"], summary["missing_bitmap_hash_records"]
        )
    )
    print(
        "pairs: total={} comparable={} skipped_missing={}".format(
            summary["total_pairs"],
            summary["comparable_pairs"],
            summary["skipped_pairs_due_to_missing_hash"],
        )
    )
    print(
        "aligned pairs: {} ({})".format(
            summary["aligned_pairs"], percent(summary["alignment_rate"])
        )
    )
    print(f"mismatched pairs: {summary['mismatched_pairs']}")
    print(
        "aligned detail: same_coverage={} ({}) different_coverage={} ({})".format(
            summary["aligned_same_coverage_pairs"],
            percent(summary["aligned_same_coverage_rate_among_aligned_pairs"]),
            summary["aligned_different_coverage_pairs"],
            percent(summary["aligned_different_coverage_rate_among_aligned_pairs"]),
        )
    )
    print(
        "aligned requests: same_request={} ({}) different_request={} ({})".format(
            summary["aligned_same_request_pairs"],
            percent(summary["aligned_same_request_rate_among_aligned_pairs"]),
            summary["aligned_different_request_pairs"],
            percent(summary["aligned_different_request_rate_among_aligned_pairs"]),
        )
    )
    print(
        "aligned same-coverage participants: records={} unique_requests={}".format(
            summary["aligned_same_coverage_record_count"],
            summary["aligned_same_coverage_unique_requests"],
        )
    )
    print(
        "aligned different-coverage participants: records={} unique_requests={}".format(
            summary["aligned_different_coverage_record_count"],
            summary["aligned_different_coverage_unique_requests"],
        )
    )
    print(
        "oracle counts: true_positive={} false_negative_merge={} false_positive_split={} true_negative={}".format(
            summary["true_positive_code_diff_bitmap_diff"],
            summary["false_merge_code_diff_bitmap_same"],
            summary["false_split_code_same_bitmap_diff"],
            summary["true_negative_code_same_bitmap_same"],
        )
    )
    print(
        "rates: false_negative_merge={} false_positive_split={}".format(
            percent(summary["false_merge_rate_among_code_different_pairs"]),
            percent(summary["false_split_rate_among_code_same_pairs"]),
        )
    )
    metrics = summary["classification"]
    print("classification (positive class = native coverage differs):")
    print(
        "  confusion: TP={} FN={} FP={} TN={}".format(
            metrics["true_positive"],
            metrics["false_negative"],
            metrics["false_positive"],
            metrics["true_negative"],
        )
    )
    print(
        "  support:   native_different={} native_same={}".format(
            metrics["native_different_pairs"], metrics["native_same_pairs"]
        )
    )
    print(
        "  TPR={} TNR={} FPR={} FNR={}".format(
            percent(metrics["tpr"]),
            percent(metrics["tnr"]),
            percent(metrics["fpr"]),
            percent(metrics["fnr"]),
        )
    )
    print(
        "  precision={} NPV={} F1={} Jaccard={}".format(
            percent(metrics["precision"]),
            percent(metrics["negative_predictive_value"]),
            percent(metrics["f1"]),
            percent(metrics["jaccard"]),
        )
    )
    print(
        "  accuracy={} balanced_accuracy={} MCC={} ARI={}".format(
            percent(metrics["accuracy"]),
            percent(metrics["balanced_accuracy"]),
            "N/A" if metrics["matthews_corrcoef"] is None else f"{metrics['matthews_corrcoef']:.4f}",
            "N/A" if metrics["adjusted_rand_index"] is None else f"{metrics['adjusted_rand_index']:.4f}",
        )
    )
    if examples["false_merges"]:
        print("example false_merge:", examples["false_merges"][0])
    if examples["false_splits"]:
        print("example false_split:", examples["false_splits"][0])
    if examples["true_negatives"]:
        print("example aligned_same_coverage:", examples["true_negatives"][0])
    if examples["true_positives"]:
        print("example aligned_different_coverage:", examples["true_positives"][0])

def print_pair(records: Sequence[RequestRecord], left_ordinal: int, right_ordinal: int) -> None:
    by_ordinal = {record.ordinal: record for record in records}
    try:
        left = by_ordinal[left_ordinal]
        right = by_ordinal[right_ordinal]
    except KeyError as exc:
        raise ValueError(
            f"unknown request ordinal or ordinal beyond --max-requests: {exc.args[0]}"
        ) from exc
    if not left.complete or not right.complete:
        raise ValueError("both selected requests must have code and bitmap coverage hashes")

    code_same, bitmap_same, outcome = pair_outcome(left, right)
    print(
        "pair {} vs {}: code_coverage_hash_same={} bitmap_coverage_hash_same={} outcome={} aligned={}".format(
            left_ordinal,
            right_ordinal,
            str(code_same).lower(),
            str(bitmap_same).lower(),
            outcome,
            str(code_same == bitmap_same).lower(),
        )
    )

def self_test() -> None:
    data = [
        {"request": "GET /a", "code_coverage_hash": "code-a", "bitmap_coverage_hash": "bitmap-x"},
        {"request": "GET /b", "code_coverage_hash": "code-a", "bitmap_coverage_hash": "bitmap-y"},
        {"request": "GET /c", "code_coverage_hash": "code-b", "bitmap_coverage_hash": "bitmap-x"},
        {"request": "GET /d", "code_coverage_hash": "code-b", "bitmap_coverage_hash": "bitmap-z"},
        {"request": "GET /a", "code_coverage_hash": "code-a", "bitmap_coverage_hash": "bitmap-x"},
        {"request": "GET /e", "code_coverage_hash": None, "bitmap_coverage_hash": "bitmap-z"},
    ]
    with tempfile.TemporaryDirectory(prefix="request-alignment-test-") as tmp:
        root = Path(tmp)
        input_path = root / "requests.json"
        input_path.write_text(json.dumps(data), encoding="utf-8")
        records = load_records(input_path)
        assert [record.ordinal for record in select_records(records, 3)] == [1, 2, 3]
        assert select_records(records, 0) == records
        try:
            select_records(records, -1)
            raise AssertionError("negative request limit was accepted")
        except ValueError:
            pass
        summary = summarize(records)
        assert summary["records"] == 6
        assert summary["complete_records"] == 5
        assert summary["unique_requests"] == 5
        assert summary["complete_unique_requests"] == 4
        assert summary["comparable_pairs"] == 10
        assert summary["false_merge_code_diff_bitmap_same"] == 2
        assert summary["false_split_code_same_bitmap_diff"] == 3
        assert summary["true_positive_code_diff_bitmap_diff"] == 4
        assert summary["true_negative_code_same_bitmap_same"] == 1
        assert summary["aligned_same_coverage_pairs"] == 1
        assert summary["aligned_different_coverage_pairs"] == 4
        assert summary["aligned_same_coverage_record_count"] == 2
        assert summary["aligned_same_coverage_unique_requests"] == 1
        assert summary["aligned_different_coverage_record_count"] == 5
        assert summary["aligned_different_coverage_unique_requests"] == 4
        assert summary["aligned_same_request_pairs"] == 1
        assert summary["aligned_different_request_pairs"] == 4
        pairs_path = root / "pairs.csv"
        assert write_pairs_csv(records, pairs_path) == 10
        assert pairs_path.read_text(encoding="utf-8").count("\n") == 11
        print_pair(records, 1, 2)

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Compare compact request-feedback JSON pairwise: code_coverage_hash is "
            "the reference relation and bitmap_coverage_hash is the TraceLib relation."
        )
    )
    parser.add_argument("json_file", nargs="?", help="compact request feedback JSON file")
    parser.add_argument("--pairs-csv", type=Path, help="optional CSV with every comparable pair")
    parser.add_argument("--summary-json", type=Path, help="optional machine-readable summary JSON")
    parser.add_argument("--examples", type=int, default=3, help="number of mismatch examples to include")
    parser.add_argument(
        "--max-requests",
        type=int,
        default=DEFAULT_MAX_REQUESTS,
        metavar="N",
        help=(
            f"analyze only the first N observations (default: {DEFAULT_MAX_REQUESTS}; "
            "0 means unlimited)"
        ),
    )
    parser.add_argument(
        "--pair",
        type=int,
        nargs=2,
        metavar=("LEFT_ORDINAL", "RIGHT_ORDINAL"),
        help="also print the comparison for one pair of 1-based request ordinals",
    )
    parser.add_argument(
        "--bitmap-hash",
        default="index",
        choices=("index", "bucket"),
        help=(
            "which TraceLib relation to score: 'index' (default) reads "
            "bitmap_coverage_hash, i.e. the SET of lit bitmap cells; 'bucket' reads "
            "bitmap_coverage_hash_bucket, i.e. lit cells AND their hit-count buckets"
        ),
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        print("compare_request_feedback_hashes: self-test passed")
        return 0
    if not args.json_file:
        parser.error("json_file is required unless --self-test is used")
    if args.max_requests < 0:
        parser.error("--max-requests must be non-negative")

    input_path = Path(args.json_file).resolve()
    available_records = load_records(input_path, args.bitmap_hash)
    records = select_records(available_records, args.max_requests)
    summary = summarize(records)
    summary.update(
        {
            "bitmap_hash": args.bitmap_hash,
            "bitmap_hash_field": BITMAP_HASH_FIELDS[args.bitmap_hash],
            "available_records": len(available_records),
            "request_limit": args.max_requests,
            "truncated_records": len(available_records) - len(records),
        }
    )
    complete = [record for record in records if record.complete]
    examples = {
        "true_positives": example_true_positives(complete, max(0, args.examples)),
        "true_negatives": example_true_negatives(complete, max(0, args.examples)),
        "false_merges": example_false_merges(complete, max(0, args.examples)),
        "false_splits": example_false_splits(complete, max(0, args.examples)),
    }

    print_summary(input_path, summary, examples)
    if args.pair:
        print_pair(records, args.pair[0], args.pair[1])
    write_summary(summary, examples, args.summary_json)
    if args.pairs_csv:
        written = write_pairs_csv(records, args.pairs_csv)
        print(f"wrote pairwise CSV: {args.pairs_csv} ({written} pairs)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
