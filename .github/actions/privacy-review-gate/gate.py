#!/usr/bin/env python3
"""Privacy review gate (issue #121, plan Step 36 Standard).

Usage: gate.py --pr pr.json --reviews reviews.json --changed changed.txt
               [--members members.json | --reviewers login,login] [--privado report.json]
               [--privacy-paths GLOB,GLOB] [--ropa ropa.yml] [--pia-link-pattern REGEX]
               [--pia-heading "## Privacy impact"] [--label privacy-review] [--head-sha SHA]
               [--comment comment.md] [--output report.json]

Decides whether the PR needs privacy review (a changed path matches the
privacy paths or names a store from ropa.yml, the privado report lists a new
source, sink or destination, or the PR body's PIA section is filled in) and,
when it does, whether the review is complete: the label is present, a
privacy owner's latest review on the current head is an approval, and the
body carries a PIA link. Exit 1 when triggered and incomplete. Values from
the PR body are never echoed beyond the matched link. Standard library only.
"""

import argparse
import json
import os
import re
import sys

DEFAULT_PATHS = "ropa.yml,retention.yml,**/migrations/**,**/models/**,**/schemas/**,**/schema/**,**/*.sql"


def glob_match(path, pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if pattern.startswith("**", i):
            out += ".*"; i += 2; continue
        c = pattern[i]
        out += "[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c)
        i += 1
    return re.fullmatch(out, path) is not None


def load(path, default=None):
    if not path or not os.path.exists(path):
        return default
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def ropa_stores(path):
    """Store ids under any `stores:` key of ropa.yml, without a YAML parser."""
    if not path or not os.path.exists(path):
        return set()
    ids, in_block = set(), False
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        m = re.match(r"stores:\s*\[(.*)\]", s)
        if m:
            ids.update(x.strip().strip("'\"") for x in m.group(1).split(",") if x.strip())
            in_block = False
            continue
        if re.match(r"stores:\s*$", s):
            in_block = True
            continue
        if in_block:
            m = re.match(r"-\s*(['\"]?)([^'\"#]+)\1", s)
            if m:
                ids.add(m.group(2).strip())
            else:
                in_block = False
    return {i for i in ids if i}


def section(body, heading):
    """Text under a markdown heading until the next heading of the same or higher level."""
    level = len(heading) - len(heading.lstrip("#"))
    lines, out, on = body.splitlines(), [], False
    for ln in lines:
        if ln.strip().lower() == heading.strip().lower():
            on = True
            continue
        if on and re.match(r"^#{1,%d}\s" % level, ln):
            break
        if on:
            out.append(ln)
    return "\n".join(out).strip()


def filled(text):
    t = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    t = re.sub(r"\[[ xX]\]", "", t)
    t = re.sub(r"(?i)\b(n/?a|none|no personal data|not applicable|tbd)\b\.?", "", t)
    return len(re.sub(r"[\s|\-:*_>]+", "", t)) >= 20


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pr", required=True)
    ap.add_argument("--reviews", required=True)
    ap.add_argument("--changed", required=True)
    ap.add_argument("--members", default="")
    ap.add_argument("--reviewers", default="")
    ap.add_argument("--privado", default="")
    ap.add_argument("--privacy-paths", default="")
    ap.add_argument("--ropa", default="ropa.yml")
    ap.add_argument("--pia-link-pattern", default=r"docs/pia/")
    ap.add_argument("--pia-heading", default="## Privacy impact")
    ap.add_argument("--label", default="privacy-review")
    ap.add_argument("--head-sha", default="")
    ap.add_argument("--owner", default="")
    ap.add_argument("--comment", default="")
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    pr = load(args.pr, {}) or {}
    body = pr.get("body") or ""
    labels = {(l.get("name") if isinstance(l, dict) else l) for l in pr.get("labels", [])}
    head = args.head_sha or (pr.get("head") or {}).get("sha", "")
    with open(args.changed, encoding="utf-8") as fh:
        changed = [ln.strip() for ln in fh if ln.strip()]

    # 1. triggers
    paths = [p.strip() for p in (args.privacy_paths or DEFAULT_PATHS).split(",") if p.strip()]
    stores = ropa_stores(args.ropa)
    hits = {}
    for f in changed:
        for p in paths:
            if glob_match(f, p):
                hits[f] = f"matches {p}"
                break
        else:
            if stores and f.endswith((".tf", ".tofu", ".json", ".ts", ".py", ".yaml", ".yml")) and os.path.exists(f):
                try:
                    text = open(f, encoding="utf-8", errors="ignore").read()
                except OSError:
                    text = ""
                named = [s for s in stores if s in text or s.split(".", 1)[-1] in text and s.split(".", 1)[0] in text]
                if named:
                    hits[f] = f"defines store {', '.join(sorted(named)[:3])} from ropa.yml"
    report = load(args.privado, None)
    new = (report or {}).get("new", {}) if report else {}
    privado_new = []
    if report:
        privado_new += [f"data element {x}" for x in new.get("sources", [])]
        privado_new += [f"third-party destination {x}" for x in new.get("destinations", [])]
        privado_new += [f"{cat.replace('_', ' ')} sink {x}" for cat, items in (new.get("sinks") or {}).items() for x in items]
    pia_text = section(body, args.pia_heading)
    self_declared = filled(pia_text)
    triggers = []
    if hits:
        triggers.append(f"{len(hits)} changed path(s) touch personal-data definitions")
    if privado_new:
        triggers.append(f"privado reports {len(privado_new)} new data flow item(s)")
    if self_declared:
        triggers.append(f"the PR body's {args.pia_heading.lstrip('# ')} section is filled in")
    triggered = bool(triggers)

    # 2. gate
    reviewers = set()
    members = load(args.members, None)
    if members is not None:
        reviewers = {m.get("login") for m in members if isinstance(m, dict) and m.get("login")}
    reviewers |= {r.strip() for r in args.reviewers.split(",") if r.strip()}
    latest = {}
    for r in sorted(load(args.reviews, []) or [], key=lambda r: r.get("submitted_at", "")):
        if r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest[(r.get("user") or {}).get("login")] = r
    approvals = [u for u, r in latest.items() if r.get("state") == "APPROVED" and u in reviewers and (not head or r.get("commit_id") == head)]
    stale = [u for u, r in latest.items() if r.get("state") == "APPROVED" and u in reviewers and head and r.get("commit_id") != head]
    link = re.search(args.pia_link_pattern + r"\S*", body)
    missing = []
    if triggered:
        if args.label not in labels:
            missing.append(f"label `{args.label}`")
        if not reviewers:
            missing.append(f"a privacy reviewer list: the token cannot read the team `{args.owner or 'privacy-owner'}` (give `privacy-reviewers` or a token with members:read)")
        elif not approvals:
            missing.append(f"an approving review on the current head from a member of `{args.owner or 'privacy-owner'}`"
                           + (f" (approval by {', '.join(stale)} is for an earlier commit)" if stale else ""))
        if not link:
            missing.append(f"a PIA link in the PR body matching `{args.pia_link_pattern}`")
    ok = not triggered or not missing

    lines = [f"## Privacy review gate: {'not required' if not triggered else ('complete' if ok else 'incomplete')}", ""]
    if triggered:
        lines += ["Triggered by:", ""] + [f"- {t}" for t in triggers]
        if hits:
            lines += [""] + [f"  - `{f}`: {why}" for f, why in sorted(hits.items())[:20]]
        if privado_new:
            lines += [""] + [f"  - {x}" for x in privado_new[:20]]
        lines += ["", "Required:", "",
                  f"- {'✅' if args.label in labels else '❌'} label `{args.label}`",
                  f"- {'✅' if approvals else '❌'} approving review on the current head from `{args.owner or 'the privacy owner'}`" + (f" ({', '.join(approvals)})" if approvals else ""),
                  f"- {'✅' if link else '❌'} PIA link in the PR body (`{args.pia_link_pattern}`)" + (f": `{link.group(0)}`" if link else "")]
        if missing:
            lines += ["", "Missing: " + "; ".join(missing) + ".", "",
                      "Fill in `docs/pia-template.md` (copy it to `docs/pia/<activity>.md`), link it from the PR body, add the label and request the privacy owner's review; the check re-runs on each review."]
    else:
        lines += ["No changed path touches personal-data definitions, the data-flow report adds nothing, and the PIA section is empty."]
    text = "\n".join(lines) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    if args.comment:
        with open(args.comment, "w") as fh:
            fh.write("<!-- privacy-review-gate -->\n" + text)
    if triggered and missing:
        print(f"::error title=privacy-review::privacy review incomplete: {'; '.join(missing)}")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"triggered={str(triggered).lower()}\ncomplete={str(ok).lower()}\nmissing-count={len(missing)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"triggered": triggered, "triggers": triggers, "hits": hits, "privado_new": privado_new, "self_declared": self_declared,
                       "approvals": approvals, "stale": stale, "link": link.group(0) if link else None, "missing": missing, "ok": ok}, fh, indent=1)
            fh.write("\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
