#!/usr/bin/env python3
"""Time-boxed fuzz driver for atheris, go test -fuzz and cargo-fuzz (issue #76).

Usage: fuzz.py --runtime python|go|rust --targets T[,T...] --duration 10m
                --crash-dir DIR [--corpus-dir testdata/fuzz] [--python python3]
                [--output report.json]

Targets: python = path to an atheris script (its corpus lives in
<corpus-dir>/<script stem>/); go = "<package dir>:<FuzzFunc>" ("." when no
package is given; the corpus is Go's own testdata/fuzz/<FuzzFunc>/ and the
build cache); rust = cargo-fuzz target name (corpus fuzz/corpus/<target>/).
Each target runs for the duration; a crash input found is copied into
<crash-dir>/<target>/ and listed in the summary and report. Exit 1 when any
target crashed or failed to run. Standard library only.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

UNITS = {"s": 1, "m": 60, "h": 3600}


def seconds(text):
    m = re.fullmatch(r"(\d+)([smh]?)", text.strip())
    if not m:
        raise SystemExit(f"duration must look like 30s, 10m or 1h, got {text!r}")
    return int(m.group(1)) * UNITS[m.group(2) or "s"]


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def run(cmd, timeout, cwd=None, env=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or b"").decode(errors="replace") + (e.stderr or b"").decode(errors="replace") + "\n(timed out)"


def tail(text, n=15):
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines[-n:])


def fuzz_python(target, secs, corpus_dir, crash_dir, python):
    stem = os.path.splitext(os.path.basename(target))[0]
    corpus = os.path.join(corpus_dir, stem)
    os.makedirs(corpus, exist_ok=True)
    os.makedirs(crash_dir, exist_ok=True)
    cmd = [python, target, corpus, f"-max_total_time={secs}", f"-artifact_prefix={crash_dir}/", "-timeout=30", "-print_final_stats=1"]
    rc, out = run(cmd, secs + 180)
    crashes = sorted(f for f in os.listdir(crash_dir) if f.startswith(("crash-", "timeout-", "oom-", "leak-")))
    return rc, out, [os.path.join(crash_dir, f) for f in crashes]


def fuzz_go(target, secs, crash_dir):
    pkg, _, func = target.rpartition(":")
    pkg = pkg or "."
    os.makedirs(crash_dir, exist_ok=True)
    cmd = ["go", "test", "-run", "^$", "-fuzz", f"^{func}$", f"-fuzztime={secs}s", pkg]
    rc, out = run(cmd, secs + 600)
    crashes = []
    # a new crasher ("Failing input written to ...") or a committed corpus entry
    # that fails on replay ("failure while testing seed corpus entry: FuzzX/<name>")
    sources = [m.group(1) for m in re.finditer(r"Failing input written to (\S+)", out)]
    sources += [os.path.join("testdata", "fuzz", m.group(1), m.group(2))
                for m in re.finditer(r"failure while testing seed corpus entry: (Fuzz\w+)/(\S+)", out)]
    for rel in sources:
        src = rel if os.path.isabs(rel) else os.path.join(pkg, rel)
        dst = os.path.join(crash_dir, os.path.basename(src))
        if os.path.exists(src) and dst not in crashes:
            shutil.copyfile(src, dst)
            crashes.append(dst)
    return rc, out, crashes


def fuzz_rust(target, secs, crash_dir):
    os.makedirs(crash_dir, exist_ok=True)
    cmd = ["cargo", "+nightly", "fuzz", "run", target, "--", f"-max_total_time={secs}", "-timeout=30"]
    rc, out = run(cmd, secs + 1800)
    art = os.path.join("fuzz", "artifacts", target)
    crashes = []
    if os.path.isdir(art):
        for f in sorted(os.listdir(art)):
            if f.startswith(("crash-", "timeout-", "oom-", "leak-")):
                dst = os.path.join(crash_dir, f)
                shutil.copyfile(os.path.join(art, f), dst)
                crashes.append(dst)
    return rc, out, crashes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime", required=True, choices=["python", "go", "rust"])
    ap.add_argument("--targets", required=True)
    ap.add_argument("--duration", default="10m")
    ap.add_argument("--crash-dir", required=True)
    ap.add_argument("--corpus-dir", default="testdata/fuzz")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--output")
    args = ap.parse_args()
    secs = seconds(args.duration)
    targets = [t.strip() for t in args.targets.split(",") if t.strip()]
    if not targets:
        raise SystemExit("no targets given")

    results = []
    for target in targets:
        name = re.sub(r"[^A-Za-z0-9_.-]+", "_", target.removeprefix("./")).strip("._")
        crash_dir = os.path.join(args.crash_dir, name)
        print(f"== {args.runtime} {target}: {secs}s")
        if args.runtime == "python":
            rc, out, crashes = fuzz_python(target, secs, args.corpus_dir, crash_dir, args.python)
        elif args.runtime == "go":
            rc, out, crashes = fuzz_go(target, secs, crash_dir)
        else:
            rc, out, crashes = fuzz_rust(target, secs, crash_dir)
        print(tail(out, 25))
        status = "crash" if crashes else ("error" if rc != 0 else "ok")
        last = tail(out, 1)
        for c in crashes:
            print(f"::error title=fuzz {target}::crash input {os.path.basename(c)} (sha256 {sha256(c)[:12]}); {last}")
        if status == "error":
            print(f"::error title=fuzz {target}::target did not run cleanly (exit {rc}); see the log")
        results.append({"target": target, "status": status, "exit": rc,
                        "crashes": [{"file": c, "sha256": sha256(c)} for c in crashes], "log_tail": tail(out, 15)})

    n_crash = sum(len(r["crashes"]) for r in results)
    n_bad = sum(1 for r in results if r["status"] != "ok")
    summary = [f"## Fuzz ({args.runtime}): {len(results)} target(s) x {args.duration}, {n_crash} crash input(s), "
               f"{sum(1 for r in results if r['status'] == 'crash')} crashing target(s)", "",
               "| Target | Result | Crash inputs |", "|---|---|---|"]
    for r in results:
        files = ", ".join(f"`{os.path.basename(c['file'])}`" for c in r["crashes"]) or "none"
        summary.append(f"| `{r['target']}` | {r['status']} | {files} |")
    for r in results:
        if r["status"] != "ok":
            summary += ["", f"### {r['target']}", "", "```", r["log_tail"], "```"]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"crash-count={n_crash}\ncrashing-targets={','.join(r['target'] for r in results if r['status'] == 'crash')}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"runtime": args.runtime, "duration": args.duration, "results": results}, fh, indent=1)
            fh.write("\n")
    return 1 if n_bad else 0


if __name__ == "__main__":
    sys.exit(main())
