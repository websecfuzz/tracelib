"""Superset configuration for the TraceLib evaluation image.

Points Superset's metadata database at the MySQL service defined in the app's
compose files. Everything Superset does — listing dashboards, loading the
welcome page, serving /api/v1 — reads or writes this database, so a request's
SQL traffic crosses a socket and carries the argument hash the *_file_sql*
encoders read.
"""

import os

def _database_uri() -> str:
    user = os.environ.get("SUPERSET_DB_USER", "superset")
    password = os.environ.get("SUPERSET_DB_PASSWORD", "superset")
    host = os.environ.get("SUPERSET_DB_HOST", "db")
    port = os.environ.get("SUPERSET_DB_PORT", "3306")
    name = os.environ.get("SUPERSET_DB_NAME", "superset")

    return f"mysql://{user}:{password}@{host}:{port}/{name}?charset=utf8mb4"

SECRET_KEY = os.environ.get(
    "SUPERSET_SECRET_KEY",
    "tracelib-superset-secret-key-not-for-production",
)
SQLALCHEMY_DATABASE_URI = _database_uri()
SQLALCHEMY_TRACK_MODIFICATIONS = False

TALISMAN_ENABLED = False
WTF_CSRF_ENABLED = True

WTF_CSRF_EXEMPT_LIST = ["superset.views.core.log"]

SCREENSHOT_LOAD_WAIT = 5
SUPERSET_WEBSERVER_TIMEOUT = 120
FEATURE_FLAGS = {"ALERT_REPORTS": False}
