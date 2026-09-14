import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8093").rstrip("/")
ADMIN_EMAIL = os.environ.get("BAGISTO_ADMIN_EMAIL", "admin@example.com")
ADMIN_PASS = os.environ.get("BAGISTO_ADMIN_PASSWORD", "admin123")

LOGIN_URL = f"{BASE_URL}/admin/login"

def _extract_csrf(html: str) -> str:
    m = re.search(r'<meta\b[^>]+name=["\']csrf-token["\'][^>]+content=["\']([^"\']+)["\']', html, re.IGNORECASE)
    if m:
        return m.group(1)
    for tag in re.findall(r'<input\b[^>]*/?>',  html, re.IGNORECASE):
        if not re.search(r'\btype=["\']hidden["\']', tag, re.IGNORECASE):
            continue
        name_m = re.search(r'\bname=["\']_token["\']', tag, re.IGNORECASE)
        if name_m:
            val_m = re.search(r'\bvalue=["\']([^"\']+)["\']', tag, re.IGNORECASE)
            return val_m.group(1) if val_m else ""
    return ""

async def main(config) -> None:
    logger.info("Running auto-login for Bagisto")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(LOGIN_URL)
    html = resp.read().decode("utf-8", errors="replace")

    token = _extract_csrf(html)
    if not token:
        raise RuntimeError("Bagisto login page missing CSRF token (_token / csrf-token).")

    data = urllib.parse.urlencode({
        "_token": token,
        "email": ADMIN_EMAIL,
        "password": ADMIN_PASS,
    }).encode()

    req = urllib.request.Request(LOGIN_URL, data=data, method="POST")
    req.add_header("Referer", LOGIN_URL)
    resp = opener.open(req)
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}
    if "adminLogout" not in html and "laravel_session" not in cookies:
        raise RuntimeError(
            f"Bagisto auto-login failed — no adminLogout element or session cookie. "
            f"Cookies: {list(cookies.keys())}. "
            "Check BAGISTO_ADMIN_EMAIL / BAGISTO_ADMIN_PASSWORD."
        )
    config["cookies"] = cookies
