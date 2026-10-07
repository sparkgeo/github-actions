#!/usr/bin/env python3
"""Turn JUnit XML and a line-rate coverage XML into a CI gate.

Shared by the pytest and node-test composites: pytest's xunit1 JUnit plus
coverage.py XML, or vitest/jest JUnit plus cobertura XML. Both coverage
formats carry `line-rate` on the root element.

Inputs via env: JUNIT_XML, COVERAGE_XML, COVERAGE_THRESHOLD (percent; 0
disables), REPORT_TOOL (annotation title and summary heading; default
pytest). Writes tests-total / tests-failed / tests-skipped /
coverage-percent to GITHUB_OUTPUT, a table to GITHUB_STEP_SUMMARY, one
::error annotation per failed or errored test case, and exits 1 when any
test failed or coverage is below the threshold.

Stdlib only: this runs inside the project's Python, which may have nothing
else installed. Invoked with -I so the project tree cannot shadow imports.
"""
import os
import sys
import xml.etree.ElementTree as ET


def out(path_env, text):
    path = os.environ.get(path_env)
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(text)


def annotate(kind, title, message, file=None, line=None):
    # Workflow-command values are single-line; the message is truncated to
    # keep the annotation readable in the PR view.
    message = " ".join(message.split())[:300]
    loc = f" file={file},line={line}," if file else " "
    print(f"::{kind}{loc}title={title}::{message}")


def main() -> int:
    tool = os.environ.get("REPORT_TOOL", "pytest")
    junit_path = os.environ["JUNIT_XML"]
    cov_path = os.environ.get("COVERAGE_XML", "")
    threshold = float(os.environ.get("COVERAGE_THRESHOLD", "0") or 0)

    try:
        root = ET.parse(junit_path).getroot()
    except (OSError, ET.ParseError) as exc:
        annotate("error", tool, f"cannot read JUnit XML {junit_path}: {exc}")
        return 1

    total = failed = skipped = 0
    for case in root.iter("testcase"):
        total += 1
        name = f"{case.get('classname', '')}::{case.get('name', '')}"
        bad = case.find("failure")
        if bad is None:
            bad = case.find("error")
        if bad is not None:
            failed += 1
            # pytest xunit1 sets file; jest-junit sets file when
            # JEST_JUNIT_ADD_FILE_ATTRIBUTE is on; vitest puts the path in
            # classname. pytest's `line` is zero-based; the others omit it.
            classname = case.get("classname", "")
            file = case.get("file") or (classname if "/" in classname else None)
            line = int(case.get("line", "0") or 0) + 1
            annotate("error", f"{tool} {name}", bad.get("message") or (bad.text or "").strip() or "failed", file, line)
        elif case.find("skipped") is not None:
            skipped += 1

    coverage = None
    if cov_path:
        try:
            rate = ET.parse(cov_path).getroot().get("line-rate")
            coverage = round(float(rate) * 100, 1)
        except (OSError, ET.ParseError, TypeError, ValueError) as exc:
            annotate("error", "coverage", f"cannot read coverage XML {cov_path}: {exc}")

    cov_text = f"{coverage}%" if coverage is not None else "n/a"
    rc = 0
    if failed:
        annotate("error", tool, f"{failed} of {total} tests failed")
        rc = 1
    if threshold > 0:
        if coverage is None:
            rc = 1
        elif coverage < threshold:
            annotate("error", "coverage", f"line coverage {cov_text} is below the {threshold:g}% threshold")
            rc = 1

    out("GITHUB_STEP_SUMMARY", "\n".join([
        f"## {tool}", "",
        "| Tests | Failed | Skipped | Line coverage | Threshold |",
        "|---|---|---|---|---|",
        f"| {total} | {failed} | {skipped} | {cov_text} | {threshold:g}% |", "", "",
    ]))
    out("GITHUB_OUTPUT", "".join([
        f"tests-total={total}\n", f"tests-failed={failed}\n", f"tests-skipped={skipped}\n",
        f"coverage-percent={'' if coverage is None else coverage}\n",
    ]))
    print(f"{tool}: {total} tests, {failed} failed, {skipped} skipped; coverage {cov_text} (threshold {threshold:g}%)")
    return rc


if __name__ == "__main__":
    sys.exit(main())
