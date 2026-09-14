"""Superset WSGI entry point with coverage.py wired in.

Mirrors what apps/wagtail does through mysite/wsgi.py and the Django
middleware in python-common/: the coverage tracker is started once per
gunicorn worker before the application is built, the tracker is flushed
periodically from a request hook, and the TraceLib request-id header is
echoed on the response so the ptrace backend can demultiplex per request.

Coverage is only enabled when TRACELIB_COVERAGE=1, so the migrations and
`superset init` run in start.sh stay out of the measurement.
"""

import os
import re

coverage_init = None
if os.environ.get("TRACELIB_COVERAGE") == "1":
    import tracelib_coverage_init as coverage_init

from superset.app import create_app

application = create_app()

_FLUSH_EVERY = max(1, int(os.environ.get("COVERAGE_FLUSH_EVERY", "50")))
_TRACELIB_HEADER = os.environ.get("TRACELIB_HEADER", "X-REQUEST-ID")
_RID_OK = re.compile(r"^[A-Za-z0-9_-]+$")
_state = {"counter": 0}

@application.before_request
def _tracelib_before_request():
    if coverage_init is not None:
        coverage_init.reset_if_requested()

@application.after_request
def _tracelib_after_request(response):
    from flask import request

    rid = request.headers.get(_TRACELIB_HEADER, "")[:127]
    if rid and _RID_OK.match(rid):
        response.headers[_TRACELIB_HEADER] = rid
    if coverage_init is not None:
        _state["counter"] += 1
        if _state["counter"] >= _FLUSH_EVERY:
            _state["counter"] = 0
            coverage_init.save()
    return response
