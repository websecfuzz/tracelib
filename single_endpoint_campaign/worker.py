from __future__ import annotations

import json
import os
import time
from itertools import repeat
from typing import Optional

from ._bootstrap import ensure_paths

ensure_paths()

from webFuzz.environment import env
from webFuzz.misc import iter_join
from webFuzz.node import Node
from webFuzz.types import CFGTuple, ExitCode, RequestStatus, get_logger
from webFuzz.worker import LOGGED_IN_CHECK_INTERVAL, Worker

from .fixed_endpoint import (
    append_request_record,
    iter_request_sequence,
    prepare_request_record,
)

class SingleEndpointWorker(Worker):
    """Worker variant where every non-session request belongs to fuzzing."""

    def _endpoint_time_budget_reached(self) -> bool:
        if getattr(env.args, "endpoint_schedule", "sequential") == "blend":
            return False

        if getattr(env.args, "endpoint_stop_requested", False):
            return True

        deadline = getattr(env.args, "endpoint_deadline_monotonic", 0.0)
        if not deadline or time.monotonic() < deadline:
            return False

        if env.shutdown_signal != ExitCode.NONE:
            return False

        logger = get_logger(__name__, self.id)
        start = getattr(env.args, "endpoint_start_monotonic", 0.0)
        elapsed = time.monotonic() - start if start else 0.0
        logger.warning(
            "ENDPOINT TIME BUDGET reached for endpoint %d/%d after %.1fs "
            "(budget %ds); moving to next endpoint",
            getattr(env.args, "endpoint_index", 1),
            getattr(env.args, "endpoint_total", 1),
            elapsed,
            getattr(env.args, "endpoint_time_budget", 0),
        )
        env.args.endpoint_time_budget_expired = True
        env.args.endpoint_stop_requested = True
        return True

    @staticmethod
    def _seed_node_for_request(request: Node) -> Node:
        node = request
        while getattr(node, "parent_request", None) is not None:
            parent = node.parent_request
            if parent is None:
                break
            node = parent
        return node

    def _record_feedback_manifest(
        self,
        request: Node,
        response_status: int,
        accepted: bool,
        cfg: CFGTuple,
        external_reference: Optional[object] = None,
    ) -> None:
        manifest = os.environ.get("WEBFUZZ_FEEDBACK_MANIFEST", "")
        rid = getattr(request, "_tracelib_rid", None)
        if not manifest or not rid:
            return

        logger = get_logger(__name__, self.id)
        try:
            parent = os.path.dirname(os.path.abspath(manifest))
            os.makedirs(parent, exist_ok=True)
            record = {
                "ordinal": self._stats.total_requests,
                "timestamp_ns": time.time_ns(),
                "request_id": rid,
                "method": request.method.name,
                "url": str(request.full_url),
                "phase": "session_check" if request.label == "session_check" else "fuzz",
                "params": {
                    method.name: dict(params)
                    for method, params in request.params.items()
                },
                "label": request.label,
                "http_status": response_status,
                "tracelib_nonzero": len(cfg.xor_cfg),
                "tracelib_accepted": bool(accepted),
            }
            if hasattr(env.args, "endpoint_index"):
                seed_node = self._seed_node_for_request(request)
                record["endpoint_schedule"] = getattr(env.args, "endpoint_schedule", "sequential")
                record["endpoint_index"] = getattr(
                    seed_node,
                    "_single_endpoint_seed_index",
                    env.args.endpoint_index,
                )
                record["endpoint_total"] = env.args.endpoint_total
                record["endpoint_url"] = getattr(
                    seed_node,
                    "_single_endpoint_seed_url",
                    env.args.URL,
                )
            if external_reference is not None:
                record["reference_feedback"] = external_reference
            with open(manifest, "a", encoding="utf-8") as output:
                output.write(json.dumps(record, sort_keys=True) + "\n")
                output.flush()
        except Exception as exc:
            logger.warning("could not write feedback manifest: %s", exc)

    def _count_fuzz_request(self, request: Node) -> None:
        if request.label == "session_check":
            return

        logger = get_logger(__name__, self.id)
        self._stats.fuzz_requests += 1
        if not self._stats.fuzz_started:
            self._stats.fuzz_started = True
            self._stats.fuzz_start_wall = time.time()
            self._stats.fuzz_start_monotonic = time.monotonic()
            self._stats.crawl_requests_at_fuzz_start = 0
            logger.warning(
                "FUZZING PHASE STARTED: single-endpoint campaign has no crawl phase "
                "(wall=%.3f)",
                self._stats.fuzz_start_wall,
            )

    def _prepare_blackbox_record(self, request: Node) -> Optional[dict]:
        record_file = getattr(env.args, "request_record_file", "")
        if not record_file or request.label == "session_check":
            return None
        ordinal = int(getattr(env.args, "request_record_count", 0)) + 1
        return prepare_request_record(request, ordinal)

    def _commit_blackbox_record(self, record: Optional[dict]) -> None:
        if record is None:
            return
        append_request_record(env.args.request_record_file, record)
        env.args.request_record_count = int(record["ordinal"])

    async def _run_replay_worker(self) -> ExitCode:
        """Submit the Blackbox baseline sequence without corpus mutation."""
        logger = get_logger(__name__, self.id)
        replay_count = int(getattr(env.args, "request_replay_count", 0))
        logger.warning(
            "IDENTICAL REQUEST REPLAY STARTED: %d cookie-free baseline requests; "
            "using this treatment's current cookie jar",
            replay_count,
        )

        replay_requests = iter_request_sequence(
            env.args.request_replay_file,
            getattr(env.args, "request_replay_endpoint_urls", []),
        )
        for request in replay_requests:
            self._count_fuzz_request(request)
            try:
                await self.process_req(request)
            except Exception as exc:
                if env.args.http_error_at_info:
                    logger.info(exc, exc_info=False)
                else:
                    logger.warning(exc, exc_info=False)

            if env.shutdown_signal != ExitCode.NONE:
                return env.shutdown_signal

        logger.warning(
            "FUZZ REQUEST BUDGET reached: %d fuzzing requests (budget %d); "
            "identical request replay complete",
            self._stats.fuzz_requests,
            replay_count,
        )
        env.shutdown_signal = ExitCode.BUDGET_REACHED
        return ExitCode.BUDGET_REACHED

    async def run_worker(self) -> ExitCode:
        logger = get_logger(__name__, self.id)
        logger.info("Single-endpoint worker reporting active")

        if getattr(env.args, "request_replay_file", ""):
            return await self._run_replay_worker()

        if env.args.catch_phrase and not env.skip_session_check:
            periodic = repeat(self._session_node)
        else:
            periodic = repeat(None, 0)

        for (src, new_request) in iter_join(
            primary=self._crawler,
            secondary=self._node_iterator,
            periodic=periodic,
            interval=LOGGED_IN_CHECK_INTERVAL,
        ):
            if self._endpoint_time_budget_reached():
                return ExitCode.TIMEOUT

            if src == self._crawler:
                logger.info("Chosen a configured endpoint seed")
            elif src == self._node_iterator:
                new_request = self._mutator.mutate(new_request, self._node_iterator.node_list)
                logger.info("Chosen a mutated single-endpoint node")

            self._count_fuzz_request(new_request)
            pending_record = self._prepare_blackbox_record(new_request)

            self._commit_blackbox_record(pending_record)

            try:
                return_code = await self.process_req(new_request)
            except Exception as exc:
                if env.args.http_error_at_info:
                    logger.info(exc, exc_info=False)
                else:
                    logger.warning(exc, exc_info=False)

                return_code = RequestStatus.UNSUCCESSFUL_REQUEST

            if src == periodic and return_code != RequestStatus.SUCCESS_FOUND_PHRASE:
                logger.warning("Fuzzer has been logged out...")
                self._stats.crawler_login_state = "logged-out"
                return ExitCode.LOGGED_OUT

            budget = getattr(env.args, "fuzz_request_budget", 0)
            if budget and self._stats.fuzz_requests >= budget:
                logger.warning(
                    "FUZZ REQUEST BUDGET reached: %d fuzzing requests "
                    "(budget %d); finishing campaign",
                    self._stats.fuzz_requests,
                    budget,
                )
                env.shutdown_signal = ExitCode.BUDGET_REACHED
                return ExitCode.BUDGET_REACHED

            if self._endpoint_time_budget_reached():
                return ExitCode.TIMEOUT

            if env.shutdown_signal != ExitCode.NONE:
                return env.shutdown_signal

        logger.error("Aborting due to lack of fuzz targets")
        return ExitCode.EMPTY_QUEUE
