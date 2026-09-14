import http.cookiejar
import json
import logging
import os
import urllib.request

logger = logging.getLogger(__name__)

BASE_URL = os.environ.get("WEBFUZZ_TARGET_URL", "http://localhost:8097").rstrip("/")
ADMIN_USER = os.environ.get("WIKIJS_ADMIN_EMAIL", "admin@example.com")
ADMIN_PASS = os.environ.get("WIKIJS_ADMIN_PASSWORD", "admin123456")

LOGIN_MUTATION = """
mutation ($username: String!, $password: String!, $strategy: String!) {
  authentication {
    login(username: $username, password: $password, strategy: $strategy) {
      responseResult { succeeded errorCode message }
      jwt
    }
  }
}
"""

async def main(config) -> None:
    logger.info("Running auto-login for Wiki.js")

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept-Encoding", "identity")]

    payload = json.dumps({
        "query": LOGIN_MUTATION,
        "variables": {
            "username": ADMIN_USER,
            "password": ADMIN_PASS,
            "strategy": "local",
        },
    }).encode()

    request = urllib.request.Request(
        f"{BASE_URL}/graphql",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    resp = opener.open(request)
    body = json.loads(resp.read().decode("utf-8", errors="replace"))

    try:
        login = body["data"]["authentication"]["login"]
        result = login["responseResult"]
        token = login.get("jwt") or ""
    except (KeyError, TypeError) as exc:
        raise RuntimeError(f"Wiki.js login response was not understood: {body}") from exc

    if not result.get("succeeded") or not token:
        raise RuntimeError(
            f"Wiki.js auto-login failed — {result.get('message', 'no message')}. "
            "Check WIKIJS_ADMIN_EMAIL / WIKIJS_ADMIN_PASSWORD."
        )

    cookies = {c.name: c.value for c in jar}

    cookies["jwt"] = token

    verify = urllib.request.Request(
        f"{BASE_URL}/a/dashboard",
        headers={"Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())},
    )
    verify_resp = opener.open(verify)
    verify_resp.read()
    if "/login" in verify_resp.geturl():
        raise RuntimeError("Wiki.js auto-login verification failed on /a/dashboard.")
    config["cookies"] = cookies
