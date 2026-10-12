#!/usr/bin/env python3
"""DR readiness report from checkov JSON (issue #93).

Usage: dr-report.py --json results.json --report report.md [--directory DIR]

Groups failed checks by resource with the check name, checkov's guideline
link and a remediation snippet per id, lists suppressions that carry no
reason (checkov:skip=ID with nothing after it), writes the markdown for the
PR comment (marker <!-- dr-check -->) and the step summary, and sets outputs
failed-count, resource-count, unreasoned-skips. Exit 0 always (the strict
run is the gate); 2 when the JSON is missing. Standard library only.
"""

import argparse
import json
import os
import sys
from pathlib import Path

TITLE = "dr-check"
NO_REASON = {"", "No comment provided"}
REMEDIATION = {
    "CKV_AWS_21": 'aws_s3_bucket_versioning with versioning_configuration { status = "Enabled" }',
    "CKV_AWS_144": "aws_s3_bucket_replication_configuration with a rule whose destination is a bucket in another region",
    "CKV_AWS_133": "backup_retention_period = 7 (or more) on the aws_db_instance / aws_rds_cluster",
    "CKV_AWS_157": "multi_az = true on the aws_db_instance",
    "CKV_AWS_28": "point_in_time_recovery { enabled = true } on the aws_dynamodb_table",
    "CKV_AWS_134": "snapshot_retention_limit = 7 (or more) on the aws_elasticache_cluster",
    "CKV_AWS_166": "kms_key_arn = aws_kms_key.backup.arn on the aws_backup_vault",
    "CKV_GCP_78": "versioning { enabled = true } on the google_storage_bucket",
    "CKV_GCP_14": "settings { backup_configuration { enabled = true } } on the google_sql_database_instance",
    "CKV_AZURE_206": 'account_replication_type = "GRS" (or GZRS, RAGRS) on the azurerm_storage_account',
    "CKV_AZURE_94": 'geo_redundant_backup_enabled = true (or geo_redundant_backup = "Enabled") on the MySQL server',
    "CKV_AZURE_102": 'geo_redundant_backup_enabled = true on the azurerm_postgresql_server',
    "CKV_AZURE_129": 'geo_redundant_backup_enabled = true on the azurerm_mariadb_server',
    "CKV_AZURE_136": "geo_redundant_backup_enabled = true on the azurerm_postgresql_flexible_server",
    "CKV_AZURE_230": 'sku_name = "Standard" (or Premium) on the azurerm_redis_cache',
    "CKV_AZURE_111": "soft_delete_retention_days = 90 on the azurerm_key_vault",
    "SPK_DR_1": "add the instance or cluster ARN to resources of an aws_backup_selection",
    "SPK_DR_2": "add the file system ARN to resources of an aws_backup_selection",
    "SPK_DR_3": "point_in_time_recovery { enabled = true }, or add the table ARN to an aws_backup_selection",
    "SPK_DR_4": "rule { lifecycle { delete_after = 35 } copy_action { destination_vault_arn = <vault in another region> } } on the aws_backup_plan",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True)
    ap.add_argument("--report", required=True)
    ap.add_argument("--directory", default="")
    args = ap.parse_args()
    path = Path(args.json)
    if not path.is_file():
        print(f"::error title={TITLE}::checkov JSON {path} not found")
        return 2
    data = json.loads(path.read_text())
    reports = data if isinstance(data, list) else [data]
    failed, skipped = [], []
    for r in reports:
        results = r.get("results") or {}
        failed += results.get("failed_checks") or []
        skipped += results.get("skipped_checks") or []

    by_resource = {}
    for c in failed:
        by_resource.setdefault(c.get("resource", "?"), []).append(c)
    unreasoned = [c for c in skipped
                  if ((c.get("check_result") or {}).get("suppress_comment") or c.get("suppress_comment") or "").strip() in NO_REASON]
    for c in unreasoned:
        print(f"::warning title={TITLE}::{c.get('resource')} skips {c.get('check_id')} without a reason; cite the tier or the exception issue (docs/dr-checklist.md)")

    where = f" ({args.directory})" if args.directory else ""
    lines = ["<!-- dr-check -->"]
    if not failed:
        lines.append(f"## DR readiness{where}: no findings")
    else:
        lines.append(f"## DR readiness{where}: {len(failed)} findings on {len(by_resource)} resources")
        for resource, checks in sorted(by_resource.items()):
            first = checks[0]
            loc = f"{first.get('file_path', '').lstrip('/')}:{(first.get('file_line_range') or [0])[0]}"
            lines += ["", f"### `{resource}`", "", f"`{loc}`", ""]
            for c in sorted(checks, key=lambda c: c.get("check_id", "")):
                cid = c.get("check_id", "")
                guideline = c.get("guideline") or ""
                link = f" ([guideline]({guideline}))" if guideline else ""
                fix = REMEDIATION.get(cid)
                lines.append(f"- `{cid}` {c.get('check_name', '')}{link}")
                if fix:
                    lines.append(f"  - fix: `{fix}`")
    if unreasoned:
        lines += ["", "### Suppressions without a reason", "",
                  "Every `checkov:skip` must cite the DR tier or the approved exception issue (`docs/dr-checklist.md`)."]
        lines += [f"- `{c.get('check_id')}` on `{c.get('resource')}` ({c.get('file_path', '').lstrip('/')})" for c in unreasoned]
    lines += ["", f"Advisory run over `policies/dr` (checkov). Strict checks, when set, run separately and fail the job."]
    text = "\n".join(lines) + "\n"
    Path(args.report).write_text(text)
    print(text)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as f:
            f.write(text)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"failed-count={len(failed)}\nresource-count={len(by_resource)}\nunreasoned-skips={len(unreasoned)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
