"""Check the runtimes a repository runs on against endoflife.date (issue #230).

Detects product versions from .python-version, pyproject.toml requires-python,
.nvmrc, package.json engines.node, go.mod `go`, Dockerfile FROM tags and
.tool-versions (explicit --products wins for a product it names), looks up
each product's cycles at https://endoflife.date/api/<product>.json and
classifies each detected version: eol (past its end-of-life date), warn
(within --warn-days of it), ok, or unknown (product or cycle not found, or the
API unreachable with nothing cached).

Usage: eol.py --root DIR --out report.json [--products python:3.10,nodejs:20]
              [--warn-days 90] [--production true] [--cache DIR] [--today YYYY-MM-DD]
              [--api URL-template]
Responses are written to --cache and read back when the API is unreachable
(the API is in beta, so the check fails open). Prints eol-count, warn-count
and unknown-count for GITHUB_OUTPUT.
"""

import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import tomllib

# Docker image and asdf tool names whose endoflife.date product name differs;
# any other name is looked up as-is.
ALIASES = {"node": "nodejs", "golang": "go", "postgres": "postgresql", "mongo": "mongodb", "java": "eclipse-temurin"}
DOCKER_PRODUCTS = {"python", "node", "golang", "postgres", "redis", "nginx", "alpine", "ubuntu", "debian",
                   "ruby", "php", "mysql", "mariadb", "mongo", "eclipse-temurin", "rabbitmq", "elasticsearch"}
VERSION = re.compile(r"v?(\d+(?:\.\d+)*)")
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "vendor"}


def first_version(text):
    m = VERSION.search(text or "")
    return m.group(1) if m else None


def files(root, name):
    for path in sorted(root.rglob(name)):
        if not SKIP_DIRS & set(path.relative_to(root).parts):
            yield path


def detect(root):
    found = []  # (product, version, source)

    def add(product, version, path):
        if version:
            # Relative to the working directory (the repository root in Actions), so annotations land on the file.
            found.append((ALIASES.get(product, product), version, os.path.relpath(path)))

    for p in files(root, ".python-version"):
        add("python", first_version(p.read_text()), p)
    for p in files(root, "pyproject.toml"):
        project = tomllib.loads(p.read_text()).get("project", {})
        add("python", first_version(project.get("requires-python")), p)
    for p in files(root, ".nvmrc"):
        text = p.read_text().strip()
        add("nodejs", first_version(text) if re.match(r"^v?\d", text) else None, p)
    for p in files(root, "package.json"):
        engines = json.loads(p.read_text() or "{}").get("engines") or {}
        add("nodejs", first_version(engines.get("node")), p)
    for p in files(root, "go.mod"):
        m = re.search(r"^go\s+(\d+\.\d+)", p.read_text(), re.MULTILINE)
        add("go", m.group(1) if m else None, p)
    for p in [*files(root, "Dockerfile"), *files(root, "*.Dockerfile"), *files(root, "Dockerfile.*")]:
        for m in re.finditer(r"^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)", p.read_text(), re.MULTILINE | re.IGNORECASE):
            image = m.group(1).split("@")[0]
            name, _, tag = image.rpartition(":") if ":" in image.split("/")[-1] else (image, "", "")
            base = name.split("/")[-1]
            if base in DOCKER_PRODUCTS and re.match(r"^\d", tag):
                add(base, first_version(tag), p)
    for p in files(root, ".tool-versions"):
        for line in p.read_text().splitlines():
            parts = line.split("#")[0].split()
            if len(parts) >= 2 and re.match(r"^\d", parts[1]):
                add(parts[0], parts[1], p)
    return found


def fetch(api, product, cache):
    cached = cache / f"{product}.json" if cache else None
    try:
        with urllib.request.urlopen(api.format(product), timeout=20) as resp:  # nosec B310 - https, or file:// in tests
            body = resp.read()
        data = json.loads(body)
        if cached:
            cached.write_bytes(body)
        return data, "live"
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None, "unknown product"
        reason = f"HTTP {err.code}"
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as err:
        reason = str(err)
    if cached and cached.is_file():
        print(f"::warning title=eol-check::endoflife.date unreachable for {product} ({reason}); using the cached response",
              file=sys.stderr)
        return json.loads(cached.read_text()), "cached"
    print(f"::warning title=eol-check::endoflife.date unreachable for {product} ({reason}) and nothing cached; skipped",
          file=sys.stderr)
    return None, "unreachable"


def match_cycle(cycles, version):
    # Longest cycle that equals the version or prefixes it at a dot: 3.11.4 -> 3.11, 20.11.0 -> 20.
    hits = [c for c in cycles if version == str(c["cycle"]) or version.startswith(f"{c['cycle']}.")]
    return max(hits, key=lambda c: len(str(c["cycle"])), default=None)


def classify(cycle, today, warn_days):
    eol = cycle.get("eol")
    if eol is True:
        return "eol", None
    if not eol:
        return "ok", None
    date = datetime.date.fromisoformat(eol)
    if date <= today:
        return "eol", date
    return ("warn" if (date - today).days <= warn_days else "ok"), date


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--out", required=True)
    ap.add_argument("--products", default="")
    ap.add_argument("--warn-days", type=int, default=90)
    ap.add_argument("--production", default="true")
    ap.add_argument("--cache", default="")
    ap.add_argument("--today", default="")
    ap.add_argument("--api", default="https://endoflife.date/api/{}.json", help="URL template; tests use file://")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.datetime.now(datetime.UTC).date()
    cache = Path(args.cache) if args.cache else None
    if cache:
        cache.mkdir(parents=True, exist_ok=True)

    explicit = []
    for pair in filter(None, (p.strip() for p in args.products.split(","))):
        product, _, version = pair.partition(":")
        if not version:
            sys.exit(f"::error title=eol-check::products entry '{pair}' must be product:version")
        explicit.append((ALIASES.get(product, product), version, "products input"))
    named = {p for p, _, _ in explicit}
    entries = sorted(set(explicit + [d for d in detect(root) if d[0] not in named]))

    severity = "high" if args.production.lower() == "true" else "medium"
    responses, rows = {}, []
    for product, version, source in entries:
        if product not in responses:
            responses[product] = fetch(args.api, product, cache)
        cycles, origin = responses[product]
        cycle = match_cycle(cycles or [], version)
        if not cycle:
            status, date = "unknown", None
        else:
            status, date = classify(cycle, today, args.warn_days)
        latest = str(cycles[0]["cycle"]) if cycles else ""
        rows.append({"product": product, "version": version, "cycle": str(cycle["cycle"]) if cycle else "",
                     "source": source, "status": status, "eol": date.isoformat() if date else (cycle or {}).get("eol"),
                     "latest_cycle": latest, "severity": severity if status == "eol" else "",
                     "response": origin})
        where = "" if source == "products input" else f"file={source},"
        if status == "eol":
            print(f"::error {where}title=eol-check::{product} {version} reached end of life on {rows[-1]['eol']} "
                  f"({severity} finding); latest cycle is {latest}", file=sys.stderr)
        elif status == "warn":
            print(f"::warning {where}title=eol-check::{product} {version} reaches end of life on {date} "
                  f"(within {args.warn_days} days); latest cycle is {latest}", file=sys.stderr)

    Path(args.out).write_text(json.dumps(rows, indent=2))
    lines = [f"### End-of-life check ({today})", "",
             "| Product | Version | Cycle | End of life | Latest cycle | Status | Source |",
             "|---|---|---|---|---|---|---|"]
    lines += [f"| {r['product']} | {r['version']} | {r['cycle'] or '-'} | {r['eol'] or '-'} | {r['latest_cycle'] or '-'} | "
              f"{r['status']}{' (' + r['severity'] + ')' if r['severity'] else ''} | `{r['source']}` |" for r in rows]
    if not rows:
        lines.append("| - | - | - | - | - | nothing detected | - |")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines), file=sys.stderr)
    for status in ("eol", "warn", "unknown"):
        print(f"{status}-count={sum(r['status'] == status for r in rows)}")


if __name__ == "__main__":
    main()
