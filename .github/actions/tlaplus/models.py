#!/usr/bin/env python3
"""Model checking support for the tlaplus and alloy composites (issue #130).

Usage:
  models.py select   --specs-dir DIR [--changed changed.txt] [--map verify-map.json] --output specs.txt
  models.py tlc      --log tlc.txt --spec X.tla --rc N --output tla-X.json
  models.py apalache --log apalache.txt --spec X.tla --rc N --output apalache-X.json
  models.py alloy    --receipt receipt.json --spec X.als --solutions DIR --output alloy-X.json
  models.py brief    --art DIR [--gate]

select: the specs to check. Without a changed list (push, schedule) every
.tla with a sibling .cfg and every .als under specs-dir; with one, the
changed .tla/.cfg/.als files plus the specs whose verify.yml `covers` code
changed (verify-map.json `stale_models`). A .tla without a sibling .cfg is
skipped, as in verify-brief.yml.
tlc: parses TLC output: the violated invariant or property, deadlock, the
error trace (state number, action, variables) and the state counts.
apalache: parses `apalache-mc check` output (NoError, a violation, or an
error such as a missing type annotation).
alloy: reads Alloy's receipt.json: a `check` with a solution is a
counterexample; a `run` without one is vacuous (the facts admit no
instance, so every check passes trivially). An `expect` clause overrides
both (`expect 1` on a check documents a known flaw, `expect 0` on a run an
intended impossibility). The counterexample's rendered instance is kept.
brief: merges tla-*.json, apalache-*.json, alloy-*.json and stale.json
into verify-brief.md and summary.json (tool "verify-models"; `tla` and
`alloy` are 0 or 1) and gates on any violation, vacuous run, error or time
out. Stdlib only.
"""

import argparse
import json
import os
import re
import sys


def glob_match(path, pattern):
    """Gitignore-style, as verify-map: ** spans directories."""
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


def lines(p):
    try:
        with open(p, encoding="utf-8", errors="ignore") as fh:
            return [l.strip() for l in fh if l.strip()]
    except OSError:
        return []


def select(a):
    root = a.specs_dir.rstrip("/")
    every = []
    for d, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.normpath(os.path.join(d, f))
            if f.endswith(".tla") and os.path.isfile(p[:-4] + ".cfg"):
                every.append(p)
            elif f.endswith(".als"):
                every.append(p)
    every.sort()
    stale = []
    if a.map and os.path.isfile(a.map):
        with open(a.map, encoding="utf-8") as fh:
            stale = json.load(fh).get("stale_models", [])
    if not a.changed:
        chosen = every
    else:
        changed = set(lines(a.changed))
        chosen = []
        for p in every:
            sib = p[:-4] + ".cfg" if p.endswith(".tla") else None
            hit = p in changed or (sib in changed) or any(p.endswith("/" + c) or c.endswith("/" + p) for c in changed)
            hit = hit or any(glob_match(p, s["model"]) or p.endswith("/" + s["model"]) for s in stale)
            if hit:
                chosen.append(p)
    with open(a.output, "w") as fh:
        fh.write("".join(c + "\n" for c in chosen))
    if a.stale_output:
        with open(a.stale_output, "w") as fh:
            json.dump(stale, fh, indent=1)
    print(f"  {len(chosen)} of {len(every)} spec(s) selected; {len(stale)} model(s) whose covered code changed")
    return 0


STATE = re.compile(r"^State (\d+): <(.*?)>\s*$")


def tlc(a):
    out = {"spec": a.spec, "rc": a.rc, "violation": None, "kind": None, "trace": [], "distinct": None, "generated": None,
           "completed": False, "timeout": a.rc == 124}
    cur = None
    in_trace = False
    for l in open(a.log, encoding="utf-8", errors="ignore").read().splitlines():
        m = re.match(r"^Error: Invariant (\S+) is violated", l)
        if m:
            out["violation"], out["kind"] = m.group(1), "invariant"
        m = re.match(r"^Error: (?:Temporal properties were violated|Action property (\S+) is violated)", l)
        if m:
            out["violation"], out["kind"] = m.group(1) or "temporal property", "property"
        if l.startswith("Error: Deadlock reached"):
            out["violation"], out["kind"] = "deadlock", "deadlock"
        if l.startswith("Error: The behavior up to this point is:") or l.startswith("Error: The following behavior constitutes a counter-example:"):
            in_trace = True
            continue
        m = STATE.match(l)
        if in_trace and m:
            act = m.group(2)
            act = "Initial predicate" if act.startswith("Initial") else act.split(" line ")[0]
            cur = {"n": int(m.group(1)), "action": act, "vars": {}}
            out["trace"].append(cur)
            continue
        if in_trace and cur is not None and l.startswith("/\\ ") and " = " in l:
            k, v = l[3:].split(" = ", 1)
            cur["vars"][k.strip()] = v.strip()
            continue
        if in_trace and cur is not None and l.strip() == "" :
            continue
        if re.search(r"Back to state|Stuttering", l) and in_trace:
            out["trace"].append({"n": len(out["trace"]) + 1, "action": l.strip().strip("<>"), "vars": {}})
            continue
        m = re.search(r"(\d+) states generated, (\d+) distinct states found", l)
        if m:
            out["generated"], out["distinct"] = int(m.group(1)), int(m.group(2))
            in_trace = False
        if l.startswith("Model checking completed."):
            out["completed"] = True
        if out["kind"] is None and a.rc not in (0, 124) and l.startswith("Error:") and "behavior" not in l:
            out["kind"], out["violation"] = "error", l[len("Error:"):].strip()[:300]
    if a.rc not in (0, 124) and out["kind"] is None:
        out["kind"], out["violation"] = "error", f"TLC exited {a.rc}"
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    what = ("time out" if out["timeout"] else f"{out['kind']} {out['violation']}" if out["kind"] else "no error")
    print(f"  {a.spec}: {what}; {out['distinct']} distinct state(s)")
    if out["kind"] or out["timeout"]:
        print(f"::error file={a.spec},title=TLC {out['kind'] or 'time out'}::{out['violation'] or 'model checking did not finish within the time limit'}")
    return 0


def apalache(a):
    txt = open(a.log, encoding="utf-8", errors="ignore").read()
    m = re.search(r"EXITCODE: (\w+)(?: \((\d+)\))?", txt)
    status = "NoError" if "The outcome is: NoError" in txt else None
    viol = re.search(r"State \d+: (?:state invariant|action invariant|trace invariant) \d+ violated", txt) or re.search(r"(?:Invariant|invariant) (\S+) violated", txt)
    err = re.search(r"^.*(?:type input error|Error|error):\s*(.*)$", txt, re.M)
    length = re.search(r"up to computation length (\d+)", txt)
    out = {"spec": a.spec, "rc": a.rc, "outcome": status or ("violation" if viol else "error" if a.rc else "unknown"),
           "detail": (viol.group(0) if viol else (err.group(0).strip() if err and a.rc else ""))[:300],
           "length": int(length.group(1)) if length else None, "exitcode": m.group(0) if m else None}
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"  {a.spec} (apalache): {out['outcome']} {out['detail']}")
    if out["outcome"] in ("violation", "error"):
        print(f"::error file={a.spec},title=Apalache {out['outcome']}::{out['detail'] or out['exitcode']}")
    return 0


def alloy(a):
    with open(a.receipt, encoding="utf-8") as fh:
        r = json.load(fh)
    cmds = []
    for name, c in r.get("commands", {}).items():
        found = bool(c.get("solution")) and any(s.get("instances") for s in c["solution"])
        expects = c.get("expects", -1)
        if c.get("type") == "check":
            bad = (found and expects != 1) or (not found and expects == 1)
            verdict = "counterexample" if found else "holds within scope"
        else:
            bad = (not found and expects != 0) or (found and expects == 0)
            verdict = "instance found" if found else "no instance (vacuous)"
        inst = ""
        if found:
            p = os.path.join(a.solutions, f"{name}-solution-0.md")
            if os.path.isfile(p):
                inst = "\n".join(open(p, encoding="utf-8", errors="ignore").read().splitlines()[:60])
        cmds.append({"name": name, "type": c.get("type"), "source": c.get("source"), "scope": c.get("overall"),
                     "expects": expects, "verdict": verdict, "failed": bad, "instance": inst})
    out = {"spec": a.spec, "commands": cmds}
    with open(a.output, "w") as fh:
        json.dump(out, fh, indent=1)
    for c in cmds:
        print(f"  {a.spec} {c['type']} {c['name']}: {c['verdict']}" + (" (FAIL)" if c["failed"] else ""))
        if c["failed"]:
            print(f"::error file={a.spec},title=Alloy {c['verdict']}::{c['source']}")
    return 0


def trace_table(trace):
    rows, prev = [], {}
    for s in trace[:40]:
        diff = {k: v for k, v in s["vars"].items() if prev.get(k) != v}
        prev = {**prev, **s["vars"]}
        cells = "<br>".join(f"`{k} = {v[:80]}`" for k, v in diff.items()) or "(unchanged)"
        rows.append(f"| {s['n']} | {s['action']} | {cells} |")
    return ["| State | Action | Changed variables |", "|---|---|---|"] + rows


def brief(a):
    art = a.art
    def load(prefix):
        res = []
        for f in sorted(os.listdir(art)):
            if f.startswith(prefix) and f.endswith(".json"):
                with open(os.path.join(art, f)) as fh:
                    res.append(json.load(fh))
        return res
    tla, ap, al = load("tla-"), load("apalache-"), load("alloy-")
    stale = []
    if os.path.isfile(f"{art}/stale.json"):
        with open(f"{art}/stale.json") as fh:
            stale = json.load(fh)
    M = ["## Verification brief (models)", ""]
    if not (tla or ap or al):
        M += ["No TLA+ or Alloy spec in scope.", ""]
    if tla:
        M += ["### TLA+ (TLC)", "", "| Spec | Result | Distinct states |", "|---|---|---|"]
        M += [f"| `{t['spec']}` | " + ("**time out**" if t["timeout"] else f"**{t['kind']}: {t['violation']}**" if t["kind"] else "invariants hold")
              + f" | {t['distinct'] if t['distinct'] is not None else '-'} |" for t in tla]
        M += [""]
        for t in tla:
            if t["trace"]:
                M += [f"<details><summary>Counterexample for <code>{t['violation']}</code> in <code>{t['spec']}</code> ({len(t['trace'])} states)</summary>", ""]
                M += trace_table(t["trace"]) + ["", "</details>", ""]
    if ap:
        M += ["### TLA+ (Apalache)", "", "| Spec | Outcome | Detail |", "|---|---|---|"]
        M += [f"| `{x['spec']}` | {x['outcome']}" + (f" (length {x['length']})" if x["length"] else "") + f" | {x['detail'][:140]} |" for x in ap]
        M += [""]
    if al:
        M += ["### Alloy", "", "| Spec | Command | Scope | Result |", "|---|---|---|---|"]
        M += [f"| `{x['spec']}` | `{c['source']}` | {c['scope']} | " + (f"**{c['verdict']}**" if c["failed"] else c["verdict"]) + " |"
              for x in al for c in x["commands"]]
        M += [""]
        for x in al:
            for c in x["commands"]:
                if c["failed"] and c["instance"]:
                    M += [f"<details><summary>{c['verdict']}: <code>{c['name']}</code></summary>", "", "```text", c["instance"], "```", "", "</details>", ""]
    if stale:
        M += ["> **Model drift review.** Code a model covers changed but the model did not: "
              + "; ".join(f"`{s['model']}` covers {', '.join(f'`{c}`' for c in s['code'][:3])}" for s in stale)
              + ". Confirm the model still describes the implementation, or update it in this PR.", ""]
    M += ["> TLC and Alloy check the model within its bounds, not the implementation. A model that holds says the "
          "design is right; the review checklist in docs/verification.md says whether the code follows it.", "",
          "Rungs and verdicts: docs/verification.md."]
    with open(f"{art}/verify-brief.md", "w", encoding="utf-8") as fh:
        fh.write("\n".join(M) + "\n")
    fail, warn = [], []
    for t in tla:
        if t["timeout"]:
            fail.append(f"TLC did not finish {t['spec']} within the time limit")
        elif t["kind"]:
            fail.append(f"TLC {t['kind']} in {t['spec']}: {t['violation']}")
    for x in ap:
        if x["outcome"] in ("violation", "error"):
            fail.append(f"Apalache {x['outcome']} in {x['spec']}")
    for x in al:
        for c in x["commands"]:
            if c["failed"]:
                fail.append(f"Alloy {c['verdict']} in {x['spec']}: {c['source']}")
    if stale:
        warn.append(f"{len(stale)} model(s) whose covered code changed without them")
    summary = {"tla": None if not tla else int(any(t["kind"] or t["timeout"] for t in tla)),
               "alloy": None if not al else int(any(c["failed"] for x in al for c in x["commands"])),
               "apalache": None if not ap else int(any(x["outcome"] in ("violation", "error") for x in ap)),
               "counterexamples": sum(1 for t in tla if t["kind"] in ("invariant", "property")) + sum(1 for x in al for c in x["commands"] if c["failed"] and c["type"] == "check"),
               "unverified": sum(1 for t in tla if t["timeout"]), "bare_high_risk": 0, "strict": True,
               "tool": "verify-models", "stale_models": len(stale), "gate": {"fail": fail, "warn": warn}}
    with open(f"{art}/summary.json", "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"tla={'' if summary['tla'] is None else summary['tla']}\nalloy={'' if summary['alloy'] is None else summary['alloy']}\n"
                     f"counterexamples={summary['counterexamples']}\nblocking={len(fail)}\n")
    for w in warn:
        print(f"  warn: {w}")
        print(f"::warning title=verify-models::{w}")
    for f in fail:
        print(f"  FAIL: {f}")
    print(f"\n{len(fail)} blocking, {len(warn)} advisory")
    return 1 if (a.gate and fail) else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select"); s.add_argument("--specs-dir", required=True); s.add_argument("--changed", default="")
    s.add_argument("--map", default=""); s.add_argument("--output", required=True); s.add_argument("--stale-output", default="")
    for name in ("tlc", "apalache"):
        p = sub.add_parser(name); p.add_argument("--log", required=True); p.add_argument("--spec", required=True)
        p.add_argument("--rc", type=int, required=True); p.add_argument("--output", required=True)
    p = sub.add_parser("alloy"); p.add_argument("--receipt", required=True); p.add_argument("--spec", required=True)
    p.add_argument("--solutions", required=True); p.add_argument("--output", required=True)
    b = sub.add_parser("brief"); b.add_argument("--art", required=True); b.add_argument("--gate", action="store_true")
    a = ap.parse_args()
    return {"select": select, "tlc": tlc, "apalache": apalache, "alloy": alloy, "brief": brief}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
