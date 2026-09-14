import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8091").rstrip("/")
ADMIN_USER = os.environ.get("GOGS_ADMIN_USER", "gogsadmin")
ADMIN_PASS = os.environ.get("GOGS_ADMIN_PASSWORD", "admin123")

WEBFUZZ_UA = os.environ.get(
    "WEBFUZZ_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36",
)

def _extract_csrf(html: str) -> str:
    """Return the _csrf hidden-input value from a Gogs login page."""
    for tag in re.findall(r'<input\b[^>]*/?>', html, re.IGNORECASE):
        name_m = re.search(r'\bname=["\']_csrf["\']', tag, re.IGNORECASE)
        if name_m:
            val_m = re.search(r'\bvalue=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            return val_m.group(1) if val_m else ""
    return ""

async def main(config) -> None:
    logger.info("Running auto-login for Gogs")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [
        ("User-Agent", WEBFUZZ_UA),
        ("Accept-Encoding", "identity"),
    ]

    resp = opener.open(f"{BASE_URL}/user/login")
    html = resp.read().decode("utf-8", errors="replace")

    csrf = _extract_csrf(html)
    if not csrf:
        raise RuntimeError("Gogs login page missing _csrf token.")

    data = urllib.parse.urlencode({
        "_csrf": csrf,
        "user_name": ADMIN_USER,
        "password": ADMIN_PASS,
    }).encode()

    resp = opener.open(f"{BASE_URL}/user/login", data)
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}

    if not any("gogs" in name.lower() or "i_like" in name.lower() for name in cookies):
        raise RuntimeError(
            f"Gogs auto-login failed — no Gogs session cookie. "
            f"Cookies: {list(cookies.keys())}. "
            "Check GOGS_ADMIN_USER / GOGS_ADMIN_PASSWORD."
        )

    resp = opener.open(f"{BASE_URL}/user/settings")
    html = resp.read().decode("utf-8", errors="replace")
    if "/user/login" in resp.geturl() or ADMIN_USER not in html:
        raise RuntimeError("Gogs auto-login verification failed on /user/settings.")
    config["cookies"] = cookies
