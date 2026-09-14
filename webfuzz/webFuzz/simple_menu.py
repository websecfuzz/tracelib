import asyncio
import os
import time
import sys

from os             import system
from typing         import Callable, Optional

from .types         import ExitCode, get_logger
from .environment   import env

def clear():
    return system('clear')

_EXT_COV_PATH = os.environ.get("WEBFUZZ_EXTERNAL_COVERAGE_FILE", "")

_EXT_COV_LABEL = os.environ.get("WEBFUZZ_EXTERNAL_COVERAGE_LABEL", "Coverage")
_EXT_COV_MIN_INTERVAL = 30.0
_ext_cov_last_read = 0.0
_ext_cov_cached: Optional[float] = None

def _read_external_coverage() -> Optional[float]:
    global _ext_cov_last_read, _ext_cov_cached
    if not _EXT_COV_PATH:
        return None
    now = time.monotonic()
    if now - _ext_cov_last_read < _EXT_COV_MIN_INTERVAL and _ext_cov_cached is not None:
        return _ext_cov_cached
    _ext_cov_last_read = now
    try:
        with open(_EXT_COV_PATH, "r") as f:
            raw = f.read().strip()
        if raw:
            _ext_cov_cached = float(raw)
    except (OSError, ValueError):
        pass
    return _ext_cov_cached

"""
    A simple front-end interface for displaying fuzzer statistics
"""
class Simple_menu:

    """
        Initialization point
    """
    def __init__(self,
                 print_to_file: bool):

        if print_to_file:
            f = open("/tmp/fuzzer_stats", "w+")

            def fwrite(line):
                f.write(line + "\n")
            def frefresh():
                f.truncate(0)
                f.seek(0)

            self.printer = fwrite
            self.printer_refresh = frefresh
            self.printer_flush = f.flush
        else:
            self.printer = print
            self.printer_refresh = clear
            self.printer_flush = sys.stdout.flush

    """
        Run interface
    """
    async def run(self, fuzzer) -> None:
        logger = get_logger(__name__)

        start_time = time.clock_gettime(time.CLOCK_MONOTONIC)

        past_time = start_time
        past_count = 0
        throughput = 0

        while env.shutdown_signal == ExitCode.NONE:

            await asyncio.sleep(0.5)

            self.printer_refresh()

            current_time = time.clock_gettime(time.CLOCK_MONOTONIC)

            if (current_time - past_time > 2):
                throughput = (fuzzer.stats.total_requests - past_count) / \
                             (current_time - past_time)

                past_count = fuzzer.stats.total_requests
                past_time = current_time

                logger.info("Total Cov: %0.4f, Throughput: %0.2f", \
                            fuzzer.stats.total_cover_score, throughput)

            wut = getattr(fuzzer, "_wut_name_display", None)
            mode = getattr(fuzzer, "_feedback_mode_display", None)
            if wut is None or mode is None:
                args = getattr(fuzzer, "args", None) or getattr(__import__("webFuzz.environment", fromlist=["env"]).env, "args", None)
                if args is not None:
                    if wut is None:
                        wut = getattr(args, "wut_name", "") or "?"
                    if mode is None:
                        fm = getattr(args, "feedback_mode", None)
                        mode = fm.value if hasattr(fm, "value") else (str(fm) if fm else "?")
                fuzzer._wut_name_display = wut
                fuzzer._feedback_mode_display = mode
            self.printer("webFuzz [{}, {}]\n-----\n".format(wut, mode))
            self.printer("Stats\n")

            self.printer('Runtime: {:0.2f} min'.format((current_time - start_time) / 60))
            self.printer('Total Requests: {:d}'.format(fuzzer.stats.total_requests))
            self.printer('Throughput: {:0.2f} requests/s'.format(throughput))
            self.printer('Crawler Pending URLs: {:d}'.format(fuzzer.stats.crawler_pending_urls))
            self.printer('Crawler Login State: {:s}'.format(fuzzer.stats.crawler_login_state))
            self.printer('Login Calls: {:d}'.format(fuzzer.stats.login_calls))
            self.printer('Corpus size: {:d}'.format(len(fuzzer._node_iterator.node_list)))
            self.printer('Current Coverage Score: {:0.4f}%'.format(fuzzer.stats.current_node.cover_score))
            self.printer('Total Coverage Score: {:0.4f}%'.format(fuzzer.stats.total_cover_score))

            ext_cov = _read_external_coverage()
            if ext_cov is not None:
                self.printer('{:s}: {:0.2f}%'.format(_EXT_COV_LABEL, ext_cov))
            self.printer('Possible XSS: {:d}'.format(fuzzer.stats.total_xss))

            self.printer('Executing link: {:s}'.format(fuzzer.stats.current_node.url[:105]))
            self.printer('Response time: {:0.2f} sec'.format(fuzzer.stats.current_node.exec_time))

            if fuzzer.stats.current_node.is_mutated:
                self.printer('State: Fuzzing')
            else:
                self.printer('State: Crawling')

            _budget = getattr(env.args, "fuzz_request_budget", 0)
            self.printer('Fuzz Requests: {:d}'.format(fuzzer.stats.fuzz_requests))
            self.printer('Fuzz Budget: {:d}'.format(_budget))
            self.printer('Fuzz Started: {:s}'.format(
                'yes' if fuzzer.stats.fuzz_started else 'no'))
            if fuzzer.stats.fuzz_started:
                self.printer('Crawl Requests At Fuzz Start: {:d}'.format(
                    fuzzer.stats.crawl_requests_at_fuzz_start))

            self.printer_flush()

        print("Shut Down Initiated. Please wait, this may take a few seconds...")
