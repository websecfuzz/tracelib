"""Activate coverage.py for the running Python web process tree.

Imported once per process from the WSGI module before Django (or another
framework) bootstraps. Each gunicorn worker that imports this module
starts its own Coverage instance and writes its own data file under
/coverage/.coverage.<pid>.<random> thanks to data_suffix=True. The
sidecar runs `coverage combine` + `coverage report` to roll them up.

Provides a save() helper so a middleware (or a SIGUSR2 handler) can
flush periodically without having to wait for atexit — gunicorn workers
can stay alive for hours during a fuzz run, and the sidecar wants fresh
numbers every minute.
"""

import atexit
import os
from pathlib import Path

import coverage

_data_file = os.environ.get("COVERAGE_DATA_FILE", "/coverage/.coverage")
_source = os.environ.get("COVERAGE_SOURCE", "/app").split(":")
_reset_token_file = Path(os.environ.get("COVERAGE_RESET_TOKEN_FILE", "/coverage/reset.token"))
_last_reset_token = ""

_cov = coverage.Coverage(
    data_file=_data_file,
    data_suffix=True,
    source=_source,
    branch=False,
    auto_data=False,
)
_cov.start()
atexit.register(_cov.save)

def save() -> None:
    try:
        _cov.save()
    except Exception:
        pass

def reset() -> None:
    try:
        _cov.stop()
    except Exception:
        pass
    try:
        _cov.erase()
    except Exception:
        pass
    try:
        _cov.start()
    except Exception:
        pass

def reset_if_requested() -> None:
    global _last_reset_token
    try:
        token = _reset_token_file.read_text(encoding="utf-8").strip()
    except Exception:
        return
    if not token or token == _last_reset_token:
        return
    reset()
    _last_reset_token = token
