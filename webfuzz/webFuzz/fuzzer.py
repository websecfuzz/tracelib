import aiohttp
import asyncio
import curses
import http.client
import importlib.util
import inspect
import json
import logging
import os
import random
import signal
from urllib.parse    import urlparse

from typing          import ContextManager, List, AsyncIterator, Dict
from aiohttp.client  import ClientSession
from aiohttp.tracing import TraceConfig
from contextlib      import asynccontextmanager

from .worker        import Worker

from .environment   import env
from .node          import Node
from .types         import Arguments, FuzzerLogger, InstrumentArgs, OutputMethod, get_logger, HTTPMethod, Statistics, ExitCode, RunMode, FeedbackMode
from .misc          import retrieve_headers, sigalarm_handler, sigint_handler, rtt_trace_config
from .mutator       import Mutator
from .node_iterator import NodeIterator
from .crawler       import Crawler
from .browser       import Browser
from .parser        import Parser
from .detector      import Detector
from .simple_menu   import Simple_menu

MAX_LOGIN_CALLS = 3

class Fuzzer:
    def __init__(self, args: Arguments) -> None:
        """
            Initialisation of a webFuzz instance
        """
        env.args = args

        env.skip_session_check = False

        FuzzerLogger.init_logging(args)

        logger = get_logger(__name__)
        logger.debug(args)

        self.worker_count = args.worker
        self.login_calls = 0

        if args.feedback_mode == FeedbackMode.NATIVE:
            meta = json.loads(open(args.meta_file).read())

            env.instrument_args = InstrumentArgs(meta)
        else:

            env.instrument_args = InstrumentArgs.synthetic(
                basic_blocks=args.tracelib_bitmap_size,
                edges=args.tracelib_bitmap_size,
            )
        logger.debug(env.instrument_args)

        if env.instrument_args.output_method == OutputMethod.HTTP:

            http.client._MAXHEADERS = max(10000, env.instrument_args.basic_blocks)

        self._session_node = Node(url=urlparse(args.URL), method=HTTPMethod.GET, label="session_check")
        start_node = Node(url=urlparse(args.URL), method=HTTPMethod.GET)
        initial_seed = set([start_node])

        cookies = {}
        if args.proxy:
            b = Browser(args.driver_file, proxy_port=args.proxy_port)
            result = b.run_browser(start_node)

            if args.session:
                cookies = result.cookies
            if args.proxy:
                initial_seed.update(result.nodes)

        self.http_cookies = cookies
        logger.debug("Initial Seed: %s", initial_seed)

        headers = retrieve_headers()
        self.http_headers = headers

        self._crawler = Crawler(block_rules=args.block,
                                init_seed=initial_seed,
                                per_base_limit=args.crawler_per_base_limit,
                                seed_file=args.seed_file)

        self._node_iterator = NodeIterator()

        self._mutator = Mutator()

        self._parser = Parser()

        self._detector = Detector()

        self.stats = Statistics(start_node)
        self.stats.login_calls = self.login_calls
        self.stats.crawler_login_state = "logged-out"
        if cookies:
            self.stats.crawler_login_state = "logged-in"

    async def run_auto_login_script(self, script_path: str) -> Dict[str, str]:
        logger = get_logger(__name__)

        if not script_path:
            return {}

        resolved_path = script_path
        if not os.path.isabs(resolved_path):
            resolved_path = os.path.abspath(resolved_path)

        if not os.path.isfile(resolved_path):
            logger.warning("Auto-login script not found: %s", resolved_path)
            return {}

        spec = importlib.util.spec_from_file_location("webfuzz_auto_login", resolved_path)
        if spec is None or spec.loader is None:
            logger.warning("Failed to load auto-login script: %s", resolved_path)
            return {}

        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        login_main = getattr(module, "main", None)
        if login_main is None:
            logger.warning("Auto-login script %s has no main(config)", resolved_path)
            return {}

        config: Dict[str, object] = {}
        if inspect.iscoroutinefunction(login_main):
            await login_main(config)
        else:
            login_main(config)

        raw_cookies = config.get("cookies")
        if raw_cookies is None:
            logger.warning("Auto-login script %s did not populate config['cookies']", resolved_path)
            return {}

        cookies: Dict[str, str] = {}
        if isinstance(raw_cookies, dict):
            cookies = {str(k): str(v) for k, v in raw_cookies.items()}
        elif isinstance(raw_cookies, list):
            for cookie in raw_cookies:
                if not isinstance(cookie, dict):
                    continue
                name = cookie.get("name")
                value = cookie.get("value")
                if name is None or value is None:
                    continue
                cookies[str(name)] = str(value)

        if not cookies:
            logger.warning("Auto-login script %s returned empty cookies", resolved_path)
            return {}

        logger.info("Auto-login loaded %d cookies from %s", len(cookies), resolved_path)
        return cookies

    async def attempt_login(self) -> bool:
        """Run the configured login mechanism, at most three times per campaign.

        The counter is incremented before invoking the mechanism, so exceptions,
        missing scripts, and empty cookie results all consume one call. This keeps
        a broken login flow from cycling forever between login and session checks.
        """
        logger = get_logger(__name__)

        if self.login_calls >= MAX_LOGIN_CALLS:
            logger.warning("Login call limit reached (%d/%d)",
                           self.login_calls, MAX_LOGIN_CALLS)
            return False

        self.login_calls += 1
        self.stats.login_calls = self.login_calls
        call_no = self.login_calls
        logger.warning("Calling login (%d/%d)", call_no, MAX_LOGIN_CALLS)

        auto_login_script = self.resolve_auto_login_script()
        auto_login_configured = bool(
            getattr(env.args, "auto_login_script", "") or
            getattr(env.args, "auto_login_dir", "")
        )

        cookies: Dict[str, str] = {}
        try:
            if auto_login_script:
                cookies = await self.run_auto_login_script(auto_login_script)
            elif auto_login_configured:

                logger.warning("Login call %d/%d failed: no auto-login script resolved",
                               call_no, MAX_LOGIN_CALLS)
            else:
                browser = Browser(env.args.driver_file, proxy_port=env.args.proxy_port)
                result = browser.run_browser(self._session_node)
                cookies = {str(k): str(v) for k, v in result.cookies.items()}
        except Exception as exc:
            logger.warning("Login call %d/%d failed: %s",
                           call_no, MAX_LOGIN_CALLS, exc, exc_info=False)

        self.http_cookies = cookies
        if cookies:
            self.stats.crawler_login_state = "logged-in"
            logger.warning("Login call %d/%d succeeded", call_no, MAX_LOGIN_CALLS)
            return True

        self.stats.crawler_login_state = "logged-out"
        logger.warning("Login call %d/%d produced no session cookies",
                       call_no, MAX_LOGIN_CALLS)
        return False

    def continue_logged_out(self) -> None:
        """Disable further login checks and let the campaign run anonymously."""
        logger = get_logger(__name__)
        self.http_cookies = {}
        self.stats.crawler_login_state = "logged-out"
        self.stats.login_calls = self.login_calls
        env.skip_session_check = True
        logger.warning(
            "Login call limit exhausted (%d/%d); continuing in logged-out mode",
            self.login_calls, MAX_LOGIN_CALLS)

    def resolve_auto_login_script(self) -> str:
        """
            Resolve auto-login script in priority order:
              1) --auto_login_script
              2) --auto_login_dir + WUT name

            WUT name lookup order:
              a) --wut_name
              b) env WUT_NAME
              c) URL hostname first label (if not localhost/IP)
        """
        logger = get_logger(__name__)

        script_path = getattr(env.args, "auto_login_script", "")
        if script_path:
            return script_path

        auto_login_dir = getattr(env.args, "auto_login_dir", "")
        if not auto_login_dir:
            return ""

        wut_name = getattr(env.args, "wut_name", "") or os.environ.get("WUT_NAME", "")
        if not wut_name:
            host = urlparse(env.args.URL).hostname or ""
            if host and host not in ("localhost", "127.0.0.1", "::1"):
                wut_name = host.split(".")[0]

        wut_name = str(wut_name).strip().lower()
        if not wut_name:
            logger.info("Auto-login dir is set but WUT name is unknown; running anonymous")
            return ""

        candidate = os.path.join(auto_login_dir, f"{wut_name}.py")
        if os.path.isfile(candidate):
            return candidate

        logger.info("Auto-login script not found for WUT '%s' at %s; running anonymous", wut_name, candidate)
        return ""

    @asynccontextmanager
    async def http_session(self,
                           cookies: Dict[str, str],
                           headers: Dict[str, str],
                           conn_count: int) -> AsyncIterator[ClientSession]:
        logger = get_logger(__name__)
        logger.info("New session to be created")

        timeout = aiohttp.ClientTimeout(total=env.args.request_timeout)
        trace_configs = [rtt_trace_config()]

        conn = aiohttp.TCPConnector(limit=conn_count, limit_per_host=conn_count)

        async with aiohttp.ClientSession(cookies=cookies,
                                         headers=headers,
                                         connector=conn,
                                         timeout=timeout,
                                         trace_configs=trace_configs) as s:
            yield s

    async def fuzzer_loop(self) -> ExitCode:
        logger = get_logger(__name__)
        exit_code = ExitCode.NONE

        while True:
            if env.args.session and not self.http_cookies and not env.skip_session_check:
                if not await self.attempt_login():
                    if self.login_calls < MAX_LOGIN_CALLS:

                        continue
                    self.continue_logged_out()

            async with self.http_session(self.http_cookies,
                                         self.http_headers,
                                         self.worker_count) as s:

                logger.info("Spawning %d workers", self.worker_count)

                workers: List[asyncio.Task] = []
                for count in range(self.worker_count):
                    worker_id = str(random.randrange(10000, 1000000))
                    worker = Worker(worker_id,
                                    s,
                                    self._crawler,
                                    self._mutator,
                                    self._parser,
                                    self._detector,
                                    self._node_iterator,
                                    self._session_node,
                                    self.stats)

                    workers.append(worker.async_run())

                    if count == 0:

                        await asyncio.sleep(8)

                    if env.shutdown_signal != ExitCode.NONE:
                        break

                for worker in workers:
                    exit_code = await worker

            if exit_code == ExitCode.LOGGED_OUT and env.args.session \
                    and not env.skip_session_check:
                self.http_cookies = {}
                self.stats.crawler_login_state = "logged-out"
                if self.login_calls < MAX_LOGIN_CALLS:
                    logger.warning(
                        "Session is logged out; calling login again (%d call(s) remain)",
                        MAX_LOGIN_CALLS - self.login_calls)
                    continue
                self.continue_logged_out()
                continue

            break

        env.shutdown_signal = exit_code
        logger.warning('Shutting Down...')
        logging.shutdown()

        return env.shutdown_signal

    """
        Starting point for the Fuzzer execution with simple print interface. Here you can specify
        async tasks to run *concurrently* and register async safe Signal Handlers
    """
    async def async_run(self, interface) -> ExitCode:
        loop = asyncio.get_running_loop()
        loop.add_signal_handler(signal.SIGINT, sigint_handler)
        loop.add_signal_handler(signal.SIGALRM, sigalarm_handler)

        interface_task = asyncio.create_task(interface.run(self))
        fuzzer_loop_task = asyncio.create_task(self.fuzzer_loop())

        exit_code = await fuzzer_loop_task
        await interface_task

        return exit_code

    def run(self) -> ExitCode:
        if env.args.run_mode == RunMode.SIMPLE:
            interface = Simple_menu(print_to_file=False)
        elif env.args.run_mode == RunMode.FILE:
            interface = Simple_menu(print_to_file=True)
        else:
            raise Exception("Curses interface not available")

        return asyncio.run(self.async_run(interface))
