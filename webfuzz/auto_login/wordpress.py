import asyncio
import http.cookiejar
import logging
import os
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8081")
ADMIN_USER = os.environ.get("WEBFUZZ_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("WEBFUZZ_ADMIN_PASSWORD", "admin")

async def main(config) -> None:
    logger.info("Running auto-login for WordPress")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("User-Agent", "Mozilla/5.0")]

    opener.open(f"{BASE_URL}/wp-login.php")

    data = urllib.parse.urlencode({
        "log": ADMIN_USER,
        "pwd": ADMIN_PASSWORD,
        "wp-submit": "Log In",
        "redirect_to": f"{BASE_URL}/wp-admin/",
        "testcookie": "1",
    }).encode()

    resp = opener.open(f"{BASE_URL}/wp-login.php", data)
    html = resp.read().decode("utf-8", errors="replace")

    cookies = {c.name: c.value for c in jar}
    config["cookies"] = cookies

    if not any("wordpress_logged_in" in name for name in cookies):
        raise RuntimeError(
            f"WordPress HTTP login failed — no session cookie set. "
            f"Got cookies: {list(cookies.keys())}. "
            f"Check WEBFUZZ_ADMIN_USER/WEBFUZZ_ADMIN_PASSWORD."
        )
