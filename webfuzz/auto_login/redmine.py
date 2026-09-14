import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8088").rstrip("/")
ADMIN_USER = os.environ.get("REDMINE_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("REDMINE_ADMIN_PASSWORD", "admin123")

def _extract_authenticity_token(html: str) -> str:
    """Return the Rails authenticity_token from a login page."""
    for tag in re.findall(r'<input\b[^>]*/?>',  html, re.IGNORECASE):
        name_m = re.search(r'\bname=["\']authenticity_token["\']', tag, re.IGNORECASE)
        if name_m:
            val_m = re.search(r'\bvalue=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            return val_m.group(1) if val_m else ""
    return ""

async def main(config) -> None:
    logger.info("Running auto-login for Redmine")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(f"{BASE_URL}/login")
    html = resp.read().decode("utf-8", errors="replace")

    token = _extract_authenticity_token(html)
    if not token:
        raise RuntimeError("Redmine login page missing authenticity_token.")

    data = urllib.parse.urlencode({
        "authenticity_token": token,
        "username": ADMIN_USER,
        "password": ADMIN_PASS,
        "login": "Login",
    }).encode()

    resp = opener.open(f"{BASE_URL}/login", data)
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}
    if "_redmine_session" not in cookies:
        raise RuntimeError(
            f"Redmine auto-login failed — no _redmine_session cookie. "
            f"Cookies: {list(cookies.keys())}. "
            "Check REDMINE_ADMIN_USER / REDMINE_ADMIN_PASSWORD."
        )

    resp = opener.open(f"{BASE_URL}/my/account")
    html = resp.read().decode("utf-8", errors="replace")
    if "/login" in resp.geturl() or "Logged in as" not in html:
        raise RuntimeError("Redmine auto-login verification failed on /my/account.")
    config["cookies"] = cookies
