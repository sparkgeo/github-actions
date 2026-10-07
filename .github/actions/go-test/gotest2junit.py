#!/usr/bin/env python3
"""Convert `go test -json` (test2json) output to JUnit XML.

Usage: gotest2junit.py <gotest.json> <junit.xml>
Env: MODULE_PATH (from `go list -m`) and optional FILE_PREFIX (the
working directory relative to the repository root) so each test case gets
a repository-relative `file` and a `line` from the first `name_test.go:N:`
line in its output. Stdlib only; run with -I.

One <testcase> per (package, test), classname = import path. Subtests keep
their full "Parent/Child" name. A package-level failure with no failing
test (build error, panic outside a test) becomes a synthetic case so it is
never silently dropped.
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

LOC = re.compile(r"^\s*([\w./-]+_test\.go):(\d+): ?(.*)$")


def main(src, dst) -> int:
    module = os.environ.get("MODULE_PATH", "").rstrip("/")
    prefix = os.environ.get("FILE_PREFIX", "").strip("/")
    cases = {}   # (pkg, test) -> dict
    order = []
    pkg_output = {}
    pkg_status = {}
    with open(src, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            pkg, test, action = ev.get("Package", ""), ev.get("Test"), ev.get("Action")
            if test is None:
                if action == "output":
                    pkg_output.setdefault(pkg, []).append(ev.get("Output", ""))
                elif action in ("pass", "fail", "skip"):
                    pkg_status[pkg] = action
                continue
            key = (pkg, test)
            if key not in cases:
                cases[key] = {"status": "run", "elapsed": 0.0, "output": []}
                order.append(key)
            c = cases[key]
            if action == "output":
                c["output"].append(ev.get("Output", ""))
            elif action in ("pass", "fail", "skip"):
                c["status"] = action
                c["elapsed"] = float(ev.get("Elapsed") or 0)

    # Packages that failed without any failing test case.
    for pkg, status in pkg_status.items():
        if status == "fail" and not any(p == pkg and c["status"] == "fail" for (p, _), c in cases.items()):
            cases[(pkg, "(package)")] = {"status": "fail", "elapsed": 0.0, "output": pkg_output.get(pkg, [])}
            order.append((pkg, "(package)"))

    def rel_dir(pkg):
        d = pkg[len(module):].strip("/") if module and pkg.startswith(module) else ""
        return "/".join(p for p in (prefix, d) if p)

    suites = ET.Element("testsuites", name="go test")
    by_pkg = {}
    for pkg, test in order:
        c = cases[(pkg, test)]
        suite = by_pkg.get(pkg)
        if suite is None:
            suite = by_pkg[pkg] = ET.SubElement(suites, "testsuite", name=pkg, tests="0", failures="0", skipped="0")
        tc = ET.SubElement(suite, "testcase", classname=pkg, name=test, time=f"{c['elapsed']:.3f}")
        suite.set("tests", str(int(suite.get("tests")) + 1))
        # Drop the === RUN / --- FAIL frame lines; keep the test's own output.
        lines = [l.rstrip("\n") for l in c["output"] if not re.match(r"^(=== |--- |\s*--- )", l)]
        message = ""
        for l in lines:
            m = LOC.match(l)
            if m:
                d = rel_dir(pkg)
                tc.set("file", f"{d}/{m.group(1)}" if d else m.group(1))
                tc.set("line", m.group(2))
                message = m.group(3)
                break
        if not message:
            message = next((l.strip() for l in lines if l.strip()), c["status"])
        if c["status"] == "fail":
            suite.set("failures", str(int(suite.get("failures")) + 1))
            f = ET.SubElement(tc, "failure", message=message)
            f.text = "\n".join(lines)
        elif c["status"] == "skip":
            suite.set("skipped", str(int(suite.get("skipped")) + 1))
            ET.SubElement(tc, "skipped", message=message)
    ET.ElementTree(suites).write(dst, encoding="utf-8", xml_declaration=True)
    print(f"gotest2junit: {len(order)} test cases in {len(by_pkg)} packages -> {dst}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: gotest2junit.py <gotest.json> <junit.xml>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
