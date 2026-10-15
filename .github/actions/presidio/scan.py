#!/usr/bin/env python3
"""PII scan of text and data files with presidio (issue #97).

Usage: scan.py --root DIR --files-from LIST --include-globs G,G --entities E,E
                --block-entities E,E --score-threshold 0.7 --model en_core_web_sm
                [--allowlist .pii-allowlist.yml] [--recognizers policies/pii/recognizers.yml]
                [--sarif out.sarif] [--output report.json] [--max-bytes 1000000]

Runs in the virtualenv that holds presidio-analyzer and the spaCy model. Reads
each file from the list that matches an include glob, analyses it with the
predefined recognizers plus the custom ones, drops matches covered by the
allowlist (literals, regexes, paths), and reports entity type, file, line and
column only: a matched value is never printed, logged or written to SARIF.
Exit 1 when a finding's entity is in --block-entities.

Allowlist (docs/data-classification.md section 5):
  version: 1
  literals: [{value: "...", reason: "..."}]
  regexes:  [{pattern: "...", reason: "..."}]
  paths:    [{glob: "tests/fixtures/**", reason: "..."}]
"""

import argparse
import json
import os
import re
import sys

import yaml

from presidio_analyzer import AnalyzerEngine, RecognizerRegistry
from presidio_analyzer.nlp_engine import NlpEngineProvider

TEXT_EXT = (".md", ".txt", ".rst", ".csv", ".tsv", ".json", ".yaml", ".yml", ".ipynb", ".sql", ".toml", ".ini", ".cfg", ".env", ".xml", ".html", ".log")


def glob_match(path, pattern):
    """Gitignore-style glob: ** spans directories, * and ? stay inside one segment."""
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


def luhn_ok(digits):
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d = d * 2 - 9 if d * 2 > 9 else d * 2
        total += d
    return total % 10 == 0


def load_allowlist(path):
    if not path or not os.path.exists(path):
        return [], [], []
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    lits = [str(e.get("value", e) if isinstance(e, dict) else e) for e in data.get("literals", []) or []]
    rxs = [re.compile(str(e.get("pattern", e) if isinstance(e, dict) else e)) for e in data.get("regexes", []) or []]
    paths = [str(e.get("glob", e) if isinstance(e, dict) else e) for e in data.get("paths", []) or []]
    return lits, rxs, paths


def read_text(full, max_bytes):
    if os.path.getsize(full) > max_bytes:
        return None
    with open(full, "rb") as fh:
        raw = fh.read()
    if b"\0" in raw:
        return None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if full.endswith(".ipynb"):
        try:
            nb = json.loads(text)
            text = "\n".join("".join(c.get("source", [])) for c in nb.get("cells", []))
        except ValueError:
            pass
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--files-from", required=True)
    ap.add_argument("--include-globs", default="**/*.md,**/*.txt,**/*.rst,**/*.csv,**/*.json,**/*.yaml,**/*.yml,**/*.ipynb,**/*.sql,**/fixtures/**")
    ap.add_argument("--entities", default="CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE,EMAIL_ADDRESS,PHONE_NUMBER,IP_ADDRESS,PERSON,LOCATION")
    ap.add_argument("--block-entities", default="CREDIT_CARD,US_SSN,CA_SIN,IBAN_CODE")
    ap.add_argument("--score-threshold", type=float, default=0.7)
    ap.add_argument("--model", default="en_core_web_sm")
    ap.add_argument("--language", default="en")
    ap.add_argument("--allowlist", default=".pii-allowlist.yml")
    ap.add_argument("--recognizers", default="")
    ap.add_argument("--sarif", default="")
    ap.add_argument("--output", default="")
    ap.add_argument("--max-bytes", type=int, default=1_000_000)
    args = ap.parse_args()

    globs = [g.strip() for g in args.include_globs.split(",") if g.strip()]
    entities = [e.strip() for e in args.entities.split(",") if e.strip()]
    block = {e.strip() for e in args.block_entities.split(",") if e.strip()}
    lits, rxs, allow_paths = load_allowlist(os.path.join(args.root, args.allowlist))

    with open(args.files_from, encoding="utf-8") as fh:
        candidates = [ln.strip() for ln in fh if ln.strip()]
    files = [f for f in candidates if any(glob_match(f, g) for g in globs)
             and not any(glob_match(f, p) for p in allow_paths)
             and (f.lower().endswith(TEXT_EXT) or any(glob_match(f, g) for g in globs if not g.endswith(TEXT_EXT)))]

    nlp = NlpEngineProvider(nlp_configuration={"nlp_engine_name": "spacy",
                                                "models": [{"lang_code": args.language, "model_name": args.model}]}).create_engine()
    registry = RecognizerRegistry()
    registry.load_predefined_recognizers(nlp_engine=nlp, languages=[args.language])
    if args.recognizers and os.path.exists(args.recognizers):
        registry.add_recognizers_from_yaml(args.recognizers)
    analyzer = AnalyzerEngine(registry=registry, nlp_engine=nlp, supported_languages=[args.language])
    supported = set(analyzer.get_supported_entities(language=args.language))
    wanted = [e for e in entities if e in supported]
    for e in entities:
        if e not in supported:
            print(f"::warning title=pii::entity {e} has no recognizer (model {args.model}); skipped")

    findings, skipped, errors = [], [], []
    for rel in files:
        full = os.path.join(args.root, rel)
        if not os.path.isfile(full):
            continue
        text = read_text(full, args.max_bytes)
        if text is None:
            skipped.append(rel)
            continue
        try:
            results = analyzer.analyze(text=text, entities=wanted, language=args.language,
                                       score_threshold=args.score_threshold, allow_list=lits or None)
        except Exception as e:  # noqa: BLE001  (one bad file must not hide the others)
            errors.append(f"{rel}: {type(e).__name__}")
            continue
        line_starts = [0]
        for i, ch in enumerate(text):
            if ch == "\n":
                line_starts.append(i + 1)
        for r in results:
            value = text[r.start:r.end]
            if any(rx.search(value) for rx in rxs):
                continue
            if r.entity_type == "CA_SIN" and not luhn_ok(re.sub(r"\D", "", value)):
                continue
            line = max(i for i, s in enumerate(line_starts) if s <= r.start) + 1
            col = r.start - line_starts[line - 1] + 1
            findings.append({"entity": r.entity_type, "score": round(r.score, 2), "file": rel, "line": line, "col": col,
                             "length": r.end - r.start, "blocking": r.entity_type in block})

    findings.sort(key=lambda f: (not f["blocking"], f["file"], f["line"], f["col"]))
    for f in findings:
        level = "error" if f["blocking"] else "warning"
        print(f"::{level} file={f['file']},line={f['line']},col={f['col']},title=pii {f['entity']}::{f['entity']} (score {f['score']}) at {f['file']}:{f['line']}:{f['col']}")
    for e in errors:
        print(f"::warning title=pii::could not analyse {e}")

    by_entity = {}
    for f in findings:
        d = by_entity.setdefault(f["entity"], {"count": 0, "files": set(), "blocking": f["blocking"]})
        d["count"] += 1
        d["files"].add(f["file"])
    blocking = [f for f in findings if f["blocking"]]
    summary = [f"## PII scan: {len(files)} file(s), {len(findings)} finding(s), {len(blocking)} blocking "
               f"(threshold {args.score_threshold}, model {args.model})", ""]
    if by_entity:
        summary += ["| Entity | Findings | Files | Gate |", "|---|---|---|---|"]
        summary += [f"| `{e}` | {d['count']} | {len(d['files'])} | {'**block**' if d['blocking'] else 'advise'} |"
                    for e, d in sorted(by_entity.items(), key=lambda kv: (not kv[1]['blocking'], kv[0]))]
        summary += ["", "| File | Line | Entity | Score |", "|---|---|---|---|"]
        summary += [f"| `{f['file']}` | {f['line']} | `{f['entity']}` | {f['score']} |" for f in findings[:200]]
    if skipped:
        summary += ["", f"Skipped (binary, too large or not UTF-8): {len(skipped)} file(s)."]
    if errors:
        summary += ["", "### Could not analyse", ""] + [f"- {e}" for e in errors]
    summary += ["", "Values are never shown; open the file at the line to review. Documented placeholders go in `.pii-allowlist.yml` (docs/data-classification.md section 5)."]
    text = "\n".join(summary) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)

    if args.sarif:
        rules = sorted(by_entity)
        sarif = {"version": "2.1.0", "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
                 "runs": [{"tool": {"driver": {"name": "presidio-pii-scan", "informationUri": "https://github.com/sparkgeo/github-actions",
                                                "rules": [{"id": f"PII/{e}", "shortDescription": {"text": f"{e} detected"},
                                                           "defaultConfiguration": {"level": "error" if e in block else "warning"}} for e in rules]}},
                           "results": [{"ruleId": f"PII/{f['entity']}", "level": "error" if f["blocking"] else "warning",
                                        "message": {"text": f"{f['entity']} (score {f['score']}); value withheld"},
                                        "locations": [{"physicalLocation": {"artifactLocation": {"uri": f["file"]},
                                                                            "region": {"startLine": f["line"], "startColumn": f["col"]}}}]}
                                       for f in findings]}]}
        with open(args.sarif, "w") as fh:
            json.dump(sarif, fh, indent=1)
            fh.write("\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"finding-count={len(findings)}\nblocking-count={len(blocking)}\nfile-count={len(files)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"files": files, "skipped": skipped, "errors": errors, "findings": findings}, fh, indent=1)
            fh.write("\n")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
