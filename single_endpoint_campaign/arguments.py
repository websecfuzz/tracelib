from __future__ import annotations

import argparse
import json
import os
from http.cookies import SimpleCookie
from pathlib import Path
from typing import Dict, Iterable, List, Optional
from urllib.parse import parse_qs

from ._bootstrap import ensure_paths

ensure_paths()

from webFuzz.types import Arguments as WebFuzzArguments
from webFuzz.types import FeedbackMode, HTTPMethod, RunMode

ENDPOINT_SCHEDULES = ("sequential", "blend")
BLACKBOX_CORPUS_MODES = ("seed-only", "keep-submitted")

def _parse_enum(enum_cls):
    def parser(raw: str):
        normalized = raw.strip().upper().replace("-", "_")
        for item in enum_cls:
            if normalized == item.name or raw.strip().lower() == str(item.value).lower():
                return item
        choices = ", ".join(item.name.lower() for item in enum_cls)
        raise argparse.ArgumentTypeError(f"expected one of: {choices}")

    return parser

def _cookies_from_cookie_string(raw: str) -> Dict[str, str]:
    raw = raw.strip()
    if not raw:
        return {}

    parsed = SimpleCookie()
    try:
        parsed.load(raw)
    except Exception:
        parsed = SimpleCookie()

    cookies = {name: morsel.value for name, morsel in parsed.items()}
    if cookies:
        return cookies

    if "=" not in raw:
        raise ValueError(f"cookie must be name=value: {raw!r}")

    name, value = raw.split("=", 1)
    name = name.strip()
    if not name:
        raise ValueError(f"cookie name is empty: {raw!r}")
    return {name: value.strip()}

def _cookies_from_json(value: object) -> Dict[str, str]:
    if isinstance(value, str):
        return _cookies_from_cookie_string(value)

    if isinstance(value, dict):
        return {str(k): str(v) for k, v in value.items()}

    if isinstance(value, list):
        cookies: Dict[str, str] = {}
        for cookie in value:
            if not isinstance(cookie, dict):
                continue
            name = cookie.get("name")
            val = cookie.get("value")
            if name is None or val is None:
                continue
            cookies[str(name)] = str(val)
        return cookies

    raise ValueError("cookies JSON must be a dict, browser-cookie list, or cookie string")

def parse_cookies(
    cookie_values: Optional[Iterable[str]] = None,
    cookie_header: str = "",
    cookies_json: str = "",
    cookies_file: str = "",
) -> Dict[str, str]:
    cookies: Dict[str, str] = {}

    for env_name in ("SINGLE_ENDPOINT_COOKIE_HEADER", "WEBFUZZ_COOKIE_HEADER"):
        raw = os.environ.get(env_name, "").strip()
        if raw:
            cookies.update(_cookies_from_cookie_string(raw))

    if cookie_header:
        cookies.update(_cookies_from_cookie_string(cookie_header))

    for raw in cookie_values or []:
        cookies.update(_cookies_from_cookie_string(raw))

    if cookies_json:
        cookies.update(_cookies_from_json(json.loads(cookies_json)))

    if cookies_file:
        text = Path(cookies_file).read_text(encoding="utf-8").strip()
        if text:
            try:
                cookies.update(_cookies_from_json(json.loads(text)))
            except json.JSONDecodeError:
                cookies.update(_cookies_from_cookie_string(text))

    return cookies

def parse_headers(header_values: Optional[Iterable[str]] = None) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    for raw in header_values or []:
        if ":" not in raw:
            raise ValueError(f"header must be 'Name: value': {raw!r}")
        name, value = raw.split(":", 1)
        name = name.strip()
        if not name:
            raise ValueError(f"header name is empty: {raw!r}")
        headers[name] = value.strip()
    return headers

def _normalize_param_value(value: object) -> List[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]

def parse_post_params(data: str = "", data_json: str = "") -> Dict[str, List[str]]:
    params: Dict[str, List[str]] = {}

    if data:
        params.update(parse_qs(data, keep_blank_values=True))

    if data_json:
        parsed = json.loads(data_json)
        if not isinstance(parsed, dict):
            raise ValueError("--data_json must be a JSON object")
        params.update({str(k): _normalize_param_value(v) for k, v in parsed.items()})

    return params

def _read_endpoint_file(endpoint_file: str) -> List[str]:
    if not endpoint_file:
        return []

    endpoints: List[str] = []
    for raw in Path(endpoint_file).read_text(encoding="utf-8").splitlines():
        endpoint = raw.strip()
        if endpoint and not endpoint.startswith("#"):
            endpoints.append(endpoint)
    return endpoints

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fuzz one or more fixed HTTP endpoints with WebFuzz mutation and feedback logic.",
    )

    parser.add_argument("-v", "--verbose", action="count", default=0)
    parser.add_argument("-w", "--worker", type=int, default=1)
    parser.add_argument("-r", "--run_mode", "--run-mode", type=_parse_enum(RunMode), default=RunMode.SIMPLE)
    parser.add_argument("--feedback_mode", "--feedback-mode", type=_parse_enum(FeedbackMode), default=FeedbackMode.NATIVE)
    parser.add_argument(
        "--blackbox_corpus_mode",
        "--blackbox-corpus-mode",
        choices=BLACKBOX_CORPUS_MODES,
        default="keep-submitted",
        help=(
            "BlackBox corpus policy. 'seed-only' retains only the configured "
            "endpoint seeds; 'keep-submitted' retains submitted mutations. "
            "Defaults to 'keep-submitted'."
        ),
    )
    parser.add_argument("--method", type=_parse_enum(HTTPMethod), default=HTTPMethod.GET)

    parser.add_argument("-m", "--meta_file", "--meta-file", default="./instr.meta")
    parser.add_argument("--allow_non_html", "--allow-non-html", action="store_true", default=False)
    parser.add_argument("--ignore_404", "--ignore-404", action="store_true", default=False)
    parser.add_argument("--ignore_4xx", "--ignore-4xx", action="store_true", default=False)
    parser.add_argument("--http_error_at_info", "--http-error-at-info", action="store_true", default=False)
    parser.add_argument("--request_timeout", "--request-timeout", type=int, default=100)
    parser.add_argument("--uniq_frag", "--uniq-frag", action="store_true", default=False)
    parser.add_argument("-b", "--block", type=WebFuzzArguments.parse_single_block_opt, action="append", default=[])

    parser.add_argument("--tracelib_bitmap_dir", "--tracelib-bitmap-dir", default="/dev/shm")
    parser.add_argument("--tracelib_header", "--tracelib-header", default="X-REQUEST-ID")
    parser.add_argument("--tracelib_bitmap_size", "--tracelib-bitmap-size", type=int, default=65536)
    parser.add_argument(
        "--tracelib_novelty",
        "--tracelib-novelty",
        choices=("bucket", "index"),
        default="bucket",
        help=(
            "Corpus-admission rule for --feedback-mode=tracelib. 'bucket' "
            "(default) applies the same rule as native AST feedback: a request "
            "is interesting if it reaches a bitmap index never seen before, or "
            "reaches a known index in a hit-count bucket never seen for that "
            "index. 'index' is the stricter legacy rule, under which only a "
            "previously unseen bitmap index counts and bucket-only changes are "
            "ignored."
        ),
    )

    parser.add_argument("--fuzz_request_budget", "--fuzz-request-budget", type=int, default=0)
    parser.add_argument("--max_corpus_size", "--max-corpus-size", type=int, default=0)
    parser.add_argument(
        "--request_record_file",
        "--request-record-file",
        default="",
        help=(
            "Record each submitted Blackbox fuzz request as a "
            "canonical cookie-free JSONL replay baseline."
        ),
    )
    parser.add_argument(
        "--request_replay_file",
        "--request-replay-file",
        default="",
        help=(
            "Submit the canonical requests in this JSONL file in exact order, "
            "without mutation. The current run's cookie jar is used."
        ),
    )
    parser.add_argument(
        "--endpoint_time_budget",
        "--endpoint-time-budget",
        type=int,
        default=None,
        help=(
            "Seconds to fuzz each endpoint before moving to the next. "
            "Only used by sequential scheduling. Defaults to 300 in "
            "sequential mode when multiple endpoints are supplied and 0 "
            "otherwise. Use 0 to disable the per-endpoint time limit."
        ),
    )
    parser.add_argument(
        "--endpoint_schedule",
        "--endpoint-schedule",
        choices=ENDPOINT_SCHEDULES,
        default="blend",
        help=(
            "Endpoint scheduling policy. 'sequential' fuzzes one configured "
            "endpoint at a time; 'blend' seeds all configured endpoints into "
            "one campaign corpus. Defaults to 'blend'."
        ),
    )
    parser.add_argument(
        "--endpoint_file",
        "--endpoint-file",
        default="",
        help="Read additional endpoints from a newline-delimited file. Blank lines and # comments are ignored.",
    )

    parser.add_argument("-s", "--session", action="store_true", default=False)
    parser.add_argument("--catch_phrase", "--catch-phrase", default="")
    parser.add_argument("--session_check_url", "--session-check-url", default="")
    parser.add_argument("--auto_login_script", "--auto-login-script", default="")
    parser.add_argument("--auto_login_dir", "--auto-login-dir", default="")
    parser.add_argument("--wut_name", "--wut-name", default="single-endpoint")
    parser.add_argument("--re_login", "--re-login", action="store_true", default=False)
    parser.add_argument("--driver_file", "--driver-file", default="webFuzz/drivers/geckodriver")
    parser.add_argument("--proxy_port", "--proxy-port", type=int, default=8090)
    parser.add_argument("-p", "--proxy", action="store_true", default=False)

    parser.add_argument("--cookie", action="append", default=[], help="Cookie as name=value. Can be repeated.")
    parser.add_argument("--cookie_header", "--cookie-header", default="", help="Raw Cookie header, e.g. 'a=b; c=d'.")
    parser.add_argument("--cookies_json", "--cookies-json", default="", help="JSON dict or browser-cookie list.")
    parser.add_argument("--cookies_file", "--cookies-file", default="", help="File containing JSON cookies or a raw Cookie header.")
    parser.add_argument("--header", action="append", default=[], help="Extra header as 'Name: value'. Can be repeated.")

    parser.add_argument("--data", default="", help="URL-encoded POST body parameters to mutate.")
    parser.add_argument("--data_json", "--data-json", default="", help="JSON object of POST body parameters to mutate.")
    parser.add_argument(
        "URL",
        nargs="*",
        metavar="URL",
        help="Endpoint to fuzz. Supply multiple URLs for sequential or blended scheduling.",
    )

    return parser

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        endpoints = list(args.URL)
        endpoints.extend(_read_endpoint_file(args.endpoint_file))
        if not endpoints:
            raise ValueError("at least one endpoint URL is required")
        if args.endpoint_time_budget is not None and args.endpoint_time_budget < 0:
            raise ValueError("--endpoint_time_budget must be >= 0")
        if args.request_record_file and args.request_replay_file:
            raise ValueError(
                "--request-record-file and --request-replay-file are mutually exclusive"
            )
        if (args.request_record_file or args.request_replay_file) and args.worker != 1:
            raise ValueError("request recording/replay requires exactly one worker")
        if args.request_record_file and args.feedback_mode != FeedbackMode.BLACKBOX:
            raise ValueError("--request-record-file requires Blackbox feedback mode")

        args.cookie_dict = parse_cookies(
            cookie_values=args.cookie,
            cookie_header=args.cookie_header,
            cookies_json=args.cookies_json,
            cookies_file=args.cookies_file,
        )
        args.extra_headers = parse_headers(args.header)
        args.post_params = parse_post_params(args.data, args.data_json)
        args.block = args.block or []
        args.seed_file = None
        args.crawler_per_base_limit = 1
        args.urls = endpoints
        args.URL = endpoints[0]
        if args.endpoint_time_budget is None:
            if args.endpoint_schedule == "blend":
                args.endpoint_time_budget = 0
            else:
                args.endpoint_time_budget = 300 if len(endpoints) > 1 else 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))

    if args.method == HTTPMethod.GET and args.post_params:
        parser.error("--data/--data_json require --method POST")

    args.parse_single_block_opt = WebFuzzArguments.parse_single_block_opt

    return args
