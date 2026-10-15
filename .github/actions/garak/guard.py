#!/usr/bin/env python3
"""Refuse to scan a production endpoint (issue #105).

Usage: guard.py --config FILE [--target-name NAME] [--pattern REGEX]

Collects every http(s) URL in the generator config (any depth) and the
target name, and exits 1 when a host matches the production pattern
(default: a prod, production or live label, or a www. host). garak's probes
are adversarial by design; they belong against staging.
Standard library only; run with python3 -I.
"""

import argparse
import json
import re
import sys
from urllib.parse import urlparse

DEFAULT = r"(^|[.-])(prod|production|live)([.-]|$)|^www\."
URL = re.compile(r"https?://[^\s\"'<>]+")


def strings(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)
    elif isinstance(node, str):
        yield node


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--target-name", default="")
    ap.add_argument("--pattern", default="")
    a = ap.parse_args()
    pattern = re.compile(a.pattern or DEFAULT, re.I)
    with open(a.config, encoding="utf-8") as f:
        config = json.load(f)
    hosts = set()
    for s in list(strings(config)) + [a.target_name]:
        for u in URL.findall(s):
            host = (urlparse(u).hostname or "").lower()
            if host:
                hosts.add(host)
    bad = sorted(h for h in hosts if pattern.search(h))
    for h in bad:
        print(f"::error title=garak guard::{h} matches the production pattern; scan staging instead")
    if bad:
        sys.exit(1)
    print(f"garak guard: target hosts {', '.join(sorted(hosts)) or '(none in config)'} pass the production check")


if __name__ == "__main__":
    main()
