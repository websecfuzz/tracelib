"""Import-path helpers for running this package directly from the repo."""

from pathlib import Path
import sys

def ensure_paths() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    webfuzz_root = repo_root / "webfuzz"

    for path in (str(repo_root), str(webfuzz_root)):
        if path not in sys.path:
            sys.path.insert(0, path)

