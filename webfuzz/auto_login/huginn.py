import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8092").rstrip("/")
ADMIN_USER = os.environ.get("HUGINN_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("HUGINN_ADMIN_PASSWORD", "admin123")

def _extract_authenticity_token(html: str) -> str:
    """Return the Rails authenticity_token from a Devise login page."""
    for tag in re.findall(r'<input\b[^>]*/?>', html, re.IGNORECASE):
        name_m = re.search(r'\bname=["\']authenticity_token["\']', tag, re.IGNORECASE)
        if name_m:
            val_m = re.search(r'\bvalue=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            return val_m.group(1) if val_m else ""
    return ""

async def main(config) -> None:
    logger.info("Running auto-login for Huginn")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(f"{BASE_URL}/users/sign_in")
    html = resp.read().decode("utf-8", errors="replace")

    token = _extract_authenticity_token(html)
    if not token:
        raise RuntimeError("Huginn login page missing authenticity_token.")

    data = urllib.parse.urlencode({
        "authenticity_token": token,
        "user[login]": ADMIN_USER,
        "user[password]": ADMIN_PASS,
        "user[remember_me]": "0",
        "commit": "Log in",
    }).encode()

    resp = opener.open(f"{BASE_URL}/users/sign_in", data)
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}

    if not any(name.endswith("_session") for name in cookies):
        raise RuntimeError(
            f"Huginn auto-login failed — no Rails session cookie. "
            f"Cookies: {list(cookies.keys())}. "
            "Check HUGINN_ADMIN_USER / HUGINN_ADMIN_PASSWORD."
        )

    resp = opener.open(f"{BASE_URL}/agents")
    html = resp.read().decode("utf-8", errors="replace")
    if "/users/sign_in" in resp.geturl() or "/users/sign_out" not in html:
        raise RuntimeError("Huginn auto-login verification failed on /agents.")
    config["cookies"] = cookies
