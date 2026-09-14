import asyncio
import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8089").rstrip("/")
ADMIN_USER = os.environ.get("PHPBB_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("PHPBB_ADMIN_PASSWORD", "admin12345678")

WEBFUZZ_UA = os.environ.get(
    "WEBFUZZ_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36",
)

LOGIN_URL = f"{BASE_URL}/ucp.php?mode=login&redirect=index.php"

def _extract_hidden(html: str) -> dict:
    """Return all hidden input name→value pairs from the page."""
    fields = {}
    for tag in re.findall(r'<input\b[^>]*/?>',  html, re.IGNORECASE):
        if not re.search(r'\btype=["\']hidden["\']', tag, re.IGNORECASE):
            continue
        name_m = re.search(r'\bname=["\']([^"\']+)["\']', tag, re.IGNORECASE)
        val_m  = re.search(r'\bvalue=["\']([^"\']*)["\']', tag, re.IGNORECASE)
        if name_m:
            fields[name_m.group(1)] = val_m.group(1) if val_m else ""
    return fields

async def main(config) -> None:
    logger.info("Running auto-login for phpBB")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    opener.addheaders = [
        ("User-Agent", WEBFUZZ_UA),
        ("Accept-Encoding", "identity"),
    ]

    req = urllib.request.Request(LOGIN_URL)
    resp = opener.open(req)
    html = resp.read().decode("utf-8", errors="replace")

    hidden = _extract_hidden(html)
    if "form_token" not in hidden or "creation_time" not in hidden:
        raise RuntimeError(
            f"phpBB login page missing form_token or creation_time. "
            f"Hidden fields found: {list(hidden.keys())}"
        )

    await asyncio.sleep(4)

    data = urllib.parse.urlencode({
        **hidden,
        "username": ADMIN_USER,
        "password": ADMIN_PASS,
        "autologin": "on",
        "login": "Login",
    }).encode()

    resp = opener.open(LOGIN_URL, data)
    html = resp.read().decode("utf-8", errors="replace")

    if "mode=logout" not in html:
        raise RuntimeError(
            f"phpBB HTTP login failed — no logout link in response. "
            f"Check PHPBB_ADMIN_USER / PHPBB_ADMIN_PASSWORD."
        )

    cookies = {c.name: c.value for c in jar}
    config["cookies"] = cookies
