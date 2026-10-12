#!/usr/bin/env python3
"""Reputation check for dependencies added in a pull request (issue #111).

Usage: reputation.py --base-sha SHA --output findings.json --report report.md
                     [--ecosystems npm,pypi,go,cargo] [--min-scorecard N]
                     [--max-age-days N] [--fail-on-malicious true|false]
                     [--exclude GLOBS] [--cache-dir DIR] [--offline] [--now ISO8601]

Diffs every lockfile changed between --base-sha and HEAD (git show for the
base side), takes the package@version pairs present only on the head side,
and asks deps.dev for each: OSV advisories (MAL-* means malicious), the source
repository and its OpenSSF Scorecard, and the package's latest release date.
Responses are cached one JSON per package@version under --cache-dir; with
--offline nothing is fetched and an uncached package is reported as such.

Gates: malicious blocks when --fail-on-malicious; a Scorecard overall score
below --min-scorecard blocks (0 disables); a latest release older than
--max-age-days, an unknown package and a missing Scorecard only warn.

Exit codes: 0 no blocking package; 1 blocking package; 2 usage error.
Standard library only (needs 3.11 for tomllib); run with python3 -I.
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.deps.dev/v3"
TITLE = "dependency-reputation"
CHECKS = ("Maintained", "Dangerous-Workflow", "Binary-Artifacts", "Signed-Releases")  # deps.dev carries no Vulnerabilities check
SYSTEMS = {"npm": "NPM", "pypi": "PYPI", "go": "GO", "cargo": "CARGO"}

# basename pattern -> ecosystem
LOCKFILES = [
    (re.compile(r"^package-lock\.json$"), "npm"), (re.compile(r"^pnpm-lock\.yaml$"), "npm"),
    (re.compile(r"^yarn\.lock$"), "npm"),
    (re.compile(r"^requirements[^/]*\.txt$"), "pypi"), (re.compile(r"^poetry\.lock$"), "pypi"),
    (re.compile(r"^uv\.lock$"), "pypi"),
    (re.compile(r"^go\.sum$"), "go"), (re.compile(r"^Cargo\.lock$"), "cargo"),
]


def warn(msg):
    print(f"::warning title={TITLE}::{msg}")


def usage_error(msg):
    print(f"::error title={TITLE}::{msg}")
    return 2


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


# --- lockfile parsers: text -> {name: version} ------------------------------

def parse_package_lock(text):
    data = json.loads(text)
    out = {}
    for key, pkg in data.get("packages", {}).items():
        if not key or pkg.get("link") or "version" not in pkg:
            continue
        out[key.rsplit("node_modules/", 1)[-1]] = pkg["version"]
    return out


PNPM = re.compile(r"^  '?/?((?:@[^/\s'@]+/)?[^@/\s']+)@([^'\s(:]+)")


def parse_pnpm_lock(text):
    out, in_packages = {}, False
    for line in text.splitlines():
        if re.match(r"^\w", line):
            in_packages = line.startswith("packages:")
            continue
        m = PNPM.match(line) if in_packages else None
        if m:
            out[m.group(1)] = m.group(2)
    return out


YARN_HEADER = re.compile(r'^"?((?:@[^/@"\s,]+/)?[^@"\s,]+)@')
YARN_VERSION = re.compile(r'^\s+version:?\s+"?([^"\s]+)')


def parse_yarn_lock(text):
    out, name = {}, None
    for line in text.splitlines():
        if line and not line[0].isspace() and not line.startswith("#"):
            m = YARN_HEADER.match(line)
            name = m.group(1) if m else None
            continue
        m = YARN_VERSION.match(line)
        if m and name:
            out[name] = m.group(1)
            name = None
    return out


REQ = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*([^\s;#\\]+)")


def parse_requirements(text):
    out = {}
    for line in text.splitlines():
        m = REQ.match(line)
        if m:
            out[m.group(1).lower().replace("_", "-")] = m.group(2)
    return out


def parse_toml_packages(text):
    out = {}
    for pkg in tomllib.loads(text).get("package", []):
        if "name" in pkg and "version" in pkg:
            out[pkg["name"]] = pkg["version"]
    return out


GOSUM = re.compile(r"^(\S+) (v\S+?) h1:")


def parse_go_sum(text):
    out = {}
    for line in text.splitlines():
        m = GOSUM.match(line)
        if m and not m.group(2).endswith("/go.mod"):
            out[m.group(1)] = m.group(2)
    return out


PARSERS = {
    "package-lock.json": parse_package_lock, "pnpm-lock.yaml": parse_pnpm_lock, "yarn.lock": parse_yarn_lock,
    "poetry.lock": parse_toml_packages, "uv.lock": parse_toml_packages, "Cargo.lock": parse_toml_packages,
    "go.sum": parse_go_sum,
}


def parser_for(basename):
    return PARSERS.get(basename) or (parse_requirements if basename.endswith(".txt") else None)


def ecosystem_for(basename):
    for pattern, eco in LOCKFILES:
        if pattern.match(basename):
            return eco
    return None


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def excluded(path, patterns):
    """fnmatch where * crosses /, so **/x also matches x at the root."""
    return any(fnmatch.fnmatch(path, p) or (p.startswith("**/") and fnmatch.fnmatch(path, p[3:])) for p in patterns)


def added_packages(base_sha, ecosystems, exclude):
    """[(ecosystem, name, version, file, line)] for packages only on the head side."""
    changed = git("diff", "--name-only", "--diff-filter=ACMR", base_sha, "HEAD").split()
    out = []
    for path in changed:
        base = os.path.basename(path)
        eco = ecosystem_for(base)
        if eco not in ecosystems or excluded(path, exclude):
            continue
        parse = parser_for(base)
        try:
            head_text = Path(path).read_text(encoding="utf-8", errors="ignore")
            try:
                base_text = git("show", f"{base_sha}:{path}")
            except subprocess.CalledProcessError:
                base_text = ""
            head_pkgs = parse(head_text)
            base_pkgs = parse(base_text) if base_text.strip() else {}
        except Exception as exc:  # malformed lockfile: report, keep going
            warn(f"{path}: cannot parse ({exc})")
            continue
        lines = head_text.splitlines()
        for name, version in sorted(head_pkgs.items()):
            if base_pkgs.get(name) == version:
                continue
            line = next((i for i, l in enumerate(lines, 1) if name in l), 1)
            out.append((eco, name, version, path, line))
    return out


# --- deps.dev client with a file cache --------------------------------------

class DepsDev:
    def __init__(self, cache_dir, offline):
        self.cache_dir = Path(cache_dir)
        self.offline = offline

    def _get(self, url):
        req = urllib.request.Request(url, headers={"User-Agent": "sparkgeo-github-actions dependency-reputation"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise

    def lookup(self, system, name, version):
        """{version, project, latest_published_at} or {missing: true} or None when offline and uncached."""
        path = self.cache_dir / system / f"{urllib.parse.quote(name, safe='')}@{version}.json"
        if path.is_file():
            with open(path) as f:
                return json.load(f)
        if self.offline:
            return None
        q = urllib.parse.quote
        ver = self._get(f"{API}/systems/{system}/packages/{q(name, safe='')}/versions/{q(version, safe='')}")
        if ver is None:
            data = {"missing": True}
        else:
            project = None
            for rel in ver.get("relatedProjects", []):
                if rel.get("relationType") == "SOURCE_REPO":
                    project = self._get(f"{API}/projects/{q(rel['projectKey']['id'], safe='')}")
                    break
            pkg = self._get(f"{API}/systems/{system}/packages/{q(name, safe='')}") or {}
            dates = [v.get("publishedAt") for v in pkg.get("versions", []) if v.get("publishedAt")]
            data = {"version": ver, "project": project, "latest_published_at": max(dates) if dates else None}
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            json.dump(data, f)
        return data


def assess(entry, data, args, now):
    """Fill one package record from a deps.dev cache record and apply the gates."""
    flags, blocking = [], False
    if data is None:
        flags.append("uncached")
    elif data.get("missing"):
        flags.append("unknown")
    else:
        ver, project = data["version"], data.get("project")
        entry["advisories"] = [a["id"] for a in ver.get("advisoryKeys", [])]
        entry["malicious"] = any(a.startswith("MAL-") for a in entry["advisories"])
        entry["published_at"] = ver.get("publishedAt")
        entry["last_release"] = data.get("latest_published_at")
        if project:
            entry["repository"] = project["projectKey"]["id"]
            sc = project.get("scorecard") or {}
            if sc:
                entry["score"] = sc.get("overallScore")
                entry["checks"] = {c["name"]: c["score"] for c in sc.get("checks", []) if c["name"] in CHECKS}
        if entry["malicious"]:
            flags.append("malicious")
            blocking |= args.fail_on_malicious
        if entry["score"] is None:
            flags.append("no-scorecard")
        elif args.min_scorecard > 0 and entry["score"] < args.min_scorecard:
            flags.append("low-score")
            blocking = True
        last = parse_ts(entry["last_release"])
        if last and (now - last).days > args.max_age_days:
            flags.append("stale")
    entry["flags"] = flags
    entry["blocking"] = blocking


def write_report(path, packages, args):
    blocking = sum(1 for p in packages if p["blocking"])
    lines = ["<!-- dependency-reputation -->"]
    if not packages:
        lines.append("## Dependency reputation: no dependencies added")
    else:
        lines.append(f"## Dependency reputation: {len(packages)} added, {blocking} blocking")
        lines.append("")
        lines.append("| Package | Version | Score | " + " | ".join(CHECKS) + " | Last release | Advisories | Flags | Source |")
        lines.append("|---|---|---|" + "---|" * len(CHECKS) + "---|---|---|---|")
        for p in packages:
            checks = " | ".join(str(p["checks"].get(c, "")) for c in CHECKS)
            last = (p["last_release"] or "")[:10]
            adv = ", ".join(p["advisories"]) or ""
            flags = ", ".join(("**blocking**: " if p["blocking"] else "") + f for f in p["flags"]) if p["flags"] else "ok"
            repo = p["repository"] or ""
            lines.append(f"| `{p['name']}` | {p['version']} | {'' if p['score'] is None else p['score']} | {checks} "
                         f"| {last} | {adv} | {flags} | {repo} |")
    lines.append("")
    lines.append(f"Gates: fail-on-malicious `{str(args.fail_on_malicious).lower()}`, min-scorecard `{args.min_scorecard}`, "
                 f"max-age-days `{args.max_age_days}`. Data: deps.dev (OSV advisories, OpenSSF Scorecard).")
    text = "\n".join(lines) + "\n"
    with open(path, "w") as f:
        f.write(text)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-sha", default="")
    ap.add_argument("--ecosystems", default="npm,pypi,go,cargo")
    ap.add_argument("--min-scorecard", type=float, default=0)
    ap.add_argument("--max-age-days", type=int, default=730)
    ap.add_argument("--fail-on-malicious", default="true")
    ap.add_argument("--exclude", default="**/tests/**,**/test/**,**/fixtures/**",
                    help="comma-separated globs of lockfile paths to ignore")
    ap.add_argument("--cache-dir", default="deps-dev-cache")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--now", help="override the clock (ISO 8601 Z), for tests")
    ap.add_argument("--output", required=True)
    ap.add_argument("--report", required=True)
    args = ap.parse_args()
    args.fail_on_malicious = str(args.fail_on_malicious).lower() == "true"

    ecosystems = {e.strip().lower() for e in args.ecosystems.split(",") if e.strip()}
    bad = ecosystems - set(SYSTEMS)
    if bad:
        return usage_error(f"unsupported ecosystem {', '.join(sorted(bad))}; use {', '.join(SYSTEMS)}")
    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc)

    packages = []
    if not args.base_sha:
        print(f"::notice title={TITLE}::no base commit given (not a pull request?); nothing to diff")
    else:
        client = DepsDev(args.cache_dir, args.offline)
        exclude = [x.strip() for x in args.exclude.split(",") if x.strip()]
        for eco, name, version, path, line in added_packages(args.base_sha, ecosystems, exclude):
            system = SYSTEMS[eco]
            entry = {"system": system, "name": name, "version": version, "file": path, "line": line,
                     "repository": None, "score": None, "checks": {}, "advisories": [], "malicious": False,
                     "published_at": None, "last_release": None}
            try:
                data = client.lookup(system, name, version)
            except (urllib.error.URLError, OSError) as exc:
                warn(f"deps.dev lookup failed for {name}@{version}: {exc}")
                data = None
            assess(entry, data, args, now)
            packages.append(entry)

    for p in packages:
        if not p["flags"]:
            continue
        level = "error" if p["blocking"] else "warning"
        print(f"::{level} file={p['file']},line={p['line']},title={TITLE}::{p['name']}@{p['version']} "
              f"{', '.join(p['flags'])}" + (f" (score {p['score']})" if p["score"] is not None else ""))

    blocking = sum(1 for p in packages if p["blocking"])
    with open(args.output, "w") as f:
        json.dump({"added_count": len(packages), "blocking_count": blocking, "packages": packages}, f, indent=1)
        f.write("\n")
    report = write_report(args.report, packages, args)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"added-count={len(packages)}\nblocking-count={blocking}\nreport-path={args.report}\n")
    print(f"{TITLE}: {len(packages)} added, {blocking} blocking")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
