from __future__ import annotations

import hashlib
import heapq
import json
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Mapping, Optional, Set
from urllib.parse import urlsplit

from ._bootstrap import ensure_paths

ensure_paths()

from webFuzz.environment import env
from webFuzz.node import Node
from webFuzz.node_iterator import NodeIterator
from webFuzz.types import CFGTuple, FeedbackMode, HTTPMethod, get_logger

REQUEST_SEQUENCE_SCHEMA_VERSION = 1

def _serializable_params(params: Mapping[object, object]) -> Dict[str, object]:
    """Return HTTP parameters in a stable, JSON-safe representation."""
    serialized: Dict[str, object] = {}
    for raw_key, raw_value in params.items():
        key = str(raw_key)
        if isinstance(raw_value, (list, tuple)):
            serialized[key] = [str(value) for value in raw_value]
        else:
            serialized[key] = str(raw_value)
    return serialized

def _request_record_core(request: Node, ordinal: int) -> Dict[str, object]:
    return {
        "schema_version": REQUEST_SEQUENCE_SCHEMA_VERSION,
        "ordinal": ordinal,
        "method": request.method.name,

        "url": request.url,
        "params": {
            HTTPMethod.GET.name: _serializable_params(request.params[HTTPMethod.GET]),
            HTTPMethod.POST.name: _serializable_params(request.params[HTTPMethod.POST]),
        },
        "label": request.label,
    }

def request_record_sha256(record: Mapping[str, object]) -> str:
    """Hash the cookie-free request identity, excluding any existing digest."""
    core = {key: value for key, value in record.items() if key != "request_sha256"}
    encoded = json.dumps(
        core,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()

def prepare_request_record(request: Node, ordinal: int) -> Dict[str, object]:
    """Build a canonical record and expose its identity in completion logs."""
    record = _request_record_core(request, ordinal)
    digest = request_record_sha256(record)
    record["request_sha256"] = digest
    request._request_baseline_ordinal = ordinal
    request._request_sha256 = digest
    request.__dict__.pop("_json", None)
    return record

def initialize_request_record_file(path: str) -> Path:
    """Create an empty baseline JSONL file, replacing only that exact file."""
    target = Path(path).expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("", encoding="utf-8")
    target.chmod(0o600)
    return target

def append_request_record(path: str, record: Mapping[str, object]) -> None:
    """Append one submitted request as a single durable JSONL record."""
    with Path(path).open("a", encoding="utf-8") as output:
        output.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        output.flush()

def _origin(raw_url: str) -> tuple[str, str]:
    parsed = urlsplit(raw_url)
    return parsed.scheme.lower(), parsed.netloc.lower()

def iter_request_sequence(
    path: str,
    allowed_endpoint_urls: Optional[Iterable[str]] = None,
) -> Iterator[Node]:
    """Load and validate a canonical Blackbox request sequence for replay.

    Cookies and mode-specific tracing headers are intentionally absent from
    the format. aiohttp supplies the fresh cookie jar established for the
    current treatment, while TraceLib adds its own per-request identifier.
    """
    source = Path(path).expanduser().resolve()
    if not source.is_file():
        raise ValueError(f"request replay file does not exist: {source}")

    allowed_origins = {
        _origin(url) for url in (allowed_endpoint_urls or [])
    }
    request_count = 0
    with source.open(encoding="utf-8") as input_file:
        lines = enumerate(input_file, start=1)
        for line_number, raw_line in lines:
            if not raw_line.strip():
                continue
            try:
                record = json.loads(raw_line)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"invalid request replay JSON at {source}:{line_number}: {exc}"
                ) from exc
            if not isinstance(record, dict):
                raise ValueError(f"request replay record {line_number} is not an object")
            if record.get("schema_version") != REQUEST_SEQUENCE_SCHEMA_VERSION:
                raise ValueError(
                    f"unsupported request replay schema at record {line_number}: "
                    f"{record.get('schema_version')!r}"
                )

            expected_ordinal = request_count + 1
            if record.get("ordinal") != expected_ordinal:
                raise ValueError(
                    f"request replay ordinals must be contiguous: expected "
                    f"{expected_ordinal}, got {record.get('ordinal')!r}"
                )
            expected_digest = request_record_sha256(record)
            if record.get("request_sha256") != expected_digest:
                raise ValueError(
                    f"request replay digest mismatch at ordinal {expected_ordinal}"
                )

            method_name = record.get("method")
            try:
                method = HTTPMethod[str(method_name)]
            except KeyError as exc:
                raise ValueError(
                    f"unsupported replay HTTP method at ordinal {expected_ordinal}: "
                    f"{method_name!r}"
                ) from exc
            if method not in {HTTPMethod.GET, HTTPMethod.POST}:
                raise ValueError(
                    f"unsupported replay HTTP method at ordinal {expected_ordinal}: "
                    f"{method.name}"
                )

            url = record.get("url")
            if not isinstance(url, str) or not url:
                raise ValueError(f"missing replay URL at ordinal {expected_ordinal}")
            if allowed_origins and _origin(url) not in allowed_origins:
                raise ValueError(
                    f"replay URL leaves the configured WUT origin at ordinal "
                    f"{expected_ordinal}: {url}"
                )

            raw_params = record.get("params")
            if not isinstance(raw_params, dict):
                raise ValueError(f"invalid replay params at ordinal {expected_ordinal}")
            params = {}
            for request_method in (HTTPMethod.GET, HTTPMethod.POST):
                values = raw_params.get(request_method.name, {})
                if not isinstance(values, dict):
                    raise ValueError(
                        f"invalid {request_method.name} replay params at ordinal "
                        f"{expected_ordinal}"
                    )
                params[request_method] = {
                    str(key): (
                        [str(value) for value in raw_value]
                        if isinstance(raw_value, list)
                        else str(raw_value)
                    )
                    for key, raw_value in values.items()
                }

            label = record.get("label", "")
            if not isinstance(label, str):
                raise ValueError(f"invalid replay label at ordinal {expected_ordinal}")
            request = Node(url, method, params=params, label=label)
            request._request_baseline_ordinal = expected_ordinal
            request._request_sha256 = expected_digest
            request_count += 1
            yield request

    if request_count == 0:
        raise ValueError(f"request replay file is empty: {source}")

def load_request_sequence(
    path: str,
    allowed_endpoint_urls: Optional[Iterable[str]] = None,
) -> List[Node]:
    """Materialize a request sequence; intended for tests and small inputs."""
    return list(iter_request_sequence(path, allowed_endpoint_urls))

def validate_request_sequence(
    path: str,
    allowed_endpoint_urls: Optional[Iterable[str]] = None,
) -> int:
    """Validate a potentially large sequence without retaining it in memory."""
    return sum(1 for _ in iter_request_sequence(path, allowed_endpoint_urls))

def _blackbox_seed_only_mode() -> bool:
    """Return whether submitted BlackBox mutations should be discarded."""
    return (
        env.args is not None
        and getattr(env.args, "feedback_mode", None) == FeedbackMode.BLACKBOX
        and getattr(env.args, "blackbox_corpus_mode", "keep-submitted") == "seed-only"
    )

class SingleEndpointQueue:
    """Crawler-compatible queue that never accepts discovered links."""

    def __init__(self, initial_nodes: Node | Iterable[Node]) -> None:
        if isinstance(initial_nodes, Node):
            self._pending = [initial_nodes]
        else:
            self._pending = list(initial_nodes)

    @property
    def pending_requests(self) -> int:
        return len(self._pending)

    def __add__(self, links: Set[Node]) -> "SingleEndpointQueue":
        return self

    def __iter__(self) -> "SingleEndpointQueue":
        return self

    def __next__(self) -> Node:
        if not self._pending:
            raise StopIteration
        return self._pending.pop(0)

class NoopParser:
    """Parser-compatible object that prevents crawler expansion."""

    @staticmethod
    def parse(node: Node, soup) -> Set[Node]:
        return set()

class SingleEndpointNodeIterator(NodeIterator):
    """Node iterator with campaign-wide coverage and endpoint-local corpus."""

    def reset_endpoint_corpus(self) -> None:
        self.node_list = []

    def add(self, new_node: Node, node_cfg: CFGTuple):
        if _blackbox_seed_only_mode() and new_node.is_mutated:
            get_logger(__name__).debug(
                "[blackbox] seed-only corpus: discarded submitted mutation"
            )
            return False

        accepted = super().add(new_node, node_cfg)
        if accepted:
            return True

        if not getattr(new_node, "_single_endpoint_seed", False):
            return False

        max_corpus = getattr(env.args, "max_corpus_size", 0) if env.args is not None else 0
        if max_corpus and len(self.node_list) >= max_corpus:
            return False

        logger = get_logger(__name__)
        new_node.ref_count += 1
        heapq.heappush(self.node_list, new_node)
        logger.info(
            "accepted configured endpoint seed for endpoint-local mutation "
            "without increasing campaign coverage"
        )
        return True
