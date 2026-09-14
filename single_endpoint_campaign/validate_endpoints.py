#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import csv
import importlib.util
import inspect
import json
import os
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, build_opener

def _read_endpoints(path: Path, base_url: str) -> List[str]:
    endpoints: List[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        endpoint = raw.strip()
        if not endpoint or endpoint.startswith("#"):
            continue
        parsed = urlparse(endpoint)
        if parsed.scheme in {"http", "https"}:
            endpoints.append(endpoint)
        elif endpoint.startswith("/"):
            endpoints.append(base_url.rstrip("/") + endpoint)
        else:
            endpoints.append(urljoin(base_url.rstrip("/") + "/", endpoint))
    return endpoints

def _parse_extra_headers(raw: str) -> Dict[str, str]:
    raw = raw.strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        headers: Dict[str, str] = {}
        for line in raw.splitlines():
            if ":" not in line:
                continue
            name, value = line.split(":", 1)
            name = name.strip()
            if name:
                headers[name] = value.strip()
        return headers
    if not isinstance(parsed, dict):
        return {}
    return {str(key): str(value) for key, value in parsed.items()}

def _cookie_header(cookies: Dict[str, str]) -> str:
    return "; ".join(f"{name}={value}" for name, value in cookies.items())

def _load_auto_login(auto_login_dir: Path, app: str):
    script = auto_login_dir / f"{app}.py"
    if not script.is_file():
        raise FileNotFoundError(f"auto-login script not found: {script}")
    spec = importlib.util.spec_from_file_location(f"single_endpoint_auto_login_{app}", script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load auto-login script: {script}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    main = getattr(module, "main", None)
    if main is None:
        raise RuntimeError(f"auto-login script has no main(config): {script}")
    return main

def _run_auto_login(auto_login_dir: Path, app: str, base_url: str) -> Dict[str, str]:
    os.environ["WEBFUZZ_TARGET_URL"] = base_url.rstrip("/")
    config: Dict[str, object] = {"cookies": {}}
    login_main = _load_auto_login(auto_login_dir, app)
    result = login_main(config)
    if inspect.isawaitable(result):
        asyncio.run(result)
    cookies = config.get("cookies") or {}
    if not isinstance(cookies, dict):
        raise RuntimeError("auto-login returned non-dict cookies")
    return {str(name): str(value) for name, value in cookies.items()}

def _fetch(
    url: str,
    headers: Dict[str, str],
    timeout: int,
) -> Tuple[int, str, int, str]:
    opener = build_opener()
    opener.addheaders = list(headers.items())
    request = Request(url, headers=headers, method="GET")
    try:
        response = opener.open(request, timeout=timeout)
        body = response.read()
        status = int(getattr(response, "status", response.getcode()))
        final_url = response.geturl()
        content_type = response.headers.get("Content-Type", "")
        return status, final_url, len(body), content_type
    except HTTPError as exc:
        body = exc.read()
        return int(exc.code), exc.geturl(), len(body), exc.headers.get("Content-Type", "")
    except URLError as exc:
        raise RuntimeError(str(exc)) from exc

def validate(
    endpoints: Iterable[str],
    headers: Dict[str, str],
    timeout: int,
) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []
    for index, endpoint in enumerate(endpoints, start=1):
        row: Dict[str, object] = {
            "index": index,
            "method": "GET",
            "url": endpoint,
            "http_status": "",
            "final_url": "",
            "bytes": "",
            "content_type": "",
            "ok": "no",
            "error": "",
        }
        try:
            status, final_url, size, content_type = _fetch(endpoint, headers, timeout)
            row.update(
                {
                    "http_status": status,
                    "final_url": final_url,
                    "bytes": size,
                    "content_type": content_type,
                    "ok": "yes" if 200 <= status < 400 else "no",
                }
            )
        except Exception as exc:
            row["error"] = str(exc)
        rows.append(row)
    return rows

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate fixed single-endpoint campaign URLs with app auto-login cookies.",
    )
    parser.add_argument("--app", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--endpoint-file", required=True)
    parser.add_argument("--auto-login-dir", default="")
    parser.add_argument("--output-csv", required=True)
    parser.add_argument("--cookie-output", required=True)
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    endpoints = _read_endpoints(Path(args.endpoint_file), base_url)
    if not endpoints:
        raise SystemExit("endpoint file did not contain any endpoints")

    cookies: Dict[str, str] = {}
    if args.auto_login_dir:
        cookies = _run_auto_login(Path(args.auto_login_dir), args.app, base_url)

    headers = {
        "User-Agent": os.environ.get(
            "WEBFUZZ_USER_AGENT",
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36",
        ),
        "Accept-Encoding": "identity",
    }
    headers.update(_parse_extra_headers(os.environ.get("WEBFUZZ_EXTRA_HEADERS", "")))
    cookie_header = _cookie_header(cookies)
    if cookie_header:
        headers["Cookie"] = cookie_header

    rows = validate(endpoints, headers, args.timeout)
    output_csv = Path(args.output_csv)
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    with output_csv.open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(
            output,
            fieldnames=[
                "index",
                "method",
                "url",
                "http_status",
                "final_url",
                "bytes",
                "content_type",
                "ok",
                "error",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    Path(args.cookie_output).write_text(cookie_header + ("\n" if cookie_header else ""), encoding="utf-8")

    failed = [row for row in rows if row.get("ok") != "yes"]
    for row in rows:
        print(
            "endpoint_check "
            f"{row['index']} {row['ok']} {row['http_status']} {row['url']} -> {row['final_url']}"
        )
    if failed:
        print(f"{len(failed)} endpoint validation check(s) failed; see {output_csv}", file=sys.stderr)
        return 1
    print(f"endpoint validation ok: {len(rows)} endpoint(s); csv={output_csv}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
