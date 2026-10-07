#!/usr/bin/env python3
"""Normalise one upstream threat feed into the mirror's common envelope.

Usage: normalize.py --feed <kev|epss|threatfox|feodo|urlhaus> --input FILE
                    --output FILE [--previous FILE] [--now ISO8601]

Envelope: {"feed", "fetched_at", "source_url", "count", "dropped_count",
           "skipped_count", "meta", "entries": [...]}
Entry:    {"value", "type" (cve|ip|cidr|domain|url), "confidence" (0-100),
           "first_seen"?, "last_seen"?, "expires_at"?, "meta"?}

Expiry (SecOps plan Step 27 IOC lifecycle): ip 30 days, url 60, domain 90,
cve never. The clock runs from last_seen when the feed has it, else
first_seen. Expired entries are dropped and counted.

Exit codes: 0 ok; 1 unreadable or empty feed; 2 entry count fell by more
than half against --previous (the mirror treats this as an upstream outage).
Standard library only; run with python3 -I.
"""

import argparse
import csv
import gzip
import io
import json
import os
import sys
from datetime import datetime, timedelta, timezone

EXPIRY_DAYS = {"ip": 30, "url": 60, "domain": 90, "cve": None, "cidr": 30}

SOURCE_URLS = {
    "kev": "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json",
    "epss": "https://epss.empiricalsecurity.com/epss_scores-current.csv.gz",
    "threatfox": "https://threatfox.abuse.ch/export/json/recent/",
    "feodo": "https://feodotracker.abuse.ch/downloads/ipblocklist.json",
    "urlhaus": "https://urlhaus.abuse.ch/downloads/csv_recent/",
}

MAX_DROP_RATIO = 0.5


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(value):
    """Feed timestamps: 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS' or ISO 8601. None if absent."""
    if not value:
        return None
    value = str(value).strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def read_text(path):
    with open(path, "rb") as f:
        raw = f.read()
    if path.endswith(".gz") or raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return raw.decode("utf-8")


def entry(value, typ, confidence, first_seen=None, last_seen=None, meta=None):
    e = {"value": value, "type": typ, "confidence": int(confidence)}
    if first_seen:
        e["first_seen"] = iso(first_seen)
    if last_seen:
        e["last_seen"] = iso(last_seen)
    if meta:
        e["meta"] = meta
    return e


# --- per-feed parsers: return (entries, skipped_count, envelope_meta) -------

def parse_kev(text):
    data = json.loads(text)
    out = []
    for v in data.get("vulnerabilities", []):
        out.append(entry(
            v["cveID"], "cve", 100, first_seen=parse_ts(v.get("dateAdded")),
            meta={
                "vendor": v.get("vendorProject"), "product": v.get("product"),
                "name": v.get("vulnerabilityName"), "due_date": v.get("dueDate"),
                "ransomware": v.get("knownRansomwareCampaignUse"),
            },
        ))
    return out, 0, {"catalog_version": data.get("catalogVersion"), "date_released": data.get("dateReleased")}


def parse_epss(text):
    meta = {}
    rows = []
    for line in text.splitlines():
        if line.startswith("#"):
            for kv in line[1:].split(","):
                k, _, v = kv.partition(":")
                meta[k.strip()] = v.strip()
            continue
        rows.append(line)
    out = []
    for r in csv.DictReader(io.StringIO("\n".join(rows))):
        out.append(entry(r["cve"], "cve", 100, meta={"epss": float(r["epss"]), "percentile": float(r["percentile"])}))
    return out, 0, {"model_version": meta.get("model_version"), "score_date": meta.get("score_date")}


def parse_threatfox(text):
    data = json.loads(text)
    out, skipped = [], 0
    for iocs in data.values():
        for i in iocs:
            typ, value = i.get("ioc_type"), i.get("ioc_value")
            meta = {"malware": i.get("malware"), "threat_type": i.get("threat_type"), "tags": i.get("tags")}
            if typ == "ip:port":
                host, _, port = value.rpartition(":")
                typ, value = "ip", host
                meta["port"] = int(port)
            elif typ not in ("domain", "url"):
                skipped += 1  # hashes: checksum-verified downloads already cover that path
                continue
            out.append(entry(value, typ, i.get("confidence_level", 50),
                             first_seen=parse_ts(i.get("first_seen_utc")),
                             last_seen=parse_ts(i.get("last_seen_utc")), meta=meta))
    return out, skipped, {}


def parse_feodo(text):
    out = []
    for i in json.loads(text):
        out.append(entry(
            i["ip_address"], "ip", 100 if i.get("status") == "online" else 50,
            first_seen=parse_ts(i.get("first_seen")), last_seen=parse_ts(i.get("last_online")),
            meta={"malware": i.get("malware"), "port": i.get("port"), "status": i.get("status"),
                  "as_number": i.get("as_number"), "country": i.get("country")},
        ))
    return out, 0, {}


def parse_urlhaus(text):
    header = ["id", "dateadded", "url", "url_status", "last_online", "threat", "tags", "urlhaus_link", "reporter"]
    rows = [l for l in text.splitlines() if l and not l.startswith("#")]
    out = []
    for r in csv.DictReader(io.StringIO("\n".join(rows)), fieldnames=header):
        out.append(entry(
            r["url"], "url", 100 if r.get("url_status") == "online" else 50,
            first_seen=parse_ts(r.get("dateadded")), last_seen=parse_ts(r.get("last_online")),
            meta={"threat": r.get("threat"), "tags": r.get("tags"), "status": r.get("url_status"), "id": r.get("id")},
        ))
    return out, 0, {}


PARSERS = {"kev": parse_kev, "epss": parse_epss, "threatfox": parse_threatfox, "feodo": parse_feodo, "urlhaus": parse_urlhaus}


def apply_expiry(entries, now):
    kept, dropped = [], 0
    for e in entries:
        days = EXPIRY_DAYS[e["type"]]
        if days is None:
            kept.append(e)
            continue
        seen = parse_ts(e.get("last_seen")) or parse_ts(e.get("first_seen"))
        if seen is None:
            kept.append(e)  # no date to age from; keep rather than guess
            continue
        expires = seen + timedelta(days=days)
        if expires <= now:
            dropped += 1
            continue
        e["expires_at"] = iso(expires)
        kept.append(e)
    return kept, dropped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feed", required=True, choices=sorted(PARSERS))
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--previous", help="yesterday's normalised file, for the drop check")
    ap.add_argument("--now", help="override fetched_at (ISO 8601 Z), for tests")
    args = ap.parse_args()

    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc).replace(microsecond=0)
    title = f"threat-feeds {args.feed}"
    try:
        entries, skipped, meta = PARSERS[args.feed](read_text(args.input))
    except Exception as exc:  # malformed upstream payload
        print(f"::error title={title}::cannot parse {args.input}: {exc}")
        return 1
    if not entries:
        print(f"::error title={title}::feed parsed to zero entries")
        return 1

    entries, dropped = apply_expiry(entries, now)
    env = {
        "feed": args.feed, "fetched_at": iso(now), "source_url": SOURCE_URLS[args.feed],
        "count": len(entries), "dropped_count": dropped, "skipped_count": skipped,
        "meta": meta, "entries": entries,
    }
    with open(args.output, "w") as f:
        json.dump(env, f, separators=(",", ":"))
        f.write("\n")

    line = f"{args.feed}: {len(entries)} entries ({dropped} expired, {skipped} skipped)"
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"| {args.feed} | {len(entries)} | {dropped} | {skipped} |\n")

    if args.previous:
        try:
            with open(args.previous) as f:
                prev = int(json.load(f).get("count", 0))
        except (OSError, ValueError) as exc:
            print(f"::warning title={title}::previous snapshot unreadable, drop check skipped: {exc}")
            prev = 0
        if prev and len(entries) < prev * MAX_DROP_RATIO:
            print(f"::error title={title}::entry count fell from {prev} to {len(entries)} (more than {int(MAX_DROP_RATIO * 100)} percent); upstream outage or format change")
            return 2
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
