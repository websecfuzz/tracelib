from __future__ import annotations

import aiohttp
import asyncio
import http.client
import json
import logging
import os
import random
import time
from contextlib import asynccontextmanager
from copy import deepcopy
from typing import AsyncIterator, Dict, List
from urllib.parse import urlparse

from aiohttp.client import ClientSession

from ._bootstrap import ensure_paths
from .fixed_endpoint import (
    NoopParser,
    SingleEndpointNodeIterator,
    SingleEndpointQueue,
    initialize_request_record_file,
    validate_request_sequence,
)
from .worker import SingleEndpointWorker

ensure_paths()

from webFuzz.detector import Detector
from webFuzz.environment import env
from webFuzz.fuzzer import Fuzzer
from webFuzz.fuzzer import MAX_LOGIN_CALLS
from webFuzz.misc import retrieve_headers, rtt_trace_config
from webFuzz.mutator import Mutator
from webFuzz.node import Node
from webFuzz.types import (
    FeedbackMode,
    FuzzerLogger,
    HTTPMethod,
    InstrumentArgs,
    ExitCode,
    OutputMethod,
    Statistics,
    get_logger,
)

def _reset_previous_webfuzz_file_handlers() -> None:
    root_logger = logging.getLogger()
    for handler in list(root_logger.handlers):
        if not isinstance(handler, logging.FileHandler):
            continue
        if not os.path.basename(handler.baseFilename).startswith("webFuzz_"):
            continue
        root_logger.removeHandler(handler)
        handler.close()

class SingleEndpointFuzzer(Fuzzer):
    """A WebFuzz campaign over configured fixed endpoints."""

    def __init__(self, args) -> None:
        env.args = args
        env.shutdown_signal = ExitCode.NONE
        env.skip_session_check = False

        _reset_previous_webfuzz_file_handlers()
        FuzzerLogger.init_logging(args)

        logger = get_logger(__name__)
        logger.debug(args)

        self.args = args
        self._endpoint_urls = list(getattr(args, "urls", [args.URL]))
        self._endpoint_schedule = getattr(args, "endpoint_schedule", "blend")
        args.urls = self._endpoint_urls
        args.endpoint_total = len(self._endpoint_urls)
        args.endpoint_schedule = self._endpoint_schedule
        args.all_endpoints_completed = False
        self.worker_count = args.worker
        self.login_calls = 0

        self._request_record_file = getattr(args, "request_record_file", "")
        self._request_replay_file = getattr(args, "request_replay_file", "")
        if self._request_record_file:
            self._request_record_file = str(
                initialize_request_record_file(self._request_record_file)
            )
            args.request_record_file = self._request_record_file
            args.request_record_count = 0
            logger.warning(
                "Recording submitted Blackbox requests for identical replay: %s",
                self._request_record_file,
            )
        if self._request_replay_file:
            replay_count = validate_request_sequence(
                self._request_replay_file,
                allowed_endpoint_urls=self._endpoint_urls,
            )
            args.request_replay_endpoint_urls = list(self._endpoint_urls)
            args.request_replay_count = replay_count
            if args.fuzz_request_budget not in (0, replay_count):
                raise ValueError(
                    "request replay budget must equal the baseline length: "
                    f"budget={args.fuzz_request_budget} baseline={replay_count}"
                )
            args.fuzz_request_budget = replay_count
            logger.warning(
                "Loaded %d canonical requests for mutation-free replay from %s; "
                "cookies will come from this treatment's fresh session",
                replay_count,
                self._request_replay_file,
            )

        if args.feedback_mode == FeedbackMode.NATIVE:
            with open(args.meta_file, encoding="utf-8") as meta_file:
                env.instrument_args = InstrumentArgs(json.loads(meta_file.read()))
        else:
            env.instrument_args = InstrumentArgs.synthetic(
                basic_blocks=args.tracelib_bitmap_size,
                edges=args.tracelib_bitmap_size,
            )

        if env.instrument_args.output_method == OutputMethod.HTTP:
            http.client._MAXHEADERS = max(10000, env.instrument_args.basic_blocks)

        start_node = self._make_start_node(self._endpoint_urls[0])
        self._session_node = self._make_session_node(self._endpoint_urls[0])

        self.http_cookies = dict(getattr(args, "cookie_dict", {}))
        self.http_headers = retrieve_headers()
        self.http_headers.update(getattr(args, "extra_headers", {}))

        self._crawler = SingleEndpointQueue(start_node)
        self._node_iterator = SingleEndpointNodeIterator()
        self._mutator = Mutator()
        self._parser = NoopParser()
        self._detector = Detector()

        self.stats = Statistics(start_node)
        self.stats.login_calls = self.login_calls
        self.stats.crawler_pending_urls = self._crawler.pending_requests
        self.stats.crawler_login_state = "logged-in" if self.http_cookies else "logged-out"

        self._set_endpoint_display(1)
        self._feedback_mode_display = args.feedback_mode.value

        logger.info(
            "Fixed-endpoint campaign configured with %d endpoint(s), schedule=%s; "
            "first target: %s %s",
            len(self._endpoint_urls),
            self._endpoint_schedule,
            args.method.name,
            start_node.full_url,
        )
        logger.info("Loaded %d user-supplied cookies", len(self.http_cookies))

    def _make_start_node(self, url: str, seed_index: int = 1) -> Node:
        params = {
            HTTPMethod.GET: {},
            HTTPMethod.POST: deepcopy(getattr(self.args, "post_params", {})),
        }
        start_node = Node(url=urlparse(url), method=self.args.method, params=params)
        start_node._single_endpoint_seed = True
        start_node._single_endpoint_seed_index = seed_index
        start_node._single_endpoint_seed_total = len(self._endpoint_urls)
        start_node._single_endpoint_seed_url = url
        return start_node

    def _make_session_node(self, endpoint_url: str) -> Node:
        session_check_url = getattr(self.args, "session_check_url", "") or endpoint_url
        return Node(url=urlparse(session_check_url), method=HTTPMethod.GET, label="session_check")

    def _set_endpoint_display(self, endpoint_index: int) -> None:
        total = len(self._endpoint_urls)
        endpoint_suffix = f" {endpoint_index}/{total}" if total > 1 else ""
        self._wut_name_display = (getattr(self.args, "wut_name", "") or "single-endpoint") + endpoint_suffix

    def _activate_endpoint(self, endpoint_index: int) -> None:
        logger = get_logger(__name__)
        endpoint_url = self._endpoint_urls[endpoint_index - 1]
        start_node = self._make_start_node(endpoint_url)

        self.args.URL = endpoint_url
        self.args.endpoint_index = endpoint_index
        self.args.endpoint_total = len(self._endpoint_urls)
        self.args.endpoint_stop_requested = False
        self.args.endpoint_time_budget_expired = False

        now = time.monotonic()
        self.args.endpoint_start_monotonic = now
        if self.args.endpoint_time_budget:
            self.args.endpoint_deadline_monotonic = now + self.args.endpoint_time_budget
        else:
            self.args.endpoint_deadline_monotonic = 0.0

        self._session_node = self._make_session_node(endpoint_url)
        self._crawler = SingleEndpointQueue(start_node)
        self._node_iterator.reset_endpoint_corpus()
        self.stats.current_node = start_node
        self.stats.crawler_pending_urls = self._crawler.pending_requests
        self._set_endpoint_display(endpoint_index)

        budget = self.args.endpoint_time_budget
        if budget:
            logger.warning(
                "Starting endpoint %d/%d for up to %ds: %s %s",
                endpoint_index,
                len(self._endpoint_urls),
                budget,
                self.args.method.name,
                start_node.full_url,
            )
        else:
            logger.warning(
                "Starting endpoint %d/%d with no endpoint time budget: %s %s",
                endpoint_index,
                len(self._endpoint_urls),
                self.args.method.name,
                start_node.full_url,
            )

    def _activate_blended_endpoints(self) -> None:
        logger = get_logger(__name__)
        start_nodes = [
            self._make_start_node(endpoint_url, seed_index)
            for seed_index, endpoint_url in enumerate(self._endpoint_urls, start=1)
        ]

        self.args.URL = self._endpoint_urls[0]
        self.args.endpoint_index = 0
        self.args.endpoint_total = len(self._endpoint_urls)
        self.args.endpoint_stop_requested = False
        self.args.endpoint_time_budget_expired = False
        self.args.endpoint_start_monotonic = time.monotonic()
        self.args.endpoint_deadline_monotonic = 0.0

        self._session_node = self._make_session_node(self._endpoint_urls[0])
        self._crawler = SingleEndpointQueue(start_nodes)
        self._node_iterator.reset_endpoint_corpus()
        self.stats.current_node = start_nodes[0]
        self.stats.crawler_pending_urls = self._crawler.pending_requests
        self._wut_name_display = (
            (getattr(self.args, "wut_name", "") or "fixed-endpoint")
            + f" blend {len(self._endpoint_urls)}"
        )

        logger.warning(
            "Starting blended endpoint campaign with %d seed endpoint(s); "
            "campaign coverage will be aggregated across the full seed set",
            len(self._endpoint_urls),
        )
        for index, start_node in enumerate(start_nodes, start=1):
            logger.warning(
                "Blended endpoint seed %d/%d: %s %s",
                index,
                len(start_nodes),
                self.args.method.name,
                start_node.full_url,
            )

    @asynccontextmanager
    async def http_session(
        self,
        cookies: Dict[str, str],
        headers: Dict[str, str],
        conn_count: int,
    ) -> AsyncIterator[ClientSession]:
        logger = get_logger(__name__)
        logger.info("New single-endpoint session to be created")

        timeout = aiohttp.ClientTimeout(total=env.args.request_timeout)
        trace_configs = [rtt_trace_config()]
        conn = aiohttp.TCPConnector(limit=conn_count, limit_per_host=conn_count)
        cookie_jar = aiohttp.CookieJar(unsafe=True)

        async with aiohttp.ClientSession(
            cookies=cookies,
            headers=headers,
            connector=conn,
            cookie_jar=cookie_jar,
            timeout=timeout,
            trace_configs=trace_configs,
        ) as session:
            yield session

    async def _settle_after_first_worker(self) -> None:
        sleep_for = 8.0
        deadline = getattr(self.args, "endpoint_deadline_monotonic", 0.0)
        if deadline:
            sleep_for = max(0.0, min(sleep_for, deadline - time.monotonic()))
        if sleep_for:
            await asyncio.sleep(sleep_for)

    async def _run_active_endpoint_workers(self, session: ClientSession) -> ExitCode:
        logger = get_logger(__name__)
        logger.info("Spawning %d single-endpoint workers", self.worker_count)

        exit_code = ExitCode.NONE
        workers: List[asyncio.Task] = []
        for count in range(self.worker_count):
            worker_id = str(random.randrange(10000, 1000000))
            worker = SingleEndpointWorker(
                worker_id,
                session,
                self._crawler,
                self._mutator,
                self._parser,
                self._detector,
                self._node_iterator,
                self._session_node,
                self.stats,
            )

            workers.append(worker.async_run())

            if count == 0:
                await self._settle_after_first_worker()

            if env.shutdown_signal != ExitCode.NONE or self.args.endpoint_stop_requested:
                break

        for worker in workers:
            worker_exit_code = await worker
            if worker_exit_code != ExitCode.NONE:
                exit_code = worker_exit_code

        if env.shutdown_signal != ExitCode.NONE:
            return env.shutdown_signal
        if self.args.endpoint_stop_requested:
            return ExitCode.TIMEOUT

        return exit_code

    async def _run_with_login_retries(self) -> ExitCode:
        logger = get_logger(__name__)

        while True:
            if env.args.session and not self.http_cookies and not env.skip_session_check:
                if not await self.attempt_login():
                    if self.login_calls < MAX_LOGIN_CALLS:
                        continue
                    self.continue_logged_out()

            async with self.http_session(
                self.http_cookies,
                self.http_headers,
                self.worker_count,
            ) as session:
                exit_code = await self._run_active_endpoint_workers(session)

            if (
                exit_code == ExitCode.LOGGED_OUT
                and env.args.session
                and not env.skip_session_check
            ):
                self.http_cookies = {}
                self.stats.crawler_login_state = "logged-out"
                if self.login_calls < MAX_LOGIN_CALLS:
                    logger.warning(
                        "Session is logged out; calling login again (%d call(s) remain)",
                        MAX_LOGIN_CALLS - self.login_calls,
                    )
                    continue
                self.continue_logged_out()
                continue

            return exit_code

    async def _run_blended_loop(self) -> ExitCode:
        logger = get_logger(__name__)
        self._activate_blended_endpoints()

        exit_code = await self._run_with_login_retries()
        if exit_code == ExitCode.EMPTY_QUEUE:
            self.args.all_endpoints_completed = True
            logger.warning(
                "Completed blended endpoint campaign; campaign coverage is %.4f%%",
                self.stats.total_cover_score,
            )

        return exit_code

    async def _run_sequential_loop(self) -> ExitCode:
        logger = get_logger(__name__)
        exit_code = ExitCode.NONE
        completed_by_endpoint_budget = False

        for endpoint_index in range(1, len(self._endpoint_urls) + 1):
            self._activate_endpoint(endpoint_index)

            exit_code = await self._run_with_login_retries()

            if env.shutdown_signal != ExitCode.NONE:
                break
            if exit_code == ExitCode.BUDGET_REACHED:
                break
            if exit_code == ExitCode.TIMEOUT:
                if self.args.endpoint_time_budget_expired:
                    completed_by_endpoint_budget = True
                    logger.warning(
                        "Completed endpoint %d/%d; campaign coverage is %.4f%%",
                        endpoint_index,
                        len(self._endpoint_urls),
                        self.stats.total_cover_score,
                    )
                    continue
                break
            if exit_code == ExitCode.EMPTY_QUEUE:
                logger.warning(
                    "Completed endpoint %d/%d early due to lack of fuzz targets; "
                    "campaign coverage is %.4f%%",
                    endpoint_index,
                    len(self._endpoint_urls),
                    self.stats.total_cover_score,
                )
                continue
            if exit_code != ExitCode.NONE:
                break
        else:
            self.args.all_endpoints_completed = True
            if completed_by_endpoint_budget:
                exit_code = ExitCode.TIMEOUT
            elif exit_code == ExitCode.NONE:
                exit_code = ExitCode.EMPTY_QUEUE

        return exit_code

    async def fuzzer_loop(self) -> ExitCode:
        logger = get_logger(__name__)
        if self._endpoint_schedule == "blend":
            exit_code = await self._run_blended_loop()
        else:
            exit_code = await self._run_sequential_loop()

        env.shutdown_signal = exit_code
        logger.warning("Shutting Down...")
        logging.shutdown()

        return env.shutdown_signal
