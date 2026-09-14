import http.cookiejar
import logging
import os
import time
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8099/roller").rstrip("/")
ADMIN_USER = os.environ.get("ROLLER_ADMIN_USER", "rolleradmin")
ADMIN_PASS = os.environ.get("ROLLER_ADMIN_PASSWORD", "admin123")

if not BASE_URL.endswith("/roller"):
    BASE_URL = BASE_URL + "/roller"

INSTALL_WAIT_SECONDS = int(os.environ.get("ROLLER_INSTALL_WAIT_SECONDS", "180"))
RETRY_INTERVAL_SECONDS = 3

REQUEST_TIMEOUT_SECONDS = float(os.environ.get("ROLLER_LOGIN_REQUEST_TIMEOUT", "15"))

def _attempt_login():
    """One full login round-trip. Returns the cookie dict, or None if the
    account is not usable yet."""
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    opener.open(f"{BASE_URL}/roller-ui/login.rol", timeout=REQUEST_TIMEOUT_SECONDS).read()

    data = urllib.parse.urlencode({
        "j_username": ADMIN_USER,
        "j_password": ADMIN_PASS,
    }).encode()
    opener.open(f"{BASE_URL}/roller_j_security_check", data,
                timeout=REQUEST_TIMEOUT_SECONDS).read()

    cookies = {c.name: c.value for c in jar}
    if "JSESSIONID" not in cookies:
        return None

    resp = opener.open(f"{BASE_URL}/roller-ui/profile.rol",
                       timeout=REQUEST_TIMEOUT_SECONDS)
    html = resp.read().decode("utf-8", errors="replace")
    if "login.rol" in resp.geturl() or ADMIN_USER not in html:
        return None
    return cookies

async def main(config) -> None:
    logger.info("Running auto-login for Apache Roller")

    deadline = time.monotonic() + INSTALL_WAIT_SECONDS
    last_error = None
    attempts = 0
    while True:
        attempts += 1
        try:
            cookies = _attempt_login()
        except Exception as exc:
            cookies = None
            last_error = exc
        if cookies:
            if attempts > 1:
                logger.info("Roller auto-login succeeded on attempt %d", attempts)
            config["cookies"] = cookies
            return
        if time.monotonic() >= deadline:
            break
        logger.info(
            "Roller not ready for login yet (attempt %d); the installer may still "
            "be running — retrying", attempts,
        )
        time.sleep(RETRY_INTERVAL_SECONDS)

    raise RuntimeError(
        f"Roller auto-login failed after {attempts} attempts over "
        f"{INSTALL_WAIT_SECONDS}s. Last error: {last_error!r}. "
        "Check ROLLER_ADMIN_USER / ROLLER_ADMIN_PASSWORD and the [roller-init] "
        "lines in the container log."
    )
