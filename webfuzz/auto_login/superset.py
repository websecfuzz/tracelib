import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8096").rstrip("/")
ADMIN_USER = os.environ.get("SUPERSET_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("SUPERSET_ADMIN_PASSWORD", "admin123")

def _extract_csrf(html: str) -> str:
    """Return the csrf_token hidden-input value from the Flask-AppBuilder form."""
    for tag in re.findall(r'<input\b[^>]*/?>', html, re.IGNORECASE):
        name_m = re.search(r'\bname=["\']csrf_token["\']', tag, re.IGNORECASE)
        if name_m:
            val_m = re.search(r'\bvalue=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            return val_m.group(1) if val_m else ""
    return ""

async def main(config) -> None:
    logger.info("Running auto-login for Superset")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(f"{BASE_URL}/login/")
    html = resp.read().decode("utf-8", errors="replace")

    csrf = _extract_csrf(html)
    if not csrf:
        raise RuntimeError("Superset login page missing csrf_token.")

    data = urllib.parse.urlencode({
        "csrf_token": csrf,
        "username": ADMIN_USER,
        "password": ADMIN_PASS,
    }).encode()

    resp = opener.open(f"{BASE_URL}/login/", data)
    resp.read()

    cookies = {c.name: c.value for c in jar}
    if "session" not in cookies:
        raise RuntimeError(
            f"Superset auto-login failed — no session cookie. "
            f"Cookies: {list(cookies.keys())}. "
            "Check SUPERSET_ADMIN_USER / SUPERSET_ADMIN_PASSWORD."
        )

    resp = opener.open(f"{BASE_URL}/api/v1/me/")
    body = resp.read().decode("utf-8", errors="replace")
    if "/login" in resp.geturl() or ADMIN_USER not in body:
        raise RuntimeError("Superset auto-login verification failed on /api/v1/me/.")
    config["cookies"] = cookies
