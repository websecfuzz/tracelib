import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8100").rstrip("/")
ADMIN_PATH = os.environ.get("PRESTASHOP_ADMIN_PATH", "admin9671czlrok7qbdn2pre")
ADMIN_EMAIL = os.environ.get("PRESTASHOP_ADMIN_EMAIL", "admin@local.co")
ADMIN_PASS = os.environ.get("PRESTASHOP_ADMIN_PASSWORD", "fuzzer123")

LOGIN_URL = f"{BASE_URL}/{ADMIN_PATH}/index.php"

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
    logger.info("Running auto-login for PrestaShop")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(LOGIN_URL)
    login_url = resp.geturl()
    html = resp.read().decode("utf-8", errors="replace")
    hidden = _extract_hidden(html)

    data = urllib.parse.urlencode({
        **hidden,
        "email": ADMIN_EMAIL,
        "passwd": ADMIN_PASS,
        "submitLogin": "1",
    }).encode()
    req = urllib.request.Request(login_url, data=data, method="POST")
    req.add_header("Referer", login_url)
    html = opener.open(req).read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}

    def logged_in(page: str) -> bool:
        return "header_logout" in page or "sign out" in page.lower()
    if not logged_in(html):
        html = opener.open(LOGIN_URL).read().decode("utf-8", errors="replace")
    if not logged_in(html):
        raise RuntimeError(
            f"PrestaShop auto-login failed — no logout control after login (logged-out). "
            f"Cookies: {list(cookies.keys())}. "
            "Check PRESTASHOP_ADMIN_EMAIL / PRESTASHOP_ADMIN_PASSWORD."
        )
    config["cookies"] = cookies
