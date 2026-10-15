#!/usr/bin/env python3
"""privado data-flow report: summary, baseline diff, PR comment (issue #99).

Usage: report.py --report .privado/privado.json [--baseline baseline/privado.json]
                 [--fail-on-new-sinks] [--comment comment.md] [--output report.json]

Reads privado's JSON (sources, dataFlow.{storages,leakages,third_parties,
internal_apis,miscellaneous}, collections), lists the data elements, where
they are stored, logged and sent, and the collection points. With a
baseline (the default branch's report) it lists what the PR adds: new
sources, new sinks per category, new third-party destinations. Writes the
job summary, a PR comment body and a JSON report; exit 1 with
--fail-on-new-sinks when a third-party sink or destination is new.
Standard library only.
"""

import argparse
import json
import os
import sys

CATEGORIES = ["third_parties", "storages", "leakages", "internal_apis", "miscellaneous"]
LABELS = {"third_parties": "Third parties", "storages": "Storages", "leakages": "Leakages (logs)",
          "internal_apis": "Internal APIs", "miscellaneous": "Other sinks"}


def load(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def rel(path):
    for prefix in ("/app/code/", "/app/"):
        if path.startswith(prefix):
            return path[len(prefix):]
    return path


def extract(data):
    """Sets that describe the map: sources, sinks per category, destinations, collection endpoints."""
    sources = {s["id"]: s.get("name", s["id"]) for s in data.get("sources", [])}
    sinks = {c: {} for c in CATEGORIES}
    flows = []
    for cat, entries in (data.get("dataFlow") or {}).items():
        if cat not in sinks:
            continue
        for entry in entries:
            src = entry.get("sourceId", "")
            for sink in entry.get("sinks", []):
                sid = sink.get("id", "")
                dests = [u.strip('"') for u in sink.get("apiUrl", [])] or list(sink.get("domains", []))
                d = sinks[cat].setdefault(sid, {"name": sink.get("name", sid), "destinations": set(), "sources": set(), "files": set()})
                d["destinations"].update(dests)
                d["sources"].add(src)
                for p in sink.get("paths", []):
                    for node in p.get("path", []):
                        if node.get("fileName"):
                            d["files"].add(f"{rel(node['fileName'])}:{node.get('lineNumber', '')}")
                flows.append((src, cat, sid))
    destinations = {dest for cat in ("third_parties",) for d in sinks[cat].values() for dest in d["destinations"]}
    endpoints = set()
    for coll in data.get("collections", []):
        for c in coll.get("collections", []):
            for occ in c.get("occurrences", []):
                if occ.get("endPoint"):
                    endpoints.add(occ["endPoint"])
            if c.get("endPoint"):
                endpoints.add(c["endPoint"])
    return {"sources": sources, "sinks": sinks, "destinations": destinations, "endpoints": endpoints, "flows": set(flows)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--baseline", default="")
    ap.add_argument("--fail-on-new-sinks", action="store_true")
    ap.add_argument("--comment", default="")
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    data = load(args.report)
    if data is None:
        print(f"::error title=pii-dataflow::no privado report at {args.report}")
        return 1
    cur = extract(data)
    base_data = load(args.baseline)
    base = extract(base_data) if base_data else None

    new = {"sources": set(), "destinations": set(), "sinks": {c: set() for c in CATEGORIES}, "flows": set()}
    if base:
        new["sources"] = set(cur["sources"]) - set(base["sources"])
        new["destinations"] = cur["destinations"] - base["destinations"]
        for c in CATEGORIES:
            new["sinks"][c] = set(cur["sinks"][c]) - set(base["sinks"][c])
        new["flows"] = cur["flows"] - base["flows"]
    new_third_party = bool(new["sinks"]["third_parties"] or new["destinations"])

    n_sinks = sum(len(v) for v in cur["sinks"].values())
    head = (f"## PII data flow: {len(cur['sources'])} data element(s), {n_sinks} sink(s), "
            f"{len(cur['destinations'])} third-party destination(s), {len(cur['endpoints'])} collection point(s)")
    lines = [head, ""]
    if base:
        lines += [f"Compared with the default-branch baseline: {len(new['sources'])} new data element(s), "
                  f"{sum(len(v) for v in new['sinks'].values())} new sink(s), {len(new['destinations'])} new third-party destination(s), "
                  f"{len(new['flows'])} new flow(s).", ""]
        if new_third_party:
            lines += ["**New third-party data flows** (review before merge" + ("; this fails the job" if args.fail_on_new_sinks else "") + "):", ""]
            for sid in sorted(new["sinks"]["third_parties"]):
                d = cur["sinks"]["third_parties"][sid]
                lines.append(f"- `{sid}` → {', '.join(sorted(d['destinations'])) or d['name']}; carries {', '.join(sorted(cur['sources'].get(s, s) for s in d['sources']))}; at {', '.join(sorted(d['files'])[:3])}")
            for dest in sorted(new["destinations"] - {x for sid in new["sinks"]["third_parties"] for x in cur["sinks"]["third_parties"][sid]["destinations"]}):
                lines.append(f"- new destination `{dest}` on an existing sink")
            lines.append("")
        if new["sources"]:
            lines += ["New data elements: " + ", ".join(f"`{cur['sources'][s]}`" for s in sorted(new["sources"])), ""]
    else:
        lines += ["No baseline (first run on this branch, or no default-branch artefact yet): everything below is reported, nothing is diffed.", ""]
    lines += ["| Data element | Stored | Logged | Shared with | Internal APIs |", "|---|---|---|---|---|"]
    for sid, name in sorted(cur["sources"].items(), key=lambda kv: kv[1]):
        def names(cat):
            items = sorted({(", ".join(sorted(d["destinations"])) or d["name"]) for k, d in cur["sinks"][cat].items() if sid in d["sources"]})
            return ", ".join(items) or "-"
        lines.append(f"| {name} | {names('storages')} | {names('leakages')} | {names('third_parties')} | {names('internal_apis')} |")
    for cat in CATEGORIES:
        if cur["sinks"][cat]:
            lines += ["", f"### {LABELS[cat]}", "", "| Sink | Destination | Data elements | Where |", "|---|---|---|---|"]
            for sid, d in sorted(cur["sinks"][cat].items()):
                mark = " **(new)**" if sid in new["sinks"][cat] else ""
                lines.append(f"| `{sid}`{mark} | {', '.join(sorted(d['destinations'])) or '-'} | {', '.join(sorted(cur['sources'].get(s, s) for s in d['sources']))} | {', '.join(sorted(d['files'])[:4]) or '-'} |")
    if cur["endpoints"]:
        lines += ["", "Collection points: " + ", ".join(f"`{e}`" for e in sorted(cur["endpoints"]))]
    lines += ["", f"privado core {data.get('privadoCoreVersion', '?')}; full report in the `privado-report` artefact. Flows feed the RoPA (#119) and the retention table (#120)."]
    text = "\n".join(lines) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    if args.comment:
        with open(args.comment, "w") as fh:
            fh.write("<!-- pii-dataflow -->\n" + text)
    if new_third_party:
        level = "error" if args.fail_on_new_sinks else "warning"
        for sid in sorted(new["sinks"]["third_parties"]):
            d = cur["sinks"]["third_parties"][sid]
            print(f"::{level} title=pii-dataflow::new third-party data flow {sid} to {', '.join(sorted(d['destinations'])) or d['name']}")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"source-count={len(cur['sources'])}\nsink-count={n_sinks}\nnew-third-party-count={len(new['sinks']['third_parties']) + len(new['destinations'])}\n")
    if args.output:
        out = {"sources": cur["sources"],
               "sinks": {c: {k: {"name": d["name"], "destinations": sorted(d["destinations"]), "sources": sorted(d["sources"]), "files": sorted(d["files"])}
                             for k, d in cur["sinks"][c].items()} for c in CATEGORIES},
               "destinations": sorted(cur["destinations"]), "endpoints": sorted(cur["endpoints"]),
               "new": {"sources": sorted(new["sources"]), "destinations": sorted(new["destinations"]),
                       "sinks": {c: sorted(v) for c, v in new["sinks"].items()}, "flows": sorted(new["flows"])},
               "baseline": bool(base)}
        with open(args.output, "w") as fh:
            json.dump(out, fh, indent=1)
            fh.write("\n")
    return 1 if (args.fail_on_new_sinks and new_third_party) else 0


if __name__ == "__main__":
    sys.exit(main())
