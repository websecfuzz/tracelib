import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8094").rstrip("/")
ADMIN_PATH = os.environ.get("ZENCART_ADMIN_PATH", "adminzcfuzz")
ADMIN_USER = os.environ.get("ZENCART_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ZENCART_ADMIN_PASSWORD", "admin123")

WEBFUZZ_UA = os.environ.get(
    "WEBFUZZ_USER_AGENT",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.97 Safari/537.36",
)

LOGIN_URL = f"{BASE_URL}/{ADMIN_PATH}/index.php?cmd=login"

def _extract_hidden(html: str) -> dict:
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
    logger.info("Running auto-login for ZenCart")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [
        ("User-Agent", WEBFUZZ_UA),
        ("Accept-Encoding", "identity"),
    ]

    resp = opener.open(LOGIN_URL)
    html = resp.read().decode("utf-8", errors="replace")
    hidden = _extract_hidden(html)

    data = urllib.parse.urlencode({
        **hidden,
        "admin_name": ADMIN_USER,
        "admin_pass": ADMIN_PASS,
        "login": "login",
    }).encode()

    resp = opener.open(urllib.request.Request(LOGIN_URL, data=data, method="POST"))
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}
    if "Logoff" not in html and "logoff" not in html.lower():
        raise RuntimeError(
            f"ZenCart auto-login failed — no Logoff link in response. "
            f"Cookies: {list(cookies.keys())}. "
            "Check ZENCART_ADMIN_USER / ZENCART_ADMIN_PASSWORD."
        )
    config["cookies"] = cookies
