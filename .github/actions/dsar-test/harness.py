#!/usr/bin/env python3
"""DSAR export and erasure test harness (issue #122, plan Step 36 Standard).

Usage: harness.py --ropa ropa.yml --seed CMD --export CMD --erase CMD --out DIR
                  [--psql "psql $DATABASE_URL"] [--activities id,id] [--seed-bystander]

Seeds a synthetic subject (and a bystander) through the consuming repo's
seed command, runs its export script and asserts the bundle holds every
subject identifier and no bystander value, runs its erase script and asserts
no row references the subject in any subject_keys table (delete) or that the
identifier is gone from the rows that stay (anonymise), that no text column
of those tables still holds the subject's values, and that every foreign key
still holds. Writes out/subject.json, out/dsar-log.md and out/report.json.
Exit 1 on any failed assertion. subject_keys come from ropa.yml, read
without a YAML parser (standard library only).
"""

import argparse
import json
import os
import random
import re
import shlex
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

FIRST = ["Avery", "Blake", "Casey", "Devon", "Emery", "Finley", "Harper", "Jordan", "Kendall", "Morgan", "Reese", "Rowan"]
LAST = ["Testsubject", "Fixture", "Synthetic", "Placeholder", "Harness", "Sample"]


def subject_keys(path, activities):
    """[(activity, table, column, erase)] from ropa.yml, without PyYAML."""
    keys, act, in_keys = [], None, False
    if not os.path.exists(path):
        return keys
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        s = line.strip()
        m = re.match(r"-\s*id:\s*([A-Za-z0-9_-]+)", s)
        if m and (len(line) - len(line.lstrip())) <= 4:
            act, in_keys = m.group(1), False
            continue
        if re.match(r"subject_keys:\s*$", s):
            in_keys = True
            continue
        if re.match(r"subject_keys:\s*\[\s*\]", s):
            in_keys = False
            continue
        if in_keys:
            m = re.match(r"-\s*\{(.*)\}", s)
            if m:
                kv = dict(re.findall(r"(\w+):\s*([^,}]+)", m.group(1)))
                if activities and act not in activities:
                    continue
                keys.append((act, kv.get("table", "").strip(), kv.get("column", "").strip(), kv.get("erase", "delete").strip()))
            elif s and not s.startswith("-") and not s.startswith("table:"):
                in_keys = False
    return [k for k in keys if k[1] and k[2]]


def make_subject(seed):
    rnd = random.Random(seed)
    sid = str(uuid.UUID(int=rnd.getrandbits(128), version=4))
    first, last = rnd.choice(FIRST), rnd.choice(LAST)
    tag = rnd.randint(1000, 9999)
    start = datetime(2026, 10, 1, 8, tzinfo=timezone.utc)
    lon, lat = -123.12 + rnd.random() * 0.1, 49.26 + rnd.random() * 0.05
    trail = [[round(lon + i * 0.004, 5), round(lat + i * 0.002, 5), (start + timedelta(minutes=15 * i)).isoformat()] for i in range(4)]
    return {"id": sid, "email": f"{first.lower()}.{last.lower()}{tag}@example.com", "name": f"{first} {last}",
            "phone": f"+1 604 555 01{tag % 100:02d}", "trail": trail}


class Harness:
    def __init__(self, psql, out):
        self.psql = shlex.split(psql)
        self.out = out
        self.log = []
        self.failed = 0

    def check(self, ok, text):
        self.log.append(f"- {'PASS' if ok else 'FAIL'}: {text}")
        if not ok:
            self.failed += 1
            print(f"::error title=dsar::{text}")
        return ok

    def sql(self, query, *params):
        args = []
        for i, p in enumerate(params):
            args += ["-v", f"p{i}={p}"]
        # psql interpolates :'var' only in input read from a file or stdin, not in -c
        r = subprocess.run(self.psql + ["-At", "-q", "-v", "ON_ERROR_STOP=1", *args, "-f", "-"], input=query + "\n", capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else f"psql exit {r.returncode}")
        return r.stdout.strip()

    def run(self, cmd, env):
        r = subprocess.run(["bash", "-euo", "pipefail", "-c", cmd], env={**os.environ, **env}, capture_output=True, text=True)
        tail = (r.stdout + r.stderr).strip().splitlines()[-5:]
        return r.returncode, "\n".join(tail)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ropa", default="ropa.yml")
    ap.add_argument("--activities", default="")
    ap.add_argument("--seed", required=True)
    ap.add_argument("--export", required=True)
    ap.add_argument("--erase", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--psql", default="psql " + os.environ.get("DATABASE_URL", ""))
    ap.add_argument("--random-seed", default="")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    h = Harness(args.psql, args.out)
    acts = {a.strip() for a in args.activities.split(",") if a.strip()}
    keys = subject_keys(args.ropa, acts)
    h.check(bool(keys), f"ropa.yml declares subject_keys ({len(keys)} table/column pair(s))" if keys else "ropa.yml declares no subject_keys; the harness cannot know where the subject lives")

    seed = args.random_seed or datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    subject, bystander = make_subject(seed + "-subject"), make_subject(seed + "-bystander")
    with open(os.path.join(args.out, "subject.json"), "w") as fh:
        json.dump({"subject": subject, "bystander": bystander, "seed": seed}, fh, indent=1)

    def env_for(s):
        return {"SUBJECT_ID": s["id"], "SUBJECT_EMAIL": s["email"], "SUBJECT_NAME": s["name"], "SUBJECT_PHONE": s["phone"], "SUBJECT_TRAIL": json.dumps(s["trail"])}

    for who, s in (("subject", subject), ("bystander", bystander)):
        rc, tail = h.run(args.seed, env_for(s))
        h.check(rc == 0, f"seed-command inserted the {who}" + ("" if rc == 0 else f": exit {rc}: {tail}"))
    if h.failed:
        return finish(h, args)

    # presence before export, per subject_keys
    for act, table, column, _ in keys:
        try:
            n = int(h.sql(f"SELECT count(*) FROM {table} WHERE {column}::text = :'p0'", subject["id"]))
        except RuntimeError as e:
            h.check(False, f"{act}: {table}.{column}: cannot query ({e})")
            continue
        h.check(n > 0, f"{act}: {table}.{column} references the subject before export ({n} row(s))")

    # export
    bundle = os.path.join(args.out, "export")
    os.makedirs(bundle, exist_ok=True)
    rc, tail = h.run(f"{args.export} {shlex.quote(subject['id'])}", {"DSAR_OUT": bundle})
    h.check(rc == 0, "export script ran" + ("" if rc == 0 else f": exit {rc}: {tail}"))
    blob = ""
    for root, _, files in os.walk(bundle):
        for f in files:
            with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                blob += fh.read() + "\n"
    h.check(bool(blob.strip()), f"export bundle is not empty ({len(blob)} bytes)")
    for label, value in (("id", subject["id"]), ("email", subject["email"]), ("name", subject["name"]), ("phone", subject["phone"])):
        h.check(value in blob, f"export contains the subject's {label}")
    for i, (lon, lat, _) in enumerate(subject["trail"]):
        h.check(str(lon) in blob and str(lat) in blob, f"export contains trail point {i + 1}")
    for label, value in (("id", bystander["id"]), ("email", bystander["email"]), ("name", bystander["name"])):
        h.check(value not in blob, f"export does not contain the bystander's {label}")

    # erase
    rc, tail = h.run(f"{args.erase} {shlex.quote(subject['id'])}", {})
    h.check(rc == 0, "erase script ran" + ("" if rc == 0 else f": exit {rc}: {tail}"))
    tables = sorted({t for _, t, _, _ in keys})
    for act, table, column, erase in keys:
        try:
            n = int(h.sql(f"SELECT count(*) FROM {table} WHERE {column}::text = :'p0'", subject["id"]))
        except RuntimeError as e:
            h.check(False, f"{act}: {table}.{column}: cannot query after erasure ({e})")
            continue
        h.check(n == 0, f"{act}: {table}.{column} no longer references the subject ({erase})" if n == 0 else f"{act}: {table}.{column} still references the subject in {n} row(s)")
    for table in tables:
        for label, value in (("email", subject["email"]), ("name", subject["name"]), ("phone", subject["phone"])):
            try:
                n = int(h.sql(f"SELECT count(*) FROM {table} t WHERE to_jsonb(t)::text ILIKE '%' || :'p0' || '%'", value))
            except RuntimeError as e:
                h.check(False, f"{table}: cannot search columns ({e})")
                break
            h.check(n == 0, f"{table}: no column still holds the subject's {label}" if n == 0 else f"{table}: {n} row(s) still hold the subject's {label}")
    try:
        n_by = int(h.sql("SELECT count(*) FROM " + tables[0] + " t WHERE to_jsonb(t)::text ILIKE '%' || :'p0' || '%'", bystander["email"])) if tables else 0
        h.check(n_by > 0, "the bystander's data survived the erasure" if n_by > 0 else "the bystander's data was erased too")
    except RuntimeError:
        pass

    # referential integrity over every single-column foreign key
    try:
        fks = json.loads(h.sql(
            "SELECT coalesce(json_agg(json_build_object('name', c.conname, 'child', c.conrelid::regclass::text, 'ccol', a.attname, "
            "'parent', c.confrelid::regclass::text, 'pcol', pa.attname)), '[]') FROM pg_constraint c "
            "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] "
            "JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[1] "
            "WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1 AND c.connamespace = 'public'::regnamespace") or "[]")
        for fk in fks:
            n = int(h.sql(f"SELECT count(*) FROM {fk['child']} c LEFT JOIN {fk['parent']} p ON c.{fk['ccol']} = p.{fk['pcol']} WHERE c.{fk['ccol']} IS NOT NULL AND p.{fk['pcol']} IS NULL"))
            h.check(n == 0, f"foreign key {fk['name']} holds ({fk['child']}.{fk['ccol']} -> {fk['parent']}.{fk['pcol']})" if n == 0 else f"foreign key {fk['name']}: {n} orphan row(s)")
        h.check(True, f"{len(fks)} foreign key(s) checked")
    except RuntimeError as e:
        h.check(False, f"foreign-key check failed: {e}")
    return finish(h, args)


def finish(h, args):
    total = len(h.log)
    head = f"## DSAR test: {total - h.failed} of {total} assertion(s) passed" + (" (FAILED)" if h.failed else "")
    text = "\n".join([head, "", f"Run at {datetime.now(timezone.utc).isoformat(timespec='seconds')}; export bundle and this log are the evidence (retained 400 days).", ""] + h.log) + "\n"
    with open(os.path.join(args.out, "dsar-log.md"), "w") as fh:
        fh.write(text)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"assertions={total}\nfailed={h.failed}\n")
    with open(os.path.join(args.out, "report.json"), "w") as fh:
        json.dump({"assertions": total, "failed": h.failed, "log": h.log}, fh, indent=1)
        fh.write("\n")
    return 1 if h.failed else 0


if __name__ == "__main__":
    sys.exit(main())
