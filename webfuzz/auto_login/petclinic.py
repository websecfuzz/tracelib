import http.cookiejar
import logging
import os
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8098").rstrip("/")

async def main(config) -> None:
    """Session bootstrap for Spring PetClinic.

    PetClinic ships no authentication — it is the Spring reference application
    and every page is public — so there is nothing to log in to. The campaign
    still calls an auto-login module for every app, so this one does what is
    actually useful here: it opens a session, hands the resulting JSESSIONID to
    the fuzzer so Spring's session-scoped state (and the CSRF-free forms) behave
    the same way across requests, and fails loudly if the app is not serving.
    """
    logger.info("Running session bootstrap for Spring PetClinic (no authentication)")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    resp = opener.open(f"{BASE_URL}/")
    html = resp.read().decode("utf-8", errors="replace")
    if "PetClinic" not in html:
        raise RuntimeError(
            "PetClinic session bootstrap failed — welcome page did not render. "
            f"Final URL: {resp.geturl()}"
        )

    config["cookies"] = {c.name: c.value for c in jar}
