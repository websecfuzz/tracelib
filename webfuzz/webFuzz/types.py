from __future__ import annotations

import logging
from logging import FileHandler

from tap          import Tap
from typing       import Any, List, Dict, Set, Union, NamedTuple, Optional, Literal
from enum         import Enum
from os           import mkdir, unlink, symlink
from datetime     import datetime
from jsonschema   import validate
from urllib.parse import ParseResult

VERSION = 1.2

Label = int
Bucket = int
UrlType = ParseResult

Numeric = Union[int, float]

CFG = Dict[Label, Bucket]
CFGTuple = NamedTuple("CFGTuple", [("xor_cfg", CFG), ("single_cfg", CFG)])

class FuzzerException(Exception):
   pass

class ExtendedEnum(Enum):
    def __str__(self):
        return str(self.name)
    def __repr__(self):
        return self.__str__()
    def __lt__(self, obj):
        return self.value < obj.value

class RequestStatus(ExtendedEnum):
    SUCCESS_INTERESTING = 0
    SUCCESS_NOT_INTERESTING = 1
    SUCCESS_FOUND_PHRASE = 2
    UNSUCCESSFUL_REQUEST = 3

class InvalidContentType(Exception):
    pass

class InvalidHttpCode(Exception):
    pass

class UnimplementedHttpMethod(Exception):
    pass

class ExitCode(ExtendedEnum):
    NONE = 0
    USER = 1
    EMPTY_QUEUE = 2
    TIMEOUT = 3
    LOGGED_OUT = 4
    BUDGET_REACHED = 5

class HTTPMethod(ExtendedEnum):
    GET = 0
    POST = 1

class XSSConfidence(ExtendedEnum):
    NONE = 0
    LOW = 1
    MEDIUM = 2
    HIGH = 3

BlockRule = NamedTuple("BlockRule", [("url",str), ("key",str), ("val", str), ("method", Optional[HTTPMethod])])
Params = Dict[HTTPMethod, Dict[str, List[str]]]

class Statistics():
    current_cover_score: float = 0.0
    total_cover_score: float = 0.0
    crawler_pending_urls: int = 0
    crawler_login_state: str = "logged-out"
    login_calls: int = 0
    total_requests: int = 0
    total_xss: int = 0

    fuzz_requests: int = 0
    fuzz_started: bool = False
    fuzz_start_wall: float = 0.0
    fuzz_start_monotonic: float = 0.0
    crawl_requests_at_fuzz_start: int = 0
    current_node: Any

    def __init__(self, initial_node):
        self.current_node = initial_node
        self.login_calls = 0

class RunMode(ExtendedEnum):
    SIMPLE = "simple"
    FILE = "file"
    AUTO = "auto"
    MANUAL = "manual"

class FeedbackMode(ExtendedEnum):
    """
        NATIVE   — use webFuzz's own ast-instrumented PHP coverage
                   (requires instr.meta + instrumented source).
        BLACKBOX — ignore coverage entirely; every crawled/mutated node is
                   accepted into the queue. The baseline for comparisons.
        TRACELIB — feed per-request bitmaps produced by TraceLib on the host
                   (each 65536-byte file at <bitmap-dir>/<X-REQUEST-ID>).
                   No PHP-level instrumentation required.
    """
    NATIVE   = "native"
    BLACKBOX = "blackbox"
    TRACELIB = "tracelib"

class Arguments(Tap):
    verbose: int = 0
    """Increase verbosity"""

    seed_file: Optional[str] = None
    """Read initial URL seed from file"""

    allow_non_html: bool = False
    """Allow non-HTML responses as coverage-bearing requests; link extraction is skipped"""

    session: bool = False
    """Retrieve cookies from a browser session"""

    catch_phrase: str = ""
    """Catch phrase to search for when checking if we are logged in"""

    proxy: bool = False
    """Enable Proxy mode. Retrieves URLs executed from a browser session"""

    proxy_port: int = 8090
    """Set the port the proxy should listen to"""

    ignore_404: bool = False
    """Do not fuzz links that return 404 code"""

    ignore_4xx: bool = False
    """Do not fuzz links that return 4xx code"""

    http_error_at_info: bool = False
    """Log Http errors at info level (Default is at Warning)"""

    meta_file: str = "./instr.meta"
    "Specify the location of instrumentation meta file (instr.meta)"

    block: List[BlockRule] = []
    """Specify a link to block the fuzzer from using, Format = 'url|parameter|value|method'"""

    worker: int = 1
    """Specify the number of workers to spawn that will concurrently send requests"""

    crawler_per_base_limit: int = 2000
    """ Crawler checks if the base url of the new request did not surpass this limit.
        This is a simple way to stop urls with nonce parameter to be constantly sent"""

    uniq_frag: bool = False
    """Treat urls with different fragments as different urls"""

    driver_file: str = "webFuzz/drivers/geckodriver"
    """Specify the location of the web driver (used in -s flag)"""

    request_timeout: int = 100
    """Set the per request timeout in seconds"""

    run_mode: RunMode = RunMode.SIMPLE
    """Select the run mode. Modes: auto, manual, simple, file"""

    feedback_mode: FeedbackMode = FeedbackMode.NATIVE
    """Feedback source used to guide the fuzzer.
       native   = ast-instrumented PHP (default; requires instr.meta)
       blackbox = no coverage feedback; accept every node
       tracelib = read per-request bitmap from --tracelib-bitmap-dir/<id>"""

    tracelib_bitmap_dir: str = "/dev/shm"
    """Directory where TraceLib writes per-request bitmaps (used only when
       --feedback-mode=tracelib)"""

    tracelib_header: str = "X-REQUEST-ID"
    """Request-id header name TraceLib demultiplexes on (used only when
       --feedback-mode=tracelib)"""

    tracelib_bitmap_size: int = 65536
    """Expected bitmap size in bytes (default 65536 matches TraceLib)"""

    tracelib_novelty: Literal["bucket", "index"] = "bucket"
    """Corpus-admission rule for --feedback-mode=tracelib.
       bucket (default) = same rule as native ast feedback: a request is
                          interesting if it reaches a bitmap index never seen
                          before, OR reaches a known index in a hit-count
                          bucket never seen for that index.
       index            = strict positional novelty: only a bitmap index never
                          seen before counts; a change in hit-count bucket
                          alone does not retain the request."""

    fuzz_request_budget: int = 0
    """Request-budget evaluation schema. Stop the campaign once this many
       FUZZING-phase (mutated) requests have been issued; crawling requests
       are NOT counted and crawling is otherwise unlimited. 0 (default) keeps
       the legacy time-budget behaviour (no request-based stop)."""

    max_corpus_size: int = 0
    """Upper bound on the number of inputs (nodes) kept in the corpus. Once the
       corpus reaches this size, newly-discovered inputs are NOT added (the
       fuzzer keeps mutating the existing corpus). Bounds memory on long (24h+)
       campaigns — most useful for blackbox, which otherwise accepts every node.
       0 (default) = unlimited (legacy behaviour)."""

    auto_login_script: str = ""
    """Optional path to a Python auto-login script.
       The script must expose async `main(config)` and set
       config['cookies'] to either a dict(name->value) or a list of
       browser-cookie dicts containing name/value fields."""

    auto_login_dir: str = ""
    """Optional directory that contains WUT login scripts named
       <wut>.py (for example nodebb.py)."""

    wut_name: str = ""
    """Target WUT identifier used for auto-login script lookup."""

    re_login: bool = False
    """Deprecated compatibility flag. Re-login is now automatic whenever a
       session is detected as logged out, with a hard campaign-wide limit of
       three login calls. The flag is still accepted so existing campaign
       commands do not fail."""

    URL: str
    'Specify the inital URL to start fuzzing from'

    def __init__(self):
        super().__init__(description='webFuzz is a grey-box fuzzer for web applications.',
                         usage='%(prog)s [options] -r/--run <mode> <URL>',
                         add_help=True)

    @staticmethod
    def parse_single_block_opt(value: str) -> BlockRule:
        (url, key, val, meth) = value.split("|")

        if not meth or meth == '*':
            meth = None
        else:
            meth = HTTPMethod[meth.upper()]
        return BlockRule(url=url, key=key, val=val, method=meth)

    def configure(self) -> None:
        self.add_argument('-v', '--verbose', action='count')
        self.add_argument('-p', '--proxy')
        self.add_argument('-s', '--session')
        self.add_argument('--seed_file')
        self.add_argument('--allow_non_html', action='store_true')
        self.add_argument('-m', '--meta_file')
        self.add_argument('-b', '--block', type=Arguments.parse_single_block_opt, action='append')
        self.add_argument('-w', '--worker')
        self.add_argument('-r', '--run_mode', type=RunMode)
        self.add_argument('--feedback_mode', type=FeedbackMode)
        self.add_argument('--auto_login_script')
        self.add_argument('--auto_login_dir')
        self.add_argument('--wut_name')
        self.add_argument('--re_login', action='store_true')
        self.add_argument('URL')

        self.add_argument('--version', help="Prints webFuzz latest version", action='version',
                          version='webFuzz v{VERSION}'.format(VERSION=VERSION))

INSTR_META_SCHEMA = {
    "title": "instrument-meta",
    "type": "object",
    "properties": {
        "basic-block-count": { "type": "integer"},
        "output-method": {
            "type": "string",
            "pattern": "^(file|http)$"
        },
        "instrument-policy": {
            "type": "string",
            "pattern": "^(edge|node-edge|node)$"
        },
        "edge-count": { "type": "integer"}
    },
    "required": ["basic-block-count", "output-method", "instrument-policy"]
}

class OutputMethod(ExtendedEnum):
    FILE = 0
    HTTP = 1

class Policy(ExtendedEnum):
    NODE = 0
    EDGE = 1
    NODE_EDGE = 2

class InstrumentArgs():
    basic_blocks: int
    edges: int
    output_method: OutputMethod
    policy: Policy

    def __init__(self, meta_json):
        validate(instance=meta_json, schema=INSTR_META_SCHEMA)

        self.basic_blocks = int(meta_json['basic-block-count'])
        self.output_method = OutputMethod[meta_json['output-method'].upper()]
        self.policy = Policy[meta_json['instrument-policy'].upper().replace('-', '_')]

        if self.policy != Policy.NODE:
            self.edges = int(meta_json['edge-count'])

    @classmethod
    def synthetic(cls, basic_blocks: int = 65536, edges: int = 65536) -> "InstrumentArgs":
        """
            Build an InstrumentArgs without an instr.meta file. Used when the
            feedback source is not ast-instrumented PHP (blackbox mode) or when
            coverage comes from an out-of-process source like TraceLib.
            The output_method here is never consumed on the fuzzer side — the
            relevant code paths are short-circuited by the feedback mode.
        """
        self = cls.__new__(cls)
        self.basic_blocks = basic_blocks
        self.edges = edges
        self.output_method = OutputMethod.FILE
        self.policy = Policy.EDGE
        return self

class FuzzerLogger(logging.Logger):

    @staticmethod
    def init_logging(args: Arguments) -> None:

        logging.setLoggerClass(FuzzerLogger)

        file_handler = FuzzerLogger.mk_file_handler()

        rootLogger = get_logger()
        rootLogger.addHandler(file_handler)

        levels = [logging.ERROR,
                  logging.WARNING,
                  logging.INFO,
                  logging.DEBUG]

        rootLogger.setLevel(levels[min(args.verbose, 4)])

    @staticmethod
    def mk_file_handler() -> FileHandler:
        try:
            mkdir("./log")
        except FileExistsError:
            pass

        try:
            unlink("fuzzer.log")
        except FileNotFoundError:
            pass

        dt = datetime.now()
        filename = f"./log/webFuzz_{dt.day}-{dt.month}_{dt.hour}:{dt.minute}.log"

        symlink(filename, "./fuzzer.log")

        file_handler = logging.FileHandler(filename)
        file_handler.setFormatter(CustomFormatter())

        return file_handler

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

def get_logger(name: str = "", worker_id: str = "") -> FuzzerLogger:
    name += "/" + worker_id if worker_id else ""

    return logging.getLogger(name)

class CustomFormatter(logging.Formatter):
    """
        Logging Formatter to add colors and add worker id to log entry
    """
    green = "\x1b[32;11m"
    grey = "\x1b[37;11m"
    cyan = "\x1b[96;11m"
    yellow = "\x1b[33;11m"
    red = "\x1b[31;21m"
    bold_red = "\x1b[31;21m"
    reset = "\x1b[0m"

    level_color = {
        logging.DEBUG: grey,
        logging.INFO: cyan,
        logging.WARNING: yellow,
        logging.ERROR: red,
        logging.CRITICAL: bold_red
    }

    default_fmt = "[%(asctime)s] %(name)s %(levelname)s %(funcName)s(%(lineno)d) %(message)s"

    def format(self, record):

        if '/' in record.name:
            (logname, work_id) = record.name.split('/')
            record.name = logname
            worker_fmt = f"[%(asctime)s] %(name)s %(levelname)s [Worker {work_id}] %(funcName)s(%(lineno)d) %(message)s"
            format_str = worker_fmt
        else:
            format_str = self.default_fmt

        fmt = self.level_color[record.levelno] + format_str + self.reset

        formatter = logging.Formatter(fmt)
        return formatter.format(record)
