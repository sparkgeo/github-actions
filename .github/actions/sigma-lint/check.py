#!/usr/bin/env python3
"""Sigma rule lint, test-case check and SIEM conversion (issue #177).

Usage: check.py --rules-dir DIR --tests-dir DIR [--require-test-case]
                [--junit check.xml] [--backend splunk --pipeline NAME_OR_FILE --output-dir DIR]
                [--sigma CMD] [--stale-days 365] [--output report.json]

Runs in the virtualenv that holds sigma-cli, so PyYAML is available.

1. Every *.yml under --rules-dir is parsed; a rule needs an `id`.
2. Rule errors from `sigma check --junitxml` (--junit) are errors;
   validation issues are warnings.
3. Test case: <tests-dir>/<rule id>.yml with `technique` (ATT&CK id),
   `source` (atomic:<guid>, stratus:<technique id> or manual, which needs
   `steps`) and `expect` (detected|prevented). A missing or malformed test
   case is an error with --require-test-case, a warning otherwise. A test
   case with no rule is a warning (orphan).
4. With --backend, each rule is converted on its own (`sigma convert`) into
   --output-dir/<stem>.txt; a failed conversion is an error.
5. Job summary: rule count, rules without a test case, conversion failures,
   rules per logsource product, rules whose `modified` (or `date`) is older
   than --stale-days.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

import yaml

TECHNIQUE = re.compile(r"^T\d{4}(\.\d{3})?$")
SOURCE = re.compile(r"^(atomic:[0-9a-fA-F-]{36}|stratus:[a-z0-9.-]+|manual)$")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def rule_date(rule):
    for key in ("modified", "date"):
        v = rule.get(key)
        if isinstance(v, datetime.date):
            return v
        if isinstance(v, str):
            for fmt in ("%Y-%m-%d", "%Y/%m/%d"):
                try:
                    return datetime.datetime.strptime(v, fmt).date()
                except ValueError:
                    pass
    return None


def check_test_case(path, errors_out):
    """Append messages for a malformed test case; return True when well formed."""
    try:
        tc = load(path)
    except yaml.YAMLError as e:
        errors_out.append(f"{path}: not valid YAML: {str(e).splitlines()[0]}")
        return False
    if not isinstance(tc, dict):
        errors_out.append(f"{path}: must be a mapping with technique, source and expect")
        return False
    ok = True
    if not TECHNIQUE.match(str(tc.get("technique", ""))):
        errors_out.append(f"{path}: \"technique\" must be an ATT&CK id such as T1078.004, got \"{tc.get('technique', '')}\"")
        ok = False
    if not SOURCE.match(str(tc.get("source", ""))):
        errors_out.append(f"{path}: \"source\" must be atomic:<test guid>, stratus:<technique id> or manual, got \"{tc.get('source', '')}\"")
        ok = False
    elif tc.get("source") == "manual" and not str(tc.get("steps", "")).strip():
        errors_out.append(f"{path}: a manual source needs \"steps\"")
        ok = False
    if tc.get("expect") not in ("detected", "prevented"):
        errors_out.append(f"{path}: \"expect\" must be detected or prevented, got \"{tc.get('expect', '')}\"")
        ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules-dir", default="detections/rules")
    ap.add_argument("--tests-dir", default="detections/tests")
    ap.add_argument("--require-test-case", action="store_true")
    ap.add_argument("--junit", default="")
    ap.add_argument("--backend", default="none")
    ap.add_argument("--pipeline", default="")
    ap.add_argument("--output-dir", default="")
    ap.add_argument("--sigma", default="sigma")
    ap.add_argument("--stale-days", type=int, default=365)
    ap.add_argument("--output")
    args = ap.parse_args()

    errors, warnings, rules = [], [], {}
    if not os.path.isdir(args.rules_dir):
        errors.append(f"rules directory {args.rules_dir} does not exist")
    for dirpath, _, files in sorted(os.walk(args.rules_dir)):
        for f in sorted(files):
            if not f.endswith((".yml", ".yaml")):
                continue
            path = os.path.join(dirpath, f).replace(os.sep, "/")
            try:
                rule = load(path)
            except yaml.YAMLError as e:
                errors.append(f"{path}: not valid YAML: {str(e).splitlines()[0]}")
                continue
            if not isinstance(rule, dict):
                errors.append(f"{path}: not a Sigma rule mapping")
                continue
            rules[path] = rule
            if not rule.get("id"):
                errors.append(f"{path}: rule has no id; a test case is keyed by it")

    # sigma check results; a rule with a rule error is fixed first, so it skips the test-case check
    broken = set()
    if args.junit and os.path.exists(args.junit):
        for case in ET.parse(args.junit).getroot().iter("testcase"):
            kind = case.get("classname", "")
            file = os.path.relpath(case.get("file", ""), os.getcwd()).replace(os.sep, "/") if case.get("file") else ""
            for failure in case.iter("failure"):
                msg = (failure.text or "").strip().replace(case.get("file", ""), file)
                level = failure.get("message", "").rsplit(":", 1)[-1].strip().upper()
                if kind.endswith("Error") or level == "ERROR":
                    errors.append(f"{file}: {kind}: {msg}")
                    broken.add(file)
                else:
                    warnings.append(f"{file}: {kind} ({level.lower()}): {msg}")

    # test cases
    missing, covered = [], {}
    for path, rule in rules.items():
        rid = str(rule.get("id") or "")
        if not rid or path in broken:
            continue
        tc_path = os.path.join(args.tests_dir, f"{rid}.yml").replace(os.sep, "/")
        if not os.path.exists(tc_path):
            missing.append(path)
            (errors if args.require_test_case else warnings).append(f"{path}: no test case {tc_path} (technique, source, expect)")
            continue
        msgs = []
        if check_test_case(tc_path, msgs):
            covered[path] = load(tc_path)
        else:
            missing.append(path)
            (errors if args.require_test_case else warnings).extend(msgs)
    ids = {str(r.get("id")) for r in rules.values() if r.get("id")}
    if os.path.isdir(args.tests_dir):
        for f in sorted(os.listdir(args.tests_dir)):
            if f.endswith(".yml") and f[:-4] not in ids:
                warnings.append(f"{args.tests_dir}/{f}: test case for no rule (orphan)")

    # conversion
    converted, failed = [], []
    if args.backend and args.backend != "none" and rules:
        os.makedirs(args.output_dir or "converted", exist_ok=True)
        for path in rules:
            out = os.path.join(args.output_dir or "converted", os.path.splitext(os.path.basename(path))[0] + ".txt")
            cmd = args.sigma.split() + ["convert", "-t", args.backend, "--skip-unsupported", "-o", out]
            cmd += ["-p", args.pipeline] if args.pipeline else ["--without-pipeline"]
            p = subprocess.run(cmd + [path], capture_output=True, text=True)
            if p.returncode == 0:
                converted.append(path)
            else:
                failed.append(path)
                tail = [ln for ln in (p.stdout + p.stderr).splitlines() if ln.strip() and ln != "Parsing Sigma rules"]
                errors.append(f"{path}: conversion to {args.backend} failed: {tail[-1] if tail else f'exit {p.returncode}'}")
                if os.path.exists(out):
                    os.remove(out)

    # stale rules and product counts
    today = datetime.date.today()
    stale = []
    products = {}
    for path, rule in rules.items():
        d = rule_date(rule)
        if d and (today - d).days > args.stale_days:
            stale.append((path, d.isoformat()))
        product = str((rule.get("logsource") or {}).get("product") or "unknown")
        products[product] = products.get(product, 0) + 1
    for path, d in stale:
        warnings.append(f"{path}: last modified {d}, older than {args.stale_days} days (stale?)")

    for e in errors:
        m = re.match(r"^([^:\s]+\.ya?ml): ", e)
        print(f"::error {'file=' + m.group(1) + ',' if m else ''}title=sigma-lint::{e}")
    for w in warnings:
        m = re.match(r"^([^:\s]+\.ya?ml): ", w)
        print(f"::warning {'file=' + m.group(1) + ',' if m else ''}title=sigma-lint::{w}")

    summary = [f"## Sigma lint: {len(rules)} rule(s), {len(missing)} without a test case, "
               f"{len(failed)} conversion failure(s), {len(stale)} stale, {len(errors)} error(s), {len(warnings)} warning(s)", ""]
    if products:
        summary += ["| Logsource product | Rules |", "|---|---|"] + [f"| {p} | {n} |" for p, n in sorted(products.items())]
    if args.backend and args.backend != "none":
        summary += ["", f"Converted to `{args.backend}`" + (f" with pipeline `{args.pipeline}`" if args.pipeline else "") + f": {len(converted)} of {len(rules)}."]
    if missing:
        summary += ["", "### Rules without a valid test case", ""] + [f"- `{p}`" for p in missing]
    if stale:
        summary += ["", "### Stale rules", ""] + [f"- `{p}` (modified {d})" for p, d in stale]
    if errors:
        summary += ["", "### Errors", ""] + [f"- {e}" for e in errors]
    if warnings:
        summary += ["", "### Warnings", ""] + [f"- {w}" for w in warnings]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"rule-count={len(rules)}\nmissing-test-count={len(missing)}\nerror-count={len(errors)}\nconverted-count={len(converted)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"rules": sorted(rules), "missing": missing, "covered": {p: tc.get("source") for p, tc in covered.items()},
                       "converted": converted, "failed": failed, "stale": stale, "products": products,
                       "errors": errors, "warnings": warnings}, fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
