import http.cookiejar
import json
import logging
import os
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:2368").rstrip("/")
ADMIN_EMAIL = os.environ.get("WEBFUZZ_ADMIN_EMAIL", "admin@example.com")
ADMIN_PASSWORD = os.environ.get("WEBFUZZ_ADMIN_PASSWORD", "Fuzz1ng-Gh0st-2026-xK")
ADMIN_NAME = os.environ.get("WEBFUZZ_ADMIN_NAME", "Admin")
BLOG_TITLE = os.environ.get("WEBFUZZ_BLOG_TITLE", "WebFuzz Ghost")
WEBFUZZ_UA = os.environ.get(
    "WEBFUZZ_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36",
)

_API_HEADERS = {
    "Content-Type": "application/json",
    "Origin": BASE_URL,
    "Referer": f"{BASE_URL}/ghost/",
    "Accept-Version": "v5.0",
    "Accept-Encoding": "identity",
    "User-Agent": WEBFUZZ_UA,
}

def _drain_response(response) -> str:

    return response.read().decode("utf-8", errors="replace")

async def main(config) -> None:
    logger.info("Running auto-login for Ghost")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [
        ("Accept-Encoding", "identity"),
        ("User-Agent", WEBFUZZ_UA),
    ]

    setup_body = json.dumps({"setup": [{
        "name": ADMIN_NAME,
        "email": ADMIN_EMAIL,
        "password": ADMIN_PASSWORD,
        "blogTitle": BLOG_TITLE,
    }]}).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/ghost/api/admin/authentication/setup/",
        data=setup_body,
        method="POST",
    )
    for k, v in _API_HEADERS.items():
        req.add_header(k, v)
    try:
        _drain_response(opener.open(req))
    except urllib.error.HTTPError as exc:
        _drain_response(exc)
        pass

    login_body = json.dumps({"username": ADMIN_EMAIL, "password": ADMIN_PASSWORD}).encode()
    req2 = urllib.request.Request(
        f"{BASE_URL}/ghost/api/admin/session/",
        data=login_body,
        method="POST",
    )
    for k, v in _API_HEADERS.items():
        req2.add_header(k, v)
    try:
        _drain_response(opener.open(req2))
    except urllib.error.HTTPError as exc:
        _drain_response(exc)
        raise RuntimeError(
            f"Ghost auto-login failed with HTTP {exc.code}. "
            "Check security__staffDeviceVerification=false and Ghost credentials."
        ) from exc

    cookies = {c.name: c.value for c in jar}
    if "ghost-admin-api-session" not in cookies:
        raise RuntimeError(
            "Ghost auto-login failed — no ghost-admin-api-session cookie. "
            "Check WEBFUZZ_ADMIN_EMAIL / WEBFUZZ_ADMIN_PASSWORD."
        )

    verify_req = urllib.request.Request(
        f"{BASE_URL}/ghost/api/admin/users/me/?include=roles",
        method="GET",
    )
    for k, v in _API_HEADERS.items():
        verify_req.add_header(k, v)
    try:
        verify_resp = opener.open(verify_req)
        verify_body = verify_resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"Ghost auto-login cookie is not an authenticated admin session "
            f"(HTTP {exc.code})."
        ) from exc
    if ADMIN_EMAIL not in verify_body:
        raise RuntimeError("Ghost auto-login verification did not return the admin user.")
    config["cookies"] = cookies
