"""Django middleware that periodically flushes coverage.py data and
echoes the TraceLib request-id header back on the response.

coverage.py only writes its data file when the process exits or
.save() is called. Gunicorn workers stay up for the full fuzz run, so
without an explicit save the sidecar would never see fresh data. This
middleware calls save() once every COVERAGE_FLUSH_EVERY requests
(default 50). The cost of a save is small — it serialises the in-memory
trace to a SQLite file under /coverage/ — and amortising over 50
requests keeps the overhead off the hot path.

TraceLib demultiplexes coverage by scanning write/writev syscalls for a
specific header. When the inbound request carries X-REQUEST-ID
(configurable via $TRACELIB_HEADER), we echo it on the outbound
response so TraceLib can spot it on the wire and bind the bitmap to the
right id.
"""

import os
import re

import tracelib_coverage_init as coverage_init

_FLUSH_EVERY = max(1, int(os.environ.get("COVERAGE_FLUSH_EVERY", "50")))
_TRACELIB_HEADER = os.environ.get("TRACELIB_HEADER", "X-REQUEST-ID")
_RID_OK = re.compile(r"^[A-Za-z0-9_-]+$")

class FlushCoverageMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        self._counter = 0

    def __call__(self, request):
        coverage_init.reset_if_requested()
        rid = request.headers.get(_TRACELIB_HEADER, "")
        rid = rid[:127]
        try:
            response = self.get_response(request)
            if rid and _RID_OK.match(rid):
                response[_TRACELIB_HEADER] = rid
            return response
        finally:
            self._counter += 1
            if self._counter >= _FLUSH_EVERY:
                self._counter = 0
                coverage_init.save()
