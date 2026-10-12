#!/usr/bin/env python3
"""Match IPs, CIDRs, domains and URLs found in IaC, container and dependency
sources against the threat-feeds snapshot (issue #110).

Usage: ioc_check.py --feeds-dir DIR --root DIR --output findings.json --report report.md
                    [--paths GLOBS] [--exclude GLOBS] [--files-from FILE]
                    [--block-on CATEGORIES]

Feeds read: threatfox.json, feodo.json, urlhaus.json (missing ones are skipped
with a warning). Categories: c2-ip (feodo ip, threatfox ip), c2-domain
(threatfox domain), malware-url (threatfox url, urlhaus url). A code CIDR that
contains a feed IP counts as a match. Private, loopback, link-local,
documentation and catch-all ranges on either side never match. URLs with a
path are redacted to <feed>#<id> everywhere this script writes.

Exit codes: 0 no blocking match; 1 blocking match; 2 usage error.
Standard library only; run with python3 -I.
"""

import argparse
import fnmatch
import ipaddress
import json
import os
import re
import sys
from pathlib import Path

FEEDS = ("threatfox", "feodo", "urlhaus")
CATEGORIES = ("c2-ip", "c2-domain", "malware-url")
CATEGORY_OF = {("feodo", "ip"): "c2-ip", ("threatfox", "ip"): "c2-ip", ("threatfox", "domain"): "c2-domain",
               ("threatfox", "url"): "malware-url", ("urlhaus", "url"): "malware-url",
               ("feodo", "cidr"): "c2-ip", ("threatfox", "cidr"): "c2-ip"}

DEFAULT_PATHS = ",".join([
    "**/*.tf", "**/*.tofu", "**/*.hcl", "**/*.tfvars",            # Terraform / OpenTofu
    "**/*.ts", "**/*.js", "**/*.py",                               # CDK / Pulumi
    "**/Dockerfile*", "**/*.dockerfile", "**/*.containerfile",     # containers
    "**/*.yaml", "**/*.yml", "**/*.json", "**/*.toml",             # Helm, Kustomize, compose, manifests
    "**/package-lock.json", "**/yarn.lock", "**/pnpm-lock.yaml",   # lockfiles
    "**/go.mod", "**/go.sum", "**/requirements*.txt", "**/poetry.lock", "**/uv.lock",
    "**/Pipfile*", "**/Cargo.toml", "**/Cargo.lock",
])
DEFAULT_EXCLUDE = "**/node_modules/**,**/.terraform/**,**/.git/**,**/vendor/**,**/tests/**,**/test/**"
MAX_FILE_BYTES = 5 * 1024 * 1024  # ponytail: lockfiles above this are skipped, not streamed

# RFC 1918, loopback, link-local, RFC 5737 TEST-NETs, this-network, CGNAT,
# multicast, broadcast. Class E is deliberately not here.
NEVER_MATCH = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "0.0.0.0/8", "100.64.0.0/10",
    "224.0.0.0/4", "255.255.255.255/32",
)]

IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?(?![\w.])")
URL = re.compile(r"https?://[^\s\"'<>()\[\]`]+")
HOST = re.compile(r"(?<![\w.-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62})(?![\w-])")


def warn(msg):
    print(f"::warning title=ioc-check::{msg}")


def usage_error(msg):
    print(f"::error title=ioc-check::{msg}")
    return 2


def never(net):
    return any(net.subnet_of(n) for n in NEVER_MATCH)


def parse_net(text):
    """IPv4 address or CIDR as a network, or None when unroutable or invalid."""
    try:
        net = ipaddress.ip_network(text, strict=False)
    except ValueError:
        return None
    if net.version != 4 or net.prefixlen == 0 or never(net):
        return None
    return net


def norm_url(u):
    return u.rstrip("/").lower() if u.count("/") <= 2 else u.rstrip("/")


def redact(feed, entry):
    """Feed URLs with a path never leave this script in clear."""
    value = entry["value"]
    if entry["type"] != "url" or value.rstrip("/").count("/") <= 2:
        return value
    ioc_id = (entry.get("meta") or {}).get("id")
    return f"{feed}#{ioc_id}" if ioc_id else f"{feed}#{value.split('/')[2]}/…"


class Index:
    def __init__(self):
        self.ips = {}      # ip -> (feed, entry)
        self.cidrs = []    # (network, feed, entry)
        self.domains = {}  # domain -> (feed, entry)
        self.urls = {}     # normalised url -> (feed, entry)
        self.snapshot = {}

    def load(self, feeds_dir):
        for feed in FEEDS:
            path = Path(feeds_dir) / f"{feed}.json"
            if not path.is_file():
                warn(f"{feed}.json not in {feeds_dir}; {feed} indicators not checked")
                continue
            with open(path) as f:
                data = json.load(f)
            self.snapshot[feed] = data.get("fetched_at")
            for e in data.get("entries", []):
                if (feed, e["type"]) not in CATEGORY_OF:
                    continue
                if e["type"] == "ip":
                    net = parse_net(e["value"])
                    if net:
                        self.ips[net.network_address] = (feed, e)
                elif e["type"] == "cidr":
                    net = parse_net(e["value"])
                    if net:
                        self.cidrs.append((net, feed, e))
                elif e["type"] == "domain":
                    self.domains[e["value"].lower().rstrip(".")] = (feed, e)
                else:
                    self.urls[norm_url(e["value"])] = (feed, e)

    def lookup_net(self, net):
        """Feed hits for a code IP or CIDR: contained feed IPs, overlapping feed CIDRs."""
        if net.num_addresses == 1:
            hit = self.ips.get(net.network_address)
            if hit:
                yield hit
        else:
            for ip, hit in self.ips.items():
                if ip in net:
                    yield hit
        for feed_net, feed, e in self.cidrs:
            if net.overlaps(feed_net):
                yield feed, e

    def lookup_host(self, host):
        labels = host.lower().rstrip(".").split(".")
        for i in range(len(labels) - 1):
            hit = self.domains.get(".".join(labels[i:]))
            if hit:
                return hit
        return None

    def lookup_url(self, url):
        return self.urls.get(norm_url(url))


def candidates(line):
    """(kind, token) pairs found on one source line."""
    for m in URL.finditer(line):
        yield "url", m.group(0).rstrip(".,;:!?")
    for m in IPV4.finditer(line):
        yield "net", m.group(0)
    for m in HOST.finditer(line.lower()):
        yield "host", m.group(1)


def matches_glob(rel, pattern):
    """fnmatch where * crosses /, so **/x matches x at any depth including the root."""
    if fnmatch.fnmatch(rel, pattern):
        return True
    return pattern.startswith("**/") and fnmatch.fnmatch(rel, pattern[3:])


def select_files(root, paths, exclude, files_from):
    root = Path(root)
    if files_from:
        with open(files_from) as f:
            rel = [l.strip() for l in f if l.strip()]
        found = {r for r in rel if (root / r).is_file()}
    else:
        found = set()
        for dirpath, _, names in os.walk(root):
            for n in names:
                found.add((Path(dirpath) / n).relative_to(root).as_posix())
    includes = [p.strip() for p in paths.split(",") if p.strip()]
    excludes = [x.strip() for x in exclude.split(",") if x.strip()]
    return sorted(f for f in found
                  if any(matches_glob(f, p) for p in includes)
                  and not any(matches_glob(f, x) for x in excludes))


def scan_file(root, rel, index):
    path = Path(root) / rel
    if path.stat().st_size > MAX_FILE_BYTES:
        warn(f"{rel} larger than {MAX_FILE_BYTES // (1024 * 1024)} MB, skipped")
        return
    with open(path, "rb") as f:
        raw = f.read()
    if b"\0" in raw:
        return
    seen = set()
    for lineno, line in enumerate(raw.decode("utf-8", errors="ignore").splitlines(), 1):
        for kind, token in candidates(line):
            if kind == "net":
                net = parse_net(token)
                hits = list(index.lookup_net(net)) if net else []
            elif kind == "host":
                hit = index.lookup_host(token)
                hits = [hit] if hit else []
            else:
                hit = index.lookup_url(token)
                hits = [hit] if hit else []
            for feed, e in hits:
                key = (lineno, feed, e["value"])
                if key in seen:
                    continue
                seen.add(key)
                yield {
                    "indicator": redact(feed, e),
                    "matched": token if kind != "url" else redact(feed, e),
                    "category": CATEGORY_OF[(feed, e["type"])],
                    "feed": feed,
                    "confidence": e.get("confidence"),
                    "first_seen": e.get("first_seen"),
                    "file": rel,
                    "line": lineno,
                }


def write_report(path, matches, snapshot, block_on):
    lines = ["<!-- ioc-check -->"]
    blocking = sum(1 for m in matches if m["blocking"])
    if not matches:
        lines.append("## IOC check: no indicators matched")
    else:
        lines.append(f"## IOC check: {len(matches)} indicator(s) matched, {blocking} blocking")
        lines.append("")
        lines.append("| Indicator | Matched | Category | Feed | Confidence | First seen | Location | Blocks |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for m in matches:
            lines.append(f"| `{m['indicator']}` | `{m['matched']}` | {m['category']} | {m['feed']} | {m['confidence']} "
                         f"| {m['first_seen'] or ''} | `{m['file']}:{m['line']}` | {'yes' if m['blocking'] else 'no'} |")
    lines.append("")
    snap = ", ".join(f"{k} {v}" for k, v in snapshot.items()) or "none"
    lines.append(f"Blocking categories: `{block_on or '(advisory)'}`. Snapshot: {snap}.")
    text = "\n".join(lines) + "\n"
    with open(path, "w") as f:
        f.write(text)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feeds-dir", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--paths", default=DEFAULT_PATHS)
    ap.add_argument("--exclude", default=DEFAULT_EXCLUDE)
    ap.add_argument("--files-from", help="newline-separated paths relative to --root, e.g. git ls-files; --paths still filters them")
    ap.add_argument("--block-on", default="", help="comma-separated categories that fail the check; empty = advisory")
    args = ap.parse_args()

    block_on = {c.strip() for c in args.block_on.split(",") if c.strip()}
    bad = block_on - set(CATEGORIES)
    if bad:
        return usage_error(f"unknown block-on category {', '.join(sorted(bad))}; use {', '.join(CATEGORIES)}")
    if not Path(args.feeds_dir).is_dir():
        return usage_error(f"feeds dir {args.feeds_dir} does not exist")
    if not Path(args.root).is_dir():
        return usage_error(f"root {args.root} does not exist")

    index = Index()
    index.load(args.feeds_dir)

    matches = []
    files = select_files(args.root, args.paths, args.exclude, args.files_from)
    for rel in files:
        for m in scan_file(args.root, rel, index):
            m["blocking"] = m["category"] in block_on
            matches.append(m)
    matches.sort(key=lambda m: (m["file"], m["line"], m["feed"], m["indicator"]))

    for m in matches:
        level = "error" if m["blocking"] else "warning"
        print(f"::{level} file={m['file']},line={m['line']},title=ioc-check::{m['indicator']} {m['category']} "
              f"({m['feed']}, confidence {m['confidence']})")

    blocking = sum(1 for m in matches if m["blocking"])
    with open(args.output, "w") as f:
        json.dump({"snapshot": index.snapshot, "files_scanned": len(files), "match_count": len(matches),
                   "blocking_count": blocking, "matches": matches}, f, indent=1)
        f.write("\n")
    report = write_report(args.report, matches, index.snapshot, args.block_on)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"match-count={len(matches)}\nblocking-count={blocking}\nreport-path={args.report}\n")

    print(f"ioc-check: {len(files)} files, {len(matches)} matches, {blocking} blocking")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
