#!/usr/bin/env python3
"""External attack-surface scan: scope check and reconciliation (issue #184).

Usage:
  reconcile.py check-scope --scope easm/scope.json
  reconcile.py reconcile --scope FILE --out-dir DIR [--register assets.json]
                         [--dnsx FILE] [--httpx FILE] [--naabu FILE]
                         [--nuclei FILE] [--dnstwist FILE] [--now ISO8601]
                         [--unknown-threshold 3]

check-scope: every domain and CIDR has an owner and an authorisation
('owned', or a reference for client-run infrastructure); exit 1 otherwise.

reconcile: joins the discovery outputs (dnsx, httpx, naabu JSON lines; nuclei
JSON lines; dnstwist JSON) with what we expect to be public: known_hosts from
the scope file plus the asset register's DNS records and `exposure=public`
resources. Writes findings.json, unknown-assets.md, retired-candidates.md,
public-assets.md (the quarterly attestation list) and summary.md. Finding
kinds: unknown-asset (High), takeover-candidate (High), nuclei finding (its own
severity), lookalike-domain (Medium), retired-candidate (informational).

Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

DNS_TYPES = {"aws_route53_record", "AWS::Route53::RecordSet", "google_dns_record_set",
             "azurerm_dns_a_record", "azurerm_dns_cname_record", "cloudflare_record"}
HOST_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")
SEVERITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}


def norm(host):
    return (host or "").strip().lower().rstrip(".")


def read_jsonl(path):
    if not path or not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                print(f"::warning title=easm::skipping unparseable line in {path}")
    return out


def read_json(path, default):
    if not path or not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def in_scope(host, domains):
    return any(host == d or host.endswith("." + d) for d in domains)


def check_scope(scope):
    errors = []
    for d in scope.get("domains", []):
        if not HOST_RE.match(norm(d.get("domain", ""))):
            errors.append(f"domain {d.get('domain')!r} is not a hostname")
        if not d.get("owner"):
            errors.append(f"domain {d.get('domain')} has no owner")
        if not d.get("authorisation"):
            errors.append(f"domain {d.get('domain')} has no authorisation ('owned' or a reference to the client's written authorisation)")
    for c in scope.get("cidrs", []):
        if not c.get("owner") or not c.get("authorisation"):
            errors.append(f"cidr {c.get('cidr')} needs owner and authorisation")
    for h in scope.get("known_hosts", []):
        if not h.get("owner"):
            errors.append(f"known host {h.get('host')} has no owner")
        if not in_scope(norm(h.get("host", "")), [norm(d["domain"]) for d in scope.get("domains", []) if d.get("domain")]):
            errors.append(f"known host {h.get('host')} is outside every scoped domain")
    for e in errors:
        print(f"::error title=easm scope::{e}")
    return 1 if errors else 0


def expected_public(scope, register):
    """host -> {"owner", "source"} for everything we expect to answer from the internet."""
    exp = {}
    for h in scope.get("known_hosts", []):
        exp[norm(h["host"])] = {"owner": h.get("owner", ""), "source": "scope.known_hosts"}
    for a in (register or {}).get("assets", []):
        tags = a.get("tags") or {}
        name = norm(a.get("name", ""))
        if a.get("type") in DNS_TYPES and HOST_RE.match(name):
            exp.setdefault(name, {"owner": tags.get("owner", ""), "source": f'{a["repo"]} {a["id"]}'})
        elif tags.get("exposure") == "public" and HOST_RE.match(name):
            exp.setdefault(name, {"owner": tags.get("owner", ""), "source": f'{a["repo"]} {a["id"]} (exposure=public)'})
    return exp


def reconcile(args):
    scope = read_json(args.scope, {})
    domains = [norm(d["domain"]) for d in scope.get("domains", []) if d.get("domain")]
    exclude = {norm(h) for h in scope.get("exclude", [])}
    register = read_json(args.register, None) if args.register else None
    expected = expected_public(scope, register)
    now = datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if args.now \
        else datetime.now(timezone.utc).replace(microsecond=0)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    live = {}  # host -> details
    for r in read_jsonl(args.dnsx):
        host = norm(r.get("host"))
        if not host or host in exclude:
            continue
        d = live.setdefault(host, {"a": [], "aaaa": [], "cname": [], "ports": set(), "http": []})
        d["a"] += r.get("a") or []
        d["aaaa"] += r.get("aaaa") or []
        d["cname"] += [norm(c) for c in (r.get("cname") or [])]
    for r in read_jsonl(args.httpx):
        host = norm(r.get("host") or r.get("input"))
        if not host or host in exclude:
            continue
        d = live.setdefault(host, {"a": [], "aaaa": [], "cname": [], "ports": set(), "http": []})
        if r.get("port"):
            d["ports"].add(int(r["port"]))
        d["http"].append({"url": r.get("url"), "status": r.get("status_code"), "title": r.get("title"),
                          "tech": r.get("tech") or []})
    for r in read_jsonl(args.naabu):
        host = norm(r.get("host") or r.get("ip"))
        if host and host not in exclude and r.get("port"):
            live.setdefault(host, {"a": [], "aaaa": [], "cname": [], "ports": set(), "http": []})["ports"].add(int(r["port"]))

    def answers(d):
        return bool(d["a"] or d["aaaa"] or d["ports"] or d["http"])

    findings = []
    public_rows = []
    for host in sorted(live):
        d = live[host]
        if not answers(d):
            if d["cname"]:  # resolves to a name that resolves to nothing: dangling
                findings.append({"kind": "takeover-candidate", "severity": "high", "host": host,
                                 "detail": f'CNAME to {", ".join(d["cname"])} which resolves to nothing', "seen": stamp})
            continue
        known = expected.get(host)
        owner = known["owner"] if known else ""
        public_rows.append((host, owner or "(unknown)", known["source"] if known else "discovered",
                            ",".join(str(p) for p in sorted(d["ports"])) or "-",
                            ",".join(d["a"] + d["aaaa"]) or "-"))
        if not known and in_scope(host, domains):
            findings.append({"kind": "unknown-asset", "severity": "high", "host": host,
                             "detail": "answers from the internet and matches no register record or known host",
                             "ports": sorted(d["ports"]), "addresses": d["a"] + d["aaaa"], "seen": stamp})

    retired = [(h, expected[h]["owner"], expected[h]["source"]) for h in sorted(expected)
               if h in live and not answers(live[h]) and not live[h]["cname"]]
    for h, owner, source in retired:
        findings.append({"kind": "retired-candidate", "severity": "info", "host": h, "owner": owner,
                         "detail": f"expected public ({source}) but no longer resolves", "seen": stamp})

    for r in read_jsonl(args.nuclei):
        info = r.get("info") or {}
        host = norm(r.get("host") or r.get("matched-at", "").split("/")[2] if "://" in r.get("matched-at", "") else r.get("host"))
        if host in exclude:
            continue
        findings.append({"kind": "nuclei", "severity": (info.get("severity") or "info").lower(), "host": host,
                         "template": r.get("template-id"), "name": info.get("name"),
                         "matched_at": r.get("matched-at"), "seen": stamp})

    for r in read_json(args.dnstwist, []):
        if r.get("domain") in domains:
            continue
        if r.get("dns_a") or r.get("dns_aaaa") or r.get("dns_mx") or r.get("dns_ns"):
            findings.append({"kind": "lookalike-domain", "severity": "medium", "host": r.get("domain"),
                             "detail": f'{r.get("fuzzer")} of a scoped domain; resolves to {", ".join(r.get("dns_a") or r.get("dns_ns") or [])}',
                             "seen": stamp})

    findings.sort(key=lambda f: (SEVERITY_RANK.get(f["severity"], 9), f["kind"], f["host"]))
    unknown = [f for f in findings if f["kind"] == "unknown-asset"]
    counts = {k: sum(1 for f in findings if f["kind"] == k)
              for k in ("unknown-asset", "takeover-candidate", "nuclei", "lookalike-domain", "retired-candidate")}
    inventory_review = len(unknown) > args.unknown_threshold

    os.makedirs(args.out_dir, exist_ok=True)
    out = {"generated_at": stamp, "scope_domains": domains, "live_hosts": len([h for h in live if answers(live[h])]),
           "expected_public": len(expected), "counts": counts, "inventory_review": inventory_review, "findings": findings}
    with open(os.path.join(args.out_dir, "findings.json"), "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")

    def table(headers, rows):
        return "\n".join(["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
                         + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]) + "\n"

    write(args.out_dir, "unknown-assets.md", "# Unknown internet-facing assets\n\n"
          + (table(["Host", "Ports", "Addresses", "Seen"], [(f["host"], ",".join(map(str, f["ports"])) or "-",
                   ",".join(f["addresses"]) or "-", f["seen"]) for f in unknown]) if unknown else "None.\n"))
    write(args.out_dir, "retired-candidates.md", "# Expected public, no longer answering\n\n"
          + (table(["Host", "Owner", "Register source"], retired) if retired else "None.\n"))
    write(args.out_dir, "public-assets.md", f"# Public asset list, {stamp[:10]}\n\n"
          "Every host that answered from the internet in this run. The security owner attests this list each quarter "
          "(SecOps plan Step 31 Standard). A host with owner `(unknown)` is an open unknown-asset finding.\n\n"
          + (table(["Host", "Owner", "Source", "Open ports", "Addresses"], public_rows) if public_rows else "None.\n"))
    summary = [f"## External attack surface: {out['live_hosts']} live hosts, {len(unknown)} unknown", "",
               f"Expected public: {out['expected_public']}. Findings: " + ", ".join(f"{k} {v}" for k, v in counts.items()) + "."]
    if inventory_review:
        summary.append(f"\n**{len(unknown)} unknown assets exceeds the threshold of {args.unknown_threshold}: inventory review.**")
    if unknown:
        summary += ["", "### Unknown assets", ""] + [f"- `{f['host']}` ports {','.join(map(str, f['ports'])) or '-'}" for f in unknown]
    write(args.out_dir, "summary.md", "\n".join(summary) + "\n")
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as f:
            f.write("\n".join(summary) + "\n")
    print("\n".join(summary))
    return 0


def write(out_dir, name, text):
    with open(os.path.join(out_dir, name), "w") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check-scope")
    c.add_argument("--scope", required=True)
    r = sub.add_parser("reconcile")
    r.add_argument("--scope", required=True)
    r.add_argument("--out-dir", required=True)
    r.add_argument("--register")
    for name in ("dnsx", "httpx", "naabu", "nuclei", "dnstwist"):
        r.add_argument(f"--{name}")
    r.add_argument("--now")
    r.add_argument("--unknown-threshold", type=int, default=3)
    args = ap.parse_args()
    if args.cmd == "check-scope":
        return check_scope(read_json(args.scope, {}))
    return reconcile(args)


if __name__ == "__main__":
    sys.exit(main())
