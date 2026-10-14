#!/usr/bin/env python3
"""Match new KEV entries and CISA advisories against the products we run.

Usage: match.py --feeds-dir DIR --products FILE --output FILE
                [--register FILE] [--window-days 7] [--now ISO8601]

Reads kev.json, advisories.json and (optionally) vulnrichment.json from the
threat-feeds snapshot, the product list (policies/threat-intel/products.json)
and, when given, the asset register (register/assets.json from
asset-register-rollup.yml) for the exposure tag and owners of each product's
repositories. Writes {"generated_at", "window_days", "matches": [...]}, one
match per (signal, product). SecOps plan Step 27 Standard and Step 40 trigger
table: a KEV entry or advisory naming an inventoried product is a High-tier
trigger validated within 72 hours; a KEV entry with total technical impact on
a publicly exposed asset also opens forensic triage (Step 25, BOD 26-04).

Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

HIGH_HOURS = 72


def parse_ts(value):
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            continue
    return None


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_feed(feeds_dir, name):
    path = os.path.join(feeds_dir, f"{name}.json")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return json.load(f).get("entries", [])


def load_products(path):
    with open(path) as f:
        products = json.load(f)["products"]
    for p in products:
        aliases = {p["name"]} | set(p.get("match", []))
        p["_aliases"] = sorted(a.lower() for a in aliases if a)
        p.setdefault("repos", [])
        p.setdefault("exposure", "internal")
    return products


def register_index(path):
    """repo -> {"exposure": public|internal, "owners": [...]} from register/assets.json."""
    if not path:
        return {}
    with open(path) as f:
        assets = json.load(f).get("assets", [])
    idx = {}
    for a in assets:
        tags = a.get("tags") or {}
        r = idx.setdefault(a["repo"], {"exposure": "internal", "owners": set()})
        if tags.get("exposure") == "public":
            r["exposure"] = "public"
        if tags.get("owner"):
            r["owners"].add(tags["owner"])
    return {k: {"exposure": v["exposure"], "owners": sorted(v["owners"])} for k, v in idx.items()}


def hits(haystack, products):
    hay = haystack.lower()
    return [p for p in products if any(a in hay for a in p["_aliases"])]


def product_context(p, register):
    exposure = p["exposure"]
    owners = set([p["owner"]] if p.get("owner") else [])
    for repo in p["repos"]:
        r = register.get(repo)
        if not r:
            continue
        if r["exposure"] == "public":
            exposure = "public"
        owners.update(r["owners"])
    return exposure, sorted(owners)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feeds-dir", required=True)
    ap.add_argument("--products", required=True)
    ap.add_argument("--register")
    ap.add_argument("--window-days", type=int, default=7)
    ap.add_argument("--now")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc).replace(microsecond=0)
    cutoff = now - timedelta(days=args.window_days)
    products = load_products(args.products)
    register = register_index(args.register)
    ssvc = {e["value"]: e.get("meta", {}) for e in load_feed(args.feeds_dir, "vulnrichment")}

    matches, unmatched = [], []
    for e in load_feed(args.feeds_dir, "kev"):
        added = parse_ts(e.get("first_seen"))
        if added is None or added < cutoff:
            continue
        m = e.get("meta", {})
        found = hits(f'{m.get("vendor", "")} {m.get("product", "")} {m.get("name", "")}', products)
        if not found:
            unmatched.append(f'{e["value"]} {m.get("vendor", "")} {m.get("product", "")}'.strip())
        for p in found:
            exposure, owners = product_context(p, register)
            sv = ssvc.get(e["value"], {})
            forensic = exposure == "public" and (
                sv.get("technical_impact") == "total" or str(m.get("forensic_triage", "")).lower() == "yes")
            matches.append({
                "kind": "kev", "id": e["value"], "title": m.get("name"),
                "vendor": m.get("vendor"), "product_name": m.get("product"),
                "kev_added": e.get("first_seen"), "kev_due": m.get("due_date"),
                "ransomware": m.get("ransomware"), "ssvc": sv or None,
                "product": p["name"], "repos": p["repos"], "exposure": exposure, "owners": owners,
                "tier": "high", "validate_by": iso(now + timedelta(hours=HIGH_HOURS)),
                "sla": "critical", "forensic_triage": forensic,
                "url": f'https://www.cisa.gov/known-exploited-vulnerabilities-catalog?search_api_fulltext={e["value"]}',
            })

    for e in load_feed(args.feeds_dir, "advisories"):
        published = parse_ts(e.get("first_seen"))
        if published is None or published < cutoff:
            continue
        m = e.get("meta", {})
        for p in hits(m.get("title", ""), products):
            exposure, owners = product_context(p, register)
            matches.append({
                "kind": "advisory", "id": e["value"], "title": m.get("title"), "cves": m.get("cves", []),
                "published": e.get("first_seen"),
                "product": p["name"], "repos": p["repos"], "exposure": exposure, "owners": owners,
                "tier": "high", "validate_by": iso(now + timedelta(hours=HIGH_HOURS)),
                "sla": "high", "forensic_triage": False, "url": e["value"],
            })

    out = {"generated_at": iso(now), "window_days": args.window_days, "cutoff": iso(cutoff),
           "matches": matches, "unmatched_kev": unmatched}
    with open(args.output, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = ["## KEV and advisory trigger", "", f"Window: {args.window_days} days to {iso(now)}. "
             f"{len(matches)} match(es), {len(unmatched)} new KEV entries with no product match.", ""]
    if matches:
        lines += ["| Signal | Product | Exposure | SLA | Forensic triage | Validate by |", "|---|---|---|---|---|---|"]
        lines += [f'| {x["id"]} | {x["product"]} | {x["exposure"]} | {x["sla"]} | {"yes" if x["forensic_triage"] else "no"} | {x["validate_by"]} |'
                  for x in matches]
    if unmatched:
        lines += ["", "<details><summary>New KEV entries with no product match (is products.json complete?)</summary>", ""]
        lines += [f"- {u}" for u in unmatched] + ["", "</details>"]
    text = "\n".join(lines) + "\n"
    if summary:
        with open(summary, "a") as f:
            f.write(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
