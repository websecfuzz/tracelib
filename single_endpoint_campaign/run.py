#!/usr/bin/env python3
from __future__ import annotations

if __package__ in (None, ""):
    from pathlib import Path
    import sys

    repo_root = Path(__file__).resolve().parents[1]
    if str(repo_root) not in sys.path:
        sys.path.insert(0, str(repo_root))

    from single_endpoint_campaign._bootstrap import ensure_paths
else:
    from ._bootstrap import ensure_paths

ensure_paths()

from single_endpoint_campaign.arguments import parse_args
from single_endpoint_campaign.fuzzer import SingleEndpointFuzzer
from webFuzz.types import ExitCode

def main() -> int:
    args = parse_args()
    exit_code = SingleEndpointFuzzer(args).run()
    if len(args.urls) > 1 and args.all_endpoints_completed:
        return int(ExitCode.NONE.value)
    return int(exit_code.value)

if __name__ == "__main__":
    raise SystemExit(main())
