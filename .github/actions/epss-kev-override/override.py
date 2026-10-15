#!/usr/bin/env python3
"""Apply the Remediation SLA Table likelihood override to a findings file.

Usage: override.py --findings FILE --output FILE --feeds-dir DIR
                   [--format osv-json] [--snapshot-tag TAG]
                   [--epss-threshold 0.10] [--kev true] [--lev-threshold 0.5]
                   [--epss-history FILE ...] [--downgrade false]
                   [--downgrade-epss 0.01] [--downgrade-lev 0.1]
                   [--runtime-relevance FILE] [--summary FILE]

Rows (SecOps plan Step 25, docs/gate-policy.md): critical >= 9.0,
high >= 7.0, medium >= 4.0, low >= 0.1. Per osv-json group (one advisory and
its aliases), using every CVE alias in the group:

  up        EPSS >= epss-threshold, on CISA KEV, or LEV >= lev-threshold
            (treated as a KEV hit) -> critical (9.0)
  down      with --downgrade: CVSS high or critical, every CVE has
            EPSS < downgrade-epss, none on KEV, LEV known and < downgrade-lev
            -> one row down
  runtime   with --runtime-relevance: every CVE in the group is marked
            relevant: false for this package in the #179 export -> one row
            down (applied after the others; low stays low)

A moved row is written as that row's floor score, so severity-gate reads the
new row. Every group with a CVE gets an `override` object: original score,
modifiers applied, per-CVE EPSS/percentile/KEV dateAdded/LEV, the snapshot
tag, and the SSVC decision points this data can supply (exploitation
"active" when on KEV; automatable from the CVSS vector AV:N/PR:N/UI:N).

LEV (NIST CSWP 41): 1 - prod(1 - epss(d_i) * weight(d_i)) over d_i every 30
days from the oldest EPSS snapshot given to the newest, weight 1 for a full
30-day window and (days left)/30 for the last. epss(d_i) is read from the
newest snapshot dated on or before d_i; a CVE absent from it counts as 0.
Needs at least two snapshot dates, otherwise LEV is unknown (null) and no
finding is downgraded. The window is bounded by the snapshots given (the
#109 mirror keeps 90 days), so LEV is a lower bound, as in the paper.

Exit codes: 0 ok; 1 bad input. Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import re
import sys
from datetime import date, timedelta

ROWS = [("critical", 9.0), ("high", 7.0), ("medium", 4.0), ("low", 0.1), ("none", 0.0)]
CVE = re.compile(r"^CVE-\d{4}-\d+$")
WINDOW = 30


def row(score):
    for i, (_, floor) in enumerate(ROWS):
        if score >= floor:
            return i
    return len(ROWS) - 1


def down_one(score):
    i = row(score)
    if i >= 3:  # low and none stay put
        return score
    return ROWS[i + 1][1]


def load_envelope(path, feed):
    with open(path, encoding="utf-8") as f:
        env = json.load(f)
    if env.get("feed") != feed:
        sys.exit(f"{path}: expected a '{feed}' feed envelope, got '{env.get('feed')}'")
    return env


def epss_snapshot(path):
    env = load_envelope(path, "epss")
    day = (env.get("meta") or {}).get("score_date") or env.get("fetched_at") or ""
    try:
        d = date.fromisoformat(day[:10])
    except ValueError:
        sys.exit(f"{path}: no score_date or fetched_at")
    return d, {e["value"]: e.get("meta", {}) for e in env["entries"]}


def lev(cve, snapshots):
    """snapshots: list of (date, {cve: meta}) sorted oldest first."""
    if len({d for d, _ in snapshots}) < 2:
        return None
    d0, dn = snapshots[0][0], snapshots[-1][0]
    p, di = 1.0, d0
    while di <= dn:
        scores = [s for d, s in snapshots if d <= di][-1]
        epss = float(scores.get(cve, {}).get("epss", 0.0))
        days = WINDOW if di + timedelta(days=WINDOW - 1) <= dn else (dn - di).days + 1
        p *= 1 - epss * days / WINDOW
        di += timedelta(days=WINDOW)
    return round(1 - p, 6)


def automatable(vulns):
    for v in vulns:
        for s in v.get("severity") or []:
            vec = s.get("score", "")
            if vec.startswith("CVSS:") and all(m in vec.split("/") for m in ("AV:N", "PR:N", "UI:N")):
                return "yes"
    return "no"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--findings", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--feeds-dir", required=True)
    ap.add_argument("--format", default="osv-json")
    ap.add_argument("--snapshot-tag", default="")
    ap.add_argument("--epss-threshold", type=float, default=0.10)
    ap.add_argument("--kev", default="true")
    ap.add_argument("--lev-threshold", type=float, default=0.5)
    ap.add_argument("--epss-history", nargs="*", default=[])
    ap.add_argument("--downgrade", default="false")
    ap.add_argument("--downgrade-epss", type=float, default=0.01)
    ap.add_argument("--downgrade-lev", type=float, default=0.1)
    ap.add_argument("--runtime-relevance", default="")
    ap.add_argument("--summary", default="")
    a = ap.parse_args()
    if a.format != "osv-json":
        sys.exit(f"unsupported format '{a.format}' (osv-json)")
    use_kev, use_down = a.kev == "true", a.downgrade == "true"

    kev = {e["value"]: e.get("first_seen", "")[:10]
           for e in load_envelope(f"{a.feeds_dir}/kev.json", "kev")["entries"]}
    current = epss_snapshot(f"{a.feeds_dir}/epss.json")
    by_date = {d: s for d, s in map(epss_snapshot, a.epss_history)}
    by_date[current[0]] = current[1]
    snapshots = sorted(by_date.items())

    not_loaded = set()
    if a.runtime_relevance:
        with open(a.runtime_relevance, encoding="utf-8") as f:
            export = json.load(f)
        for e in export.get("entries", export) if isinstance(export, dict) else export:
            if e.get("relevant") is False:
                not_loaded.add((e.get("package"), e.get("cve")))

    with open(a.findings, encoding="utf-8") as f:
        doc = json.load(f)

    changes = []
    for result in doc.get("results") or []:
        for pkg in result.get("packages") or []:
            name = (pkg.get("package") or {}).get("name", "")
            vulns = {v.get("id"): v for v in pkg.get("vulnerabilities") or []}
            for g in pkg.get("groups") or []:
                cves = sorted({i for i in (g.get("aliases") or []) + (g.get("ids") or []) if CVE.match(i)})
                if not cves:
                    continue  # MAL-* and GHSA-only advisories: nothing to look up
                raw = g.get("max_severity")
                score = float(raw) if raw not in (None, "") else 0.0
                per = {}
                for c in cves:
                    m = current[1].get(c, {})
                    per[c] = {"epss": m.get("epss"), "percentile": m.get("percentile"),
                              "kev_date_added": kev.get(c), "lev": lev(c, snapshots)}
                on_kev = use_kev and any(p["kev_date_added"] for p in per.values())
                hot_epss = any((p["epss"] or 0) >= a.epss_threshold for p in per.values())
                hot_lev = any(p["lev"] is not None and p["lev"] >= a.lev_threshold for p in per.values())
                applied, new = [], score
                if on_kev or hot_epss or hot_lev:
                    if new < 9.0:
                        new = 9.0
                        applied.append("up:" + ",".join(
                            r for r, hit in (("kev", on_kev), ("epss", hot_epss), ("lev", hot_lev)) if hit))
                elif use_down and new >= 7.0 and all(
                        (p["epss"] or 0) < a.downgrade_epss and not p["kev_date_added"]
                        and p["lev"] is not None and p["lev"] < a.downgrade_lev for p in per.values()):
                    new = down_one(new)
                    applied.append("down:likelihood")
                if not_loaded and all((name, c) in not_loaded for c in cves) and row(new) < 3:
                    new = down_one(new)
                    applied.append("down:runtime-relevance")
                group_vulns = [vulns[i] for i in g.get("ids") or [] if i in vulns]
                ssvc = {"automatable": automatable(group_vulns)}
                if any(p["kev_date_added"] for p in per.values()):
                    ssvc["exploitation"] = "active"
                g["override"] = {"original_max_severity": raw, "applied": applied, "snapshot": a.snapshot_tag,
                                 "cves": per, "ssvc": ssvc}
                if applied:
                    g["max_severity"] = f"{new:.1f}"
                    changes.append((name, ",".join(g.get("ids") or []), cves, score, new, applied))

    with open(a.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)

    for name, ids, cves, old, new, applied in changes:
        print(f"::notice title=epss-kev-override::{name} {ids} ({','.join(cves)}): "
              f"{ROWS[row(old)][0]} {old} -> {ROWS[row(new)][0]} {new} [{' '.join(applied)}]")
    up = sum(1 for c in changes if any(x.startswith("up:") for x in c[5]))
    print(f"{up} finding(s) raised, {len(changes) - up} lowered")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write(f"uplifted={up}\ndowngraded={len(changes) - up}\n")
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(f"### EPSS/KEV override ({a.snapshot_tag or 'snapshot tag not given'}; "
                    f"EPSS scores of {current[0]}, LEV over {len(snapshots)} snapshot(s))\n\n")
            if not changes:
                f.write("No finding changed row.\n")
            else:
                f.write("| Package | Advisory | CVEs | From | To | Why |\n|---|---|---|---|---|---|\n")
                for name, ids, cves, old, new, applied in changes:
                    f.write(f"| {name} | {ids} | {', '.join(cves)} | {old} | {new} | {' '.join(applied)} |\n")


if __name__ == "__main__":
    main()
