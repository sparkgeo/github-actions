#!/usr/bin/env python3
"""axe-core results to annotations, job summary and an HTML report (issue #70).

Usage: report.py --results results.json --html report.html [--fail-on-violations] [--output report.json]

results.json is the array `@axe-core/cli --save` writes: one entry per URL
with violations, passes, incomplete and inapplicable. Every violation node
becomes a PR annotation (error, or warning in report-only mode); the job
summary lists violations per URL by impact and rule; report.html is the
same table with the offending HTML and the fix summary. Exit 1 when
--fail-on-violations is set and any violation exists. Standard library only.
"""

import argparse
import html
import json
import os
import sys

IMPACTS = ["critical", "serious", "moderate", "minor"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--html", default="")
    ap.add_argument("--fail-on-violations", action="store_true")
    ap.add_argument("--output")
    args = ap.parse_args()

    with open(args.results) as fh:
        results = json.load(fh)
    if isinstance(results, dict):
        results = [results]

    level = "error" if args.fail_on_violations else "warning"
    rows, total, by_impact, urls = [], 0, {i: 0 for i in IMPACTS}, []
    for page in results:
        url = page.get("url", "")
        violations = page.get("violations", [])
        urls.append((url, len(violations), sum(len(v.get("nodes", [])) for v in violations), len(page.get("incomplete", []))))
        for v in violations:
            impact = v.get("impact") or "minor"
            nodes = v.get("nodes", [])
            total += 1
            by_impact[impact] = by_impact.get(impact, 0) + 1
            targets = [", ".join(str(t) for t in n.get("target", [])) for n in nodes]
            rows.append((url, impact, v.get("id", ""), v.get("help", ""), v.get("helpUrl", ""), len(nodes), nodes))
            print(f"::{level} title=a11y {v.get('id', '')} ({impact})::{url}: {v.get('help', '')}; {len(nodes)} element(s): {'; '.join(targets[:5])}")

    summary = [f"## Accessibility scan: {len(results)} page(s), {total} violation(s) "
               f"({', '.join(f'{by_impact[i]} {i}' for i in IMPACTS if by_impact[i])})" if total else
               f"## Accessibility scan: {len(results)} page(s), 0 violations", ""]
    summary += ["| Page | Violations | Elements | Incomplete |", "|---|---|---|---|"]
    summary += [f"| {u} | {n} | {e} | {inc} |" for u, n, e, inc in urls]
    if rows:
        summary += ["", "| Page | Impact | Rule | Elements | Fix |", "|---|---|---|---|---|"]
        summary += [f"| {u} | {i} | [`{rid}`]({link}) | {n} | {h} |" for u, i, rid, h, link, n, _ in
                    sorted(rows, key=lambda r: (IMPACTS.index(r[1]) if r[1] in IMPACTS else 9, r[0]))]
    if not args.fail_on_violations and total:
        summary += ["", "Report-only mode: violations do not fail the job. Set `fail-on-violations: true` to gate."]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)

    if args.html:
        parts = ["<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Accessibility report</title>",
                 "<style>body{font:14px system-ui;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.3rem .6rem;vertical-align:top}",
                 "code{white-space:pre-wrap}.critical{color:#b00}.serious{color:#c60}.moderate{color:#960}.minor{color:#666}</style></head><body>",
                 f"<h1>Accessibility report</h1><p>{len(results)} page(s), {total} violation(s).</p>"]
        for page in results:
            url = html.escape(page.get("url", ""))
            parts.append(f"<h2>{url}</h2><p>{len(page.get('violations', []))} violation(s), {len(page.get('passes', []))} rule(s) passed, "
                         f"{len(page.get('incomplete', []))} needing review.</p>")
            for v in page.get("violations", []):
                impact = html.escape(v.get("impact") or "minor")
                parts.append(f"<h3 class=\"{impact}\">{html.escape(v.get('id', ''))} ({impact}): {html.escape(v.get('help', ''))}</h3>"
                             f"<p>{html.escape(v.get('description', ''))} <a href=\"{html.escape(v.get('helpUrl', ''))}\">rule page</a></p>"
                             "<table><tr><th>Element</th><th>HTML</th><th>Fix</th></tr>")
                for n in v.get("nodes", []):
                    parts.append(f"<tr><td><code>{html.escape(', '.join(str(t) for t in n.get('target', [])))}</code></td>"
                                 f"<td><code>{html.escape(n.get('html', ''))}</code></td><td><code>{html.escape(n.get('failureSummary', ''))}</code></td></tr>")
                parts.append("</table>")
        parts.append("</body></html>")
        with open(args.html, "w") as fh:
            fh.write("\n".join(parts) + "\n")

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"violation-count={total}\npage-count={len(results)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"pages": [{"url": u, "violations": n, "elements": e, "incomplete": inc} for u, n, e, inc in urls],
                       "by_impact": by_impact, "total": total}, fh, indent=1)
            fh.write("\n")
    return 1 if args.fail_on_violations and total else 0


if __name__ == "__main__":
    sys.exit(main())
