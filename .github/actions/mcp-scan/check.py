#!/usr/bin/env python3
"""MCP server and skill allowlist, lockfile and finding gate (issue #103).

Usage: check.py --root DIR --inspect inspect.json --allowlist FILE
                [--lock .mcp-scan.lock] [--write-lock] [--skills GLOB,GLOB]
                [--scan scan.json --fail-on high|medium|low] [--output report.json]

inspect.json is the output of `snyk-agent-scan inspect --json` over the
repository's MCP configuration files: the declared servers and, for each one
the scanner could reach, its tool, prompt and resource descriptions. The
checks, in order:

1. Every declared server has an allowlist entry with the same name; the
   declared command line (stdio) or URL (remote) equals the pinned one; the
   entry carries a version; when the server reports a version it equals the
   pinned one; a package-runner command (npx, uvx, pipx, docker, bunx) names
   the version. Otherwise: unknown or unpinned server, error.
2. The sha256 of the server's tool, prompt and resource descriptions equals
   the hash recorded in the lockfile and in the allowlist entry. A changed
   hash is an error until both are updated in the same PR (re-review on
   update). A server the scanner could not reach is an error: its hash
   cannot be verified.
3. Every skill or plugin manifest matching --skills has an allowlist entry
   by path and its file hash equals the lockfile and allowlist hashes.
4. With --scan, a `snyk-agent-scan scan --json` response: any risk score at
   or above the --fail-on band (low 1, medium 300, high 600 of 1000) is an
   error.

--write-lock rewrites the lockfile from the observed hashes before the
comparison, so the only remaining errors are allowlist ones. Standard
library only; run with python3 -I.
"""

import argparse
import glob
import hashlib
import json
import os
import sys

FAIL_ON = {"low": 1, "medium": 300, "high": 600}
PACKAGE_RUNNERS = {"npx", "uvx", "pipx", "docker", "bunx", "pnpx"}


def strip_none(obj):
    if isinstance(obj, dict):
        return {k: strip_none(v) for k, v in obj.items() if v is not None}
    if isinstance(obj, list):
        return [strip_none(v) for v in obj]
    return obj


def digest(obj):
    return "sha256:" + hashlib.sha256(json.dumps(strip_none(obj), sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_digest(path):
    with open(path, "rb") as fh:
        return "sha256:" + hashlib.sha256(fh.read()).hexdigest()


def load_json(path, default):
    if not path or not os.path.exists(path):
        return default
    with open(path) as fh:
        return json.load(fh)


def declared(server):
    """The pinned identity of a declared server: its command line or URL."""
    if "url" in server:
        return "url", server["url"]
    return "command", " ".join([server.get("command", "")] + list(server.get("args") or []))


def check_server_entry(key, name, server, meta, entry, errors):
    if entry is None:
        errors.append(f"{key}: server \"{name}\" is not on the allowlist; add a reviewed entry or remove it")
        return
    kind, value = declared(server)
    pinned = entry.get(kind)
    if not pinned:
        errors.append(f"{key}: allowlist entry \"{name}\" has no \"{kind}\" to pin; add it")
    elif pinned != value:
        errors.append(f"{key}: \"{name}\" declares {kind} \"{value}\" but the allowlist pins \"{pinned}\"")
    version = str(entry.get("version") or "").strip()
    if not version:
        errors.append(f"{key}: allowlist entry \"{name}\" has no pinned version")
        return
    reported = ((meta or {}).get("serverInfo") or {}).get("version")
    if reported and reported != version:
        errors.append(f"{key}: \"{name}\" reports version {reported}, allowlist pins {version}")
    if kind == "command" and value.split(" ", 1)[0] in PACKAGE_RUNNERS and version not in value:
        errors.append(f"{key}: \"{name}\" runs through {value.split(' ', 1)[0]} without the pinned version {version} in the command")


def check_hash(label, observed, lock_hash, entry, lock_name, errors):
    allow_hash = (entry or {}).get("hash")
    if lock_hash is None:
        errors.append(f"{label}: not in {lock_name}; run the check with update-lock after review")
    elif lock_hash != observed:
        errors.append(f"{label}: descriptions changed ({observed} != locked {lock_hash}); re-review, then update {lock_name} and the allowlist entry in the same PR")
    if entry is None:
        return  # already reported as not on the allowlist
    if allow_hash is None:
        errors.append(f"{label}: allowlist entry has no hash")
    elif allow_hash != observed:
        errors.append(f"{label}: allowlist hash {allow_hash} differs from observed {observed}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--inspect", default="")
    ap.add_argument("--allowlist", required=True)
    ap.add_argument("--lock", default=".mcp-scan.lock")
    ap.add_argument("--write-lock", action="store_true")
    ap.add_argument("--skills", default=".claude/skills/*/SKILL.md,.claude-plugin/plugin.json,.claude-plugin/marketplace.json")
    ap.add_argument("--scan", default="")
    ap.add_argument("--fail-on", default="high", choices=sorted(FAIL_ON))
    ap.add_argument("--output")
    args = ap.parse_args()

    allow = load_json(args.allowlist, {})
    allow_servers = {e.get("name"): e for e in allow.get("servers", [])}
    allow_skills = {e.get("path"): e for e in allow.get("skills", [])}
    lock_path = os.path.join(args.root, args.lock)
    lock = load_json(lock_path, {"version": 1, "servers": {}, "skills": {}})
    errors, servers, skills = [], {}, {}

    for path, result in (load_json(args.inspect, {}) or {}).items():
        rel = os.path.relpath(path, args.root) if os.path.isabs(path) else path
        if result.get("error"):
            errors.append(f"{rel}: {result['error'].get('message')}")
        for s in result.get("servers", []):
            key = f"{rel}::{s['name']}"
            sig = s.get("signature") or {}
            entry = allow_servers.get(s["name"])
            check_server_entry(key, s["name"], s.get("server") or {}, sig.get("metadata"), entry, errors)
            if s.get("error") or not s.get("signature"):
                errors.append(f"{key}: could not read its tool descriptions ({(s.get('error') or {}).get('message', 'no signature')}); hash not verified")
                servers[key] = None
                continue
            observed = digest({k: sig.get(k) for k in ("tools", "prompts", "resources", "resource_templates")})
            servers[key] = observed

    for pattern in [p.strip() for p in args.skills.split(",") if p.strip()]:
        for hit in sorted(glob.glob(pattern, root_dir=args.root, recursive=True, include_hidden=True)):
            rel = hit.replace(os.sep, "/")
            if os.path.isfile(os.path.join(args.root, hit)):
                skills[rel] = file_digest(os.path.join(args.root, hit))
                if rel not in allow_skills:
                    errors.append(f"{rel}: skill is not on the allowlist; add a reviewed entry or remove it")

    if args.write_lock:
        lock = {"version": 1,
                "servers": {k: v for k, v in servers.items() if v},
                "skills": skills}
        with open(lock_path, "w") as fh:
            json.dump(lock, fh, indent=2, sort_keys=True)
            fh.write("\n")
    for key, observed in servers.items():
        if observed:
            check_hash(key, observed, lock.get("servers", {}).get(key), allow_servers.get(key.split("::", 1)[1]), args.lock, errors)
    for rel, observed in skills.items():
        check_hash(rel, observed, lock.get("skills", {}).get(rel), allow_skills.get(rel), args.lock, errors)
    for key in sorted(set(lock.get("servers", {})) - set(servers)):
        errors.append(f"{key}: in {args.lock} but no longer declared; remove the stale lock entry")
    for rel in sorted(set(lock.get("skills", {})) - set(skills)):
        errors.append(f"{rel}: in {args.lock} but the file is gone; remove the stale lock entry")

    findings = []
    threshold = FAIL_ON[args.fail_on]
    for path in (load_json(args.scan, {}) or {}).get("scan_path_responses", []):
        for kind in ("server_risks", "skill_risks"):
            for item in path.get(kind, []):
                for risk, score in (item.get("risk_indexes") or {}).items():
                    if score and score.get("score", 0) >= 1:
                        band = "high" if score["score"] >= 600 else "medium" if score["score"] >= 300 else "low"
                        findings.append((item.get("name"), risk, score["score"], band, score.get("evidence", "")))
                        if score["score"] >= threshold:
                            errors.append(f"{path.get('path')}::{item.get('name')}: {risk} score {score['score']}/1000 ({band}): {score.get('evidence', '')}")

    for e in errors:
        print(f"::error title=mcp-scan::{e}")
    summary = [f"## MCP scan: {len(servers)} server(s), {len(skills)} skill file(s), {len(findings)} finding(s), {len(errors)} error(s)", ""]
    if servers or skills:
        summary += ["| Item | Hash | Status |", "|---|---|---|"]
        for k, v in list(servers.items()) + list(skills.items()):
            status = "**error**" if any(e.startswith(k + ":") for e in errors) else "ok"
            summary.append(f"| `{k}` | `{(v or 'unverified')[:19]}` | {status} |")
    if findings:
        summary += ["", "### Analysis findings", "", "| Item | Risk | Score | Band |", "|---|---|---|---|"]
        summary += [f"| {n} | {r} | {s} | {b} |" for n, r, s, b, _ in findings]
    if errors:
        summary += ["", "### Errors", ""] + [f"- {e}" for e in errors]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"server-count={len(servers)}\nskill-count={len(skills)}\nerror-count={len(errors)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"servers": servers, "skills": skills, "findings": findings, "errors": errors}, fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
