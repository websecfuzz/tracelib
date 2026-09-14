import asyncio
import hashlib
import json
import logging
import os
import signal
import time
import uuid

from aiohttp      import ClientSession,ClientResponse
from bs4          import BeautifulSoup
from typing       import Generator, Union, Optional, Dict, Iterator, AsyncIterator
from itertools    import repeat
from contextlib   import asynccontextmanager

from .environment   import env
from .node          import Node
from .types         import FuzzerLogger, get_logger, HTTPMethod, RequestStatus, Statistics, ExitCode, UnimplementedHttpMethod, InvalidContentType, InvalidHttpCode, XSSConfidence, FeedbackMode, CFGTuple
from .misc          import iter_join, lazyFunc
from .mutator       import Mutator
from .node_iterator import NodeIterator
from .crawler       import Crawler
from .parser        import Parser
from .detector      import Detector
from .browser       import Browser

LOGGED_IN_CHECK_INTERVAL = 50

class Worker():
    def __init__(self,
                 id_: str,
                 session: ClientSession,
                 crawler: Crawler,
                 mutator: Mutator,
                 parser: Parser,
                 detector: Detector,
                 iterator: NodeIterator,
                 session_node: Node,
                 statistics: Statistics):

        self.id = id_
        self._session = session
        self._crawler = crawler
        self._mutator = mutator
        self._parser = parser
        self._detector = detector
        self._node_iterator = iterator
        self._session_node = session_node
        self._stats = statistics
        self._external_reference_failures = 0
        self._external_reference_disabled = False

    @property
    def asyncio_task(self) -> Optional[asyncio.Task]:
        if hasattr(self, "_task"):
            return self._task
        else:
            return None

    def async_run(self):
        self._task = asyncio.create_task(self.run_worker())
        return self._task

    def update_stats(self, current_node: Node):
        self._stats.total_cover_score = self._node_iterator.total_cover_score
        self._stats.current_node = current_node
        self._stats.crawler_pending_urls = self._crawler.pending_requests
        self._stats.total_xss = self._detector.xss_count

    async def _terminate_external_reference_process(self, process: asyncio.subprocess.Process) -> None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        except Exception:
            try:
                process.terminate()
            except ProcessLookupError:
                return
            except Exception:
                pass

        try:
            await asyncio.wait_for(process.wait(), timeout=2)
            return
        except asyncio.TimeoutError:
            pass

        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        except Exception:
            try:
                process.kill()
            except ProcessLookupError:
                return
            except Exception:
                pass
        try:
            await asyncio.wait_for(process.wait(), timeout=2)
        except Exception:
            pass

    def _note_external_reference_failure(self, logger: FuzzerLogger) -> None:
        self._external_reference_failures += 1
        if self._external_reference_failures >= 3 and not self._external_reference_disabled:
            self._external_reference_disabled = True
            logger.warning("external reference feedback disabled after %d consecutive failures", self._external_reference_failures)

    async def _run_external_reference_command(self,
                                              command_env: str,
                                              parse_json: bool) -> Optional[object]:
        command = os.environ.get(command_env, "")
        if not command or self._external_reference_disabled:
            return None

        logger = get_logger(__name__, self.id)
        timeout = float(os.environ.get("WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_TIMEOUT", "15"))
        process: Optional[asyncio.subprocess.Process] = None
        try:
            process = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                start_new_session=True,
            )
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            if process is not None:
                await self._terminate_external_reference_process(process)
            logger.warning("external reference feedback command timed out")
            self._note_external_reference_failure(logger)
            return {"error": "timeout"}
        except Exception as exc:
            logger.warning("external reference feedback command failed: %s", exc)
            self._note_external_reference_failure(logger)
            return {"error": str(exc)}

        stdout_text = stdout.decode("utf-8", errors="replace").strip()
        stderr_text = stderr.decode("utf-8", errors="replace").strip()
        if process.returncode != 0:
            logger.warning(
                "external reference feedback command returned %s: %s",
                process.returncode,
                stderr_text[:500],
            )
            self._note_external_reference_failure(logger)
            return {"error": f"returncode={process.returncode}", "stderr": stderr_text[:1000]}
        self._external_reference_failures = 0
        if not stdout_text:
            return None
        if not parse_json:
            return stdout_text
        try:
            return json.loads(stdout_text)
        except json.JSONDecodeError:
            return {"raw": stdout_text}

    async def _reset_external_reference_feedback(self) -> None:
        await self._run_external_reference_command(
            "WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_RESET_CMD",
            parse_json=False,
        )

    async def _read_external_reference_feedback(self) -> Optional[object]:
        return await self._run_external_reference_command(
            "WEBFUZZ_FEEDBACK_EXTERNAL_COVERAGE_CMD",
            parse_json=True,
        )

    @staticmethod
    def _feedback_feature_hash(cfg: CFGTuple) -> str:
        """Hash the set of feedback features using the offline export format."""
        features = cfg.xor_cfg.keys() if cfg.xor_cfg else cfg.single_cfg.keys()
        digest = hashlib.sha256()
        for feature in sorted(features):
            digest.update(str(feature).encode("utf-8", errors="replace"))
            digest.update(b"\n")
        return digest.hexdigest()

    def _record_mode_feedback_hash(self,
                                   request: Node,
                                   response_status: int,
                                   cfg: CFGTuple) -> None:
        """Append one compact, cross-mode-alignable feedback observation.

        The processing-time experiment enables this explicitly.  Canonical
        replay ordinal and request SHA-256 fields make Native and TraceLib
        streams joinable without treating their unrelated feature identifiers
        as directly comparable values.
        """
        output_path = os.environ.get("WEBFUZZ_FEEDBACK_HASH_FILE", "")
        if not output_path or request.label == "session_check":
            return

        logger = get_logger(__name__, self.id)
        try:
            feedback_mode = env.args.feedback_mode
            feedback_hash: Optional[str]
            feedback_kind: str
            feature_count: int
            if feedback_mode == FeedbackMode.BLACKBOX:
                feedback_hash = None
                feedback_kind = "none"
                feature_count = 0
            elif feedback_mode == FeedbackMode.NATIVE:
                feedback_hash = self._feedback_feature_hash(cfg)
                feedback_kind = "native_ast_edges"
                feature_count = len(cfg.xor_cfg) if cfg.xor_cfg else len(cfg.single_cfg)
            else:
                feedback_hash = self._feedback_feature_hash(cfg)
                feedback_kind = "tracelib_bitmap_indices"
                feature_count = len(cfg.xor_cfg) if cfg.xor_cfg else len(cfg.single_cfg)

            record = {
                "schema_version": 1,
                "timestamp_ns": time.time_ns(),
                "treatment_mode": os.environ.get(
                    "WEBFUZZ_FEEDBACK_TREATMENT_MODE", feedback_mode.value
                ),
                "feedback_mode": feedback_mode.value,
                "feedback_kind": feedback_kind,
                "feedback_sha256": feedback_hash,
                "feature_count": feature_count,
                "request_ordinal": int(
                    getattr(request, "_request_baseline_ordinal", self._stats.total_requests)
                ),
                "request_baseline_ordinal": getattr(
                    request, "_request_baseline_ordinal", None
                ),
                "request_sha256": getattr(request, "_request_sha256", None),
                "method": request.method.name,
                "url": str(request.full_url),
                "http_status": int(response_status),
            }
            parent = os.path.dirname(os.path.abspath(output_path))
            os.makedirs(parent, exist_ok=True)
            with open(output_path, "a", encoding="utf-8") as output:
                output.write(json.dumps(record, sort_keys=True) + "\n")
                output.flush()
        except Exception as exc:
            logger.warning("could not write mode feedback hash: %s", exc)

    def _record_feedback_manifest(self,
                                  request: Node,
                                  response_status: int,
                                  accepted: bool,
                                  cfg: CFGTuple,
                                  external_reference: Optional[object] = None) -> None:
        """Persist request order for an offline paired-feedback experiment.

        The campaign runner enables this with WEBFUZZ_FEEDBACK_MANIFEST.  The
        AST map and TraceLib bitmap themselves are retained by the runner; this
        JSONL file supplies their common request id and chronological order.
        Capture failures are deliberately non-fatal to normal fuzzing.
        """
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
                "phase": "fuzz" if request.is_mutated else "crawl",
                "params": {
                    method.name: dict(params)
                    for method, params in request.params.items()
                },
                "label": request.label,
                "http_status": response_status,
                "tracelib_nonzero": len(cfg.xor_cfg),
                "tracelib_accepted": bool(accepted),
            }
            if external_reference is not None:
                record["reference_feedback"] = external_reference

            with open(manifest, "a", encoding="utf-8") as output:
                output.write(json.dumps(record, sort_keys=True) + "\n")
                output.flush()
        except Exception as exc:
            logger.warning("could not write feedback manifest: %s", exc)

    @staticmethod
    def has_catchphrase(raw_html: str, catchphrase: str) -> bool:
        if not catchphrase:
            return True

        if catchphrase in raw_html:
            return True

        return False

    @asynccontextmanager
    async def http_send(self, new_request: Node) -> AsyncIterator[ClientResponse]:
        logger = get_logger(__name__, self.id)

        if new_request.method == HTTPMethod.GET:
            aiohttp_send = self._session.get
        elif new_request.method == HTTPMethod.POST:
            aiohttp_send = self._session.post
        else:
            logger.error("Unimplemented HTTP method")
            raise UnimplementedHttpMethod(new_request.method)

        logger.info("sending request: %s", new_request.url)

        req_headers = { 'REQ-ID' : self.id }

        if env.args.feedback_mode == FeedbackMode.TRACELIB:

            rid = "wf-" + uuid.uuid4().hex
            req_headers[env.args.tracelib_header] = rid
            new_request._tracelib_rid = rid

        await self._reset_external_reference_feedback()

        async with aiohttp_send(new_request.url,
                                headers=req_headers,
                                params=new_request.params[HTTPMethod.GET],
                                data=new_request.params[HTTPMethod.POST],

                                allow_redirects=not bool(
                                    getattr(env.args, "request_replay_file", "")
                                ),
                                trace_request_ctx=new_request) as r:

            self._stats.total_requests += 1

            content_type = (r.content_type or '').lower()
            if content_type and content_type != 'text/html' and not env.args.allow_non_html:
                raise InvalidContentType(r.content_type)

            if r.status >= 400:
                logger.info('Got code %d from %s', r.status, r.url)

                if env.args.ignore_404 and r.status == 404:
                    raise InvalidHttpCode(404)

                if env.args.ignore_4xx:
                    raise InvalidHttpCode(r.status)

            yield r

    async def _read_tracelib_bitmap(self, request: Node, rid: Optional[str]) -> CFGTuple:
        """
            Read TraceLib's per-request bitmap (65536 bytes) from disk and
            convert it into a CFGTuple so the rest of the fuzzer can treat
            it identically to ast-instrumented feedback. Returns an empty
            CFGTuple on failure so the request is simply deemed uninteresting.
        """
        logger = get_logger(__name__, self.id)

        if not rid:
            return CFGTuple(xor_cfg={}, single_cfg={})

        bitmap_path = os.path.join(env.args.tracelib_bitmap_dir, rid)
        expected = env.args.tracelib_bitmap_size
        data: Optional[bytes] = None

        for attempt in range(150):
            try:
                with open(bitmap_path, "rb") as f:
                    data = f.read()
                if data is not None and len(data) >= expected:
                    break
            except FileNotFoundError:
                pass
            await asyncio.sleep(0.005 if attempt < 100 else 0.05)

        if data is None or len(data) < expected:
            logger.debug("tracelib bitmap %s not available", bitmap_path)
            return CFGTuple(xor_cfg={}, single_cfg={})

        from .misc import to_bucket
        cfg_xor: Dict[int, int] = {}
        for i, b in enumerate(data[:expected]):
            if b:
                cfg_xor[i] = to_bucket(b)

        request._cover_score_xor = len(cfg_xor)
        request._cover_score_single = 0
        request.__dict__.pop('_json', None)

        return CFGTuple(xor_cfg=cfg_xor, single_cfg={})

    async def process_req(self, request: Node) -> RequestStatus:
        logger = get_logger(__name__, self.id)

        async with self.http_send(request) as r:

            raw_html: str = await r.text(errors="replace")
            is_html = not r.content_type or r.content_type.lower() == 'text/html'

            logger.debug(raw_html)

            if request.label == 'session_check':

                if Worker.has_catchphrase(raw_html, env.args.catch_phrase):
                    logger.info("Success, we are still logged in")
                    self._stats.crawler_login_state = "logged-in"
                    return RequestStatus.SUCCESS_FOUND_PHRASE

            soup = lazyFunc(BeautifulSoup, raw_html, "html5lib") if is_html else None

            if is_html and self._detector.xss_precheck(raw_html):
                self._detector.xss_scanner(request, next(soup))

            mode = env.args.feedback_mode
            if mode == FeedbackMode.TRACELIB:

                rid = getattr(request, "_tracelib_rid", None)
                cfg = await self._read_tracelib_bitmap(request, rid)
            elif mode == FeedbackMode.BLACKBOX:

                cfg = CFGTuple(xor_cfg={}, single_cfg={})
                request._cover_score_xor = 0
                request._cover_score_single = 0
                request.__dict__.pop('_json', None)
            else:
                cfg = request.parse_instrumentation(r.headers, self.id)

            accepted = self._node_iterator.add(request, cfg)
            self._record_mode_feedback_hash(request, r.status, cfg)
            external_reference = await self._read_external_reference_feedback()
            self._record_feedback_manifest(request, r.status, accepted, cfg, external_reference)
            if is_html:
                links = self._parser.parse(request, next(soup))
                self._crawler += links
            else:
                logger.info("Skipping link extraction for non-HTML content-type: %s", r.content_type)
            status = RequestStatus.SUCCESS_INTERESTING if accepted else RequestStatus.SUCCESS_NOT_INTERESTING

            self.update_stats(request)

            logger.info("Request Completed: %s", request)
            if (request._xss_confidence > XSSConfidence['NONE']):
                logger.warning("Suspicious request %s", request)

            return status

    async def run_worker(self) -> ExitCode:
        logger = get_logger(__name__, self.id)
        logger.info("Worker reporting Active")

        if env.args.catch_phrase and not env.skip_session_check:
            periodic = repeat(self._session_node)
        else:

            periodic = repeat(None, 0)

        for (src, new_request) in iter_join(primary=self._crawler,
                                            secondary=self._node_iterator,
                                            periodic=periodic,
                                            interval=LOGGED_IN_CHECK_INTERVAL):
            if src == self._crawler:
                logger.info("Chosen an unvisited node")

            elif src == self._node_iterator:

                new_request = self._mutator.mutate(new_request,
                                                   self._node_iterator.node_list)
                logger.info("Chosen a mutated node")

                self._stats.fuzz_requests += 1
                if not self._stats.fuzz_started:
                    self._stats.fuzz_started = True
                    self._stats.fuzz_start_wall = time.time()
                    self._stats.fuzz_start_monotonic = time.monotonic()
                    self._stats.crawl_requests_at_fuzz_start = self._stats.total_requests
                    logger.warning(
                        "FUZZING PHASE STARTED: first mutated request after "
                        "%d crawl requests (wall=%.3f)",
                        self._stats.total_requests, self._stats.fuzz_start_wall)

            try:
                return_code = await self.process_req(new_request)
            except Exception as e:
                if env.args.http_error_at_info:
                    logger.info(e, exc_info=False)
                else:
                    logger.warning(e, exc_info=False)

                return_code = RequestStatus.UNSUCCESSFUL_REQUEST

            if src == periodic and \
                return_code != RequestStatus.SUCCESS_FOUND_PHRASE:
                logger.warning("Fuzzer has been logged out...")
                self._stats.crawler_login_state = "logged-out"

                return ExitCode.LOGGED_OUT

            budget = getattr(env.args, "fuzz_request_budget", 0)
            if budget and self._stats.fuzz_requests >= budget:
                logger.warning(
                    "FUZZ REQUEST BUDGET reached: %d fuzzing requests "
                    "(budget %d); finishing campaign",
                    self._stats.fuzz_requests, budget)
                env.shutdown_signal = ExitCode.BUDGET_REACHED
                return ExitCode.BUDGET_REACHED

            if env.shutdown_signal != ExitCode.NONE:
                return env.shutdown_signal

        logger.error("Aborting due to lack of fuzz targets")
        return ExitCode.EMPTY_QUEUE
