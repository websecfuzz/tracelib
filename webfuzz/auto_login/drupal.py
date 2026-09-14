import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8095").rstrip("/")
ADMIN_USER = os.environ.get("DRUPAL_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("DRUPAL_ADMIN_PASSWORD", "admin12345678")

LOGIN_URL = f"{BASE_URL}/user/login"

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
    logger.info("Running auto-login for Drupal")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(LOGIN_URL)
    html = resp.read().decode("utf-8", errors="replace")
    hidden = _extract_hidden(html)

    data = urllib.parse.urlencode({
        **hidden,
        "name": ADMIN_USER,
        "pass": ADMIN_PASS,
        "form_id": "user_login_form",
        "op": "Log in",
    }).encode()

    resp = opener.open(urllib.request.Request(LOGIN_URL, data=data, method="POST"))
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}
    sess_cookies = [n for n in cookies if "SESS" in n or "sess" in n.lower()]
    if not sess_cookies and "Log out" not in html:
        raise RuntimeError(
            f"Drupal auto-login failed — no session cookie and no logout link. "
            f"Cookies: {list(cookies.keys())}. "
            "Check DRUPAL_ADMIN_USER / DRUPAL_ADMIN_PASSWORD."
        )
    config["cookies"] = cookies
