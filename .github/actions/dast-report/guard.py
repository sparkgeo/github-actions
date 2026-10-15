"""Refuse a production target before any active scan runs (issue #68).

Usage: guard.py --target URL --pattern REGEX
The pattern is matched (re.search, case-insensitive) against the target's
host name. A match, a URL without http(s) or a host, or an invalid pattern
exits 1 with an ::error annotation.
"""

import argparse
import re
import sys
from urllib.parse import urlparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--pattern", required=True)
    args = ap.parse_args()
    url = urlparse(args.target)
    if url.scheme not in {"http", "https"} or not url.hostname:
        sys.exit(f"::error title=dast-scheduled::target-url '{args.target}' must be an http(s) URL with a host")
    try:
        prod = re.compile(args.pattern, re.IGNORECASE)
    except re.error as err:
        sys.exit(f"::error title=dast-scheduled::production-pattern is not a valid regular expression: {err}")
    if prod.search(url.hostname):
        sys.exit(f"::error title=dast-scheduled::refusing to run an active scan against {url.hostname}: it matches "
                 f"production-pattern '{args.pattern}'. Active scans send attack payloads; target staging only.")
    print(f"target host {url.hostname} does not match production-pattern; scanning")


if __name__ == "__main__":
    main()
