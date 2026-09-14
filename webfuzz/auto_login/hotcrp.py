import http.cookiejar
import logging
import os
import re
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8087").rstrip("/")
ADMIN_EMAIL = os.environ.get("WEBFUZZ_ADMIN_EMAIL", "admin@example.com")
ADMIN_PASSWORD = os.environ.get("WEBFUZZ_ADMIN_PASSWORD", "Password123!")

SIGNIN_PAGE = f"{BASE_URL}/signin"
SIGNIN_POST = f"{BASE_URL}/signin.php"

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
    logger.info("Running auto-login for HotCRP")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    def signin_hidden() -> dict:

        resp = opener.open(SIGNIN_PAGE)
        return _extract_hidden(resp.read().decode("utf-8", errors="replace"))

    def signin_post(hidden: dict) -> None:
        data = urllib.parse.urlencode({
            **hidden,
            "email": ADMIN_EMAIL,
            "password": ADMIN_PASSWORD,
            "signin": "1",
        }).encode()
        req = urllib.request.Request(SIGNIN_POST, data=data, method="POST")
        req.add_header("Referer", SIGNIN_PAGE)
        opener.open(req).read()

    def logged_in() -> bool:
        home = opener.open(BASE_URL + "/").read().decode("utf-8", errors="replace")
        return "sign out" in home.lower()

    signin_hidden()
    signin_post(signin_hidden())
    if not logged_in():
        signin_post(signin_hidden())

    cookies = {c.name: c.value for c in jar}
    if not logged_in():
        raise RuntimeError(
            f"HotCRP auto-login failed — no 'Sign out' after login. "
            f"Cookies: {list(cookies.keys())}. "
            "Check WEBFUZZ_ADMIN_EMAIL / WEBFUZZ_ADMIN_PASSWORD "
            "(hotcrp's seeded admin password is Password123!)."
        )
    config["cookies"] = cookies
