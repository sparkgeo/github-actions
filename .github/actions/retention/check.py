#!/usr/bin/env python3
"""Retention and residency enforcement in IaC (issue #120, plan Step 36).

Usage: check.py --retention retention.yml (--plan-json plan.json | --template template.json [--manifest manifest.json])
                [--region REGION] [--fail-on none|mismatch|all] [--comment comment.md] [--output report.json]

Runs in a virtualenv with PyYAML. Compares retention.yml (one entry per data
store: retention, mechanism, optional residency and ttl_attribute) with an
OpenTofu plan JSON or a CloudFormation template (CDK synth output):

  SPK_RET_1  every store in retention.yml exists in the plan, and every
             resource tagged data-class confidential or restricted of a
             retention-bearing type has an entry
  SPK_RET_2  S3 bucket with mechanism lifecycle: a lifecycle rule expires
             current objects at the declared days; with versioning on,
             noncurrent versions too
  SPK_RET_3  CloudWatch log group: retention_in_days equals the declared
             value (0 or absent never expires)
  SPK_RET_4  RDS: backup_retention_period equals the declared value
  SPK_RET_5  DynamoDB with mechanism ttl: TTL enabled, on ttl_attribute when
             declared
  SPK_RET_6  AWS Backup plan rules keep copies no longer than the longest
             declared retention plus defaults.backup_expiry_grace
  SPK_RES_1  resources tagged confidential or restricted sit in
             defaults.allowed_regions (or the store's residency); S3
             replication destinations and backup copy destinations too

fail-on: none (report), mismatch (mismatches and missing entries fail, the
default), all (residency and orphan findings fail too). The PR comment and
summary list every store: declared, implemented, status.
"""

import argparse
import json
import os
import re
import sys

import yaml

TYPES = {  # IaC type -> (mechanism, kind)
    "aws_s3_bucket": ("lifecycle", "s3"), "AWS::S3::Bucket": ("lifecycle", "s3"),
    "aws_cloudwatch_log_group": ("retention_in_days", "logs"), "AWS::Logs::LogGroup": ("retention_in_days", "logs"),
    "aws_rds_cluster": ("backup_retention", "rds"), "aws_db_instance": ("backup_retention", "rds"),
    "AWS::RDS::DBCluster": ("backup_retention", "rds"), "AWS::RDS::DBInstance": ("backup_retention", "rds"),
    "aws_dynamodb_table": ("ttl", "dynamodb"), "AWS::DynamoDB::Table": ("ttl", "dynamodb"),
}
SENSITIVE = {"confidential", "restricted"}


def days(text):
    """90d -> 90, 12m -> 360, 7y -> 2555; until-<event> -> None (not comparable)."""
    m = re.fullmatch(r"(\d+)([dmy])", str(text).strip())
    if not m:
        return None
    return int(m.group(1)) * {"d": 1, "m": 30, "y": 365}[m.group(2)]


def tags_of(values):
    t = values.get("tags_all") or values.get("tags") or {}
    if isinstance(t, list):  # CloudFormation [{Key, Value}]
        t = {x.get("Key"): x.get("Value") for x in t if isinstance(x, dict)}
    return {str(k).lower(): str(v).lower() for k, v in t.items()}


class Model:
    """Resources as {address: {type, values, region, refs}} from either input."""

    def __init__(self):
        self.resources = {}

    @classmethod
    def from_plan(cls, plan, default_region):
        m = cls()
        providers = {}
        for key, p in (plan.get("configuration", {}).get("provider_config") or {}).items():
            providers[key] = ((p.get("expressions") or {}).get("region") or {}).get("constant_value")
        refs = {}

        def walk_cfg(mod, prefix=""):
            for r in mod.get("resources", []):
                addr = prefix + r["address"]
                refs[addr] = {k: v.get("references", []) for k, v in (r.get("expressions") or {}).items() if isinstance(v, dict)}
            for name, child in (mod.get("module_calls") or {}).items():
                walk_cfg(child.get("module", {}), f"{prefix}module.{name}.")

        walk_cfg(plan.get("configuration", {}).get("root_module", {}))

        def walk(mod):
            for r in mod.get("resources", []):
                if r.get("mode", "managed") != "managed":
                    continue
                region = providers.get(r.get("provider_config_key") or r.get("provider_name", "").split("/")[-1]) or providers.get("aws") or default_region
                base = re.sub(r"\[[^\]]*\]$", "", r["address"])
                m.resources[r["address"]] = {"type": r["type"], "values": r.get("values") or {}, "region": region, "refs": refs.get(base, {})}
            for child in mod.get("child_modules", []):
                walk(child)

        walk(plan.get("planned_values", {}).get("root_module", {}))
        for rc in plan.get("resource_changes", []):
            if "delete" in rc.get("change", {}).get("actions", []) and rc["address"] in m.resources and rc["change"]["actions"] == ["delete"]:
                del m.resources[rc["address"]]
        return m

    @classmethod
    def from_template(cls, template, region):
        m = cls()
        for lid, r in (template.get("Resources") or {}).items():
            props = r.get("Properties") or {}
            refs = {}
            for k, v in props.items():
                found = []
                stack = [v]
                while stack:
                    x = stack.pop()
                    if isinstance(x, dict):
                        if "Ref" in x and isinstance(x["Ref"], str):
                            found.append(x["Ref"])
                        if "Fn::GetAtt" in x and isinstance(x["Fn::GetAtt"], list):
                            found.append(x["Fn::GetAtt"][0])
                        stack.extend(x.values())
                    elif isinstance(x, list):
                        stack.extend(x)
                if found:
                    refs[k] = found
            entry = {"type": r.get("Type", ""), "values": props, "region": region, "refs": refs}
            m.resources[lid] = entry
            path = (r.get("Metadata") or {}).get("aws:cdk:path")
            if path:
                m.resources[path] = entry
        return m

    def referencing(self, type_, field, target):
        """Resources of type_ whose field references target (by address or by name value)."""
        out = []
        tvals = self.resources.get(target, {}).get("values", {})
        names = {v for v in (tvals.get("bucket"), tvals.get("BucketName"), tvals.get("id")) if v}
        for addr, r in self.resources.items():
            if r["type"] != type_:
                continue
            fr = r["refs"].get(field, [])
            if any(x == target or x.startswith(target + ".") or target.startswith(x + ".") or x == target.split("[")[0] for x in fr):
                out.append(r)
            elif r["values"].get(field) in names and names:
                out.append(r)
        return out


def first(seq):
    return seq[0] if isinstance(seq, list) and seq else (seq if isinstance(seq, dict) else {})


def check_store(model, key, spec, findings):
    r = model.resources.get(key)
    label = f"{key}"
    if r is None:
        findings.append(("SPK_RET_1", "missing", key, f"declared in retention.yml but not in the plan", spec.get("retention"), "absent"))
        return
    want = days(spec.get("retention"))
    mech = spec.get("mechanism") or TYPES.get(r["type"], ("", ""))[0]
    kind = TYPES.get(r["type"], ("", ""))[1]
    v = r["values"]
    got = None
    if kind == "s3" and mech == "lifecycle":
        exp, nonc, versioned = None, None, False
        if r["type"].startswith("AWS::"):
            for rule in (v.get("LifecycleConfiguration") or {}).get("Rules", []):
                if rule.get("Status", "Enabled") == "Enabled":
                    exp = rule.get("ExpirationInDays", exp)
                    nonc = (rule.get("NoncurrentVersionExpiration") or {}).get("NoncurrentDays", nonc)
            versioned = (v.get("VersioningConfiguration") or {}).get("Status") == "Enabled"
        else:
            for lc in model.referencing("aws_s3_bucket_lifecycle_configuration", "bucket", key):
                for rule in lc["values"].get("rule", []):
                    if rule.get("status", "Enabled") == "Enabled":
                        exp = first(rule.get("expiration")).get("days", exp)
                        nonc = first(rule.get("noncurrent_version_expiration")).get("noncurrent_days", nonc)
            versioned = any(first(x["values"].get("versioning_configuration")).get("status") == "Enabled"
                            for x in model.referencing("aws_s3_bucket_versioning", "bucket", key))
        got = exp
        if exp is None:
            findings.append(("SPK_RET_2", "mismatch", key, "no enabled lifecycle rule with an expiration", spec.get("retention"), "none"))
        elif want is not None and int(exp) != want:
            findings.append(("SPK_RET_2", "mismatch", key, f"lifecycle expiration {exp} days, declared {want}", spec.get("retention"), f"{exp}d"))
        elif versioned and (nonc is None or (want is not None and int(nonc) != want)):
            findings.append(("SPK_RET_2", "mismatch", key, f"versioning is on but noncurrent versions expire after {nonc if nonc is not None else 'never'}, declared {want}", spec.get("retention"), f"{exp}d current, {nonc or 'never'} noncurrent"))
    elif kind == "logs":
        got = v.get("retention_in_days", v.get("RetentionInDays"))
        if not got:
            findings.append(("SPK_RET_3", "mismatch", key, "retention_in_days is 0 or absent (never expires)", spec.get("retention"), "never"))
        elif want is not None and int(got) != want:
            findings.append(("SPK_RET_3", "mismatch", key, f"retention_in_days {got}, declared {want}", spec.get("retention"), f"{got}d"))
        got = f"{got}d" if got else "never"
    elif kind == "rds":
        got = v.get("backup_retention_period", v.get("BackupRetentionPeriod"))
        if got is None:
            findings.append(("SPK_RET_4", "mismatch", key, "backup_retention_period not set", spec.get("retention"), "default"))
        elif want is not None and int(got) != want:
            findings.append(("SPK_RET_4", "mismatch", key, f"backup_retention_period {got}, declared {want}", spec.get("retention"), f"{got}d"))
        got = f"{got}d" if got is not None else "default"
    elif kind == "dynamodb" and mech == "ttl":
        ttl = first(v.get("ttl")) if not r["type"].startswith("AWS::") else (v.get("TimeToLiveSpecification") or {})
        enabled = ttl.get("enabled", ttl.get("Enabled"))
        attr = ttl.get("attribute_name", ttl.get("AttributeName"))
        got = f"ttl on {attr}" if enabled else "ttl off"
        if not enabled:
            findings.append(("SPK_RET_5", "mismatch", key, "TTL is not enabled", spec.get("retention"), got))
        elif spec.get("ttl_attribute") and attr != spec["ttl_attribute"]:
            findings.append(("SPK_RET_5", "mismatch", key, f"TTL attribute {attr}, declared {spec['ttl_attribute']}", spec.get("retention"), got))
    else:
        findings.append(("SPK_RET_1", "orphan", key, f"mechanism {mech!r} is not checkable for {r['type']}", spec.get("retention"), "unchecked"))
    return got


def arn_region(arn):
    parts = str(arn).split(":")
    return parts[3] if len(parts) > 4 and parts[0] == "arn" else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retention", default="retention.yml")
    ap.add_argument("--plan-json", default="")
    ap.add_argument("--template", default="")
    ap.add_argument("--manifest", default="")
    ap.add_argument("--region", default="")
    ap.add_argument("--fail-on", default="mismatch", choices=["none", "mismatch", "all"])
    ap.add_argument("--comment", default="")
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    if not os.path.exists(args.retention):
        print(f"::error title=retention::{args.retention} does not exist; copy docs/examples/retention.yml")
        return 1
    with open(args.retention, encoding="utf-8") as fh:
        table = yaml.safe_load(fh) or {}
    stores = table.get("stores") or {}
    defaults = table.get("defaults") or {}
    allowed = {str(x) for x in defaults.get("allowed_regions", [])}
    grace = days(defaults.get("backup_expiry_grace", "0d")) or 0

    region = args.region
    if args.plan_json:
        with open(args.plan_json, encoding="utf-8") as fh:
            model = Model.from_plan(json.load(fh), region)
    elif args.template:
        if args.manifest and os.path.exists(args.manifest) and not region:
            with open(args.manifest, encoding="utf-8") as fh:
                for art in (json.load(fh).get("artifacts") or {}).values():
                    env = art.get("environment", "")
                    if env.startswith("aws://"):
                        region = env.rsplit("/", 1)[-1]
        with open(args.template, encoding="utf-8") as fh:
            model = Model.from_template(json.load(fh), region)
    else:
        print("::error title=retention::give --plan-json or --template")
        return 1

    findings, rows = [], []
    for key, spec in stores.items():
        spec = spec or {}
        before = len(findings)
        got = check_store(model, key, spec, findings)
        status = "ok" if len(findings) == before else findings[-1][1]
        rows.append((key, spec.get("retention", ""), spec.get("mechanism", ""), got if got is not None else "-", status))

    # SPK_RET_1: sensitive retention-bearing resources without an entry
    for addr, r in model.resources.items():
        if r["type"] in TYPES and tags_of(r["values"]).get("data-class") in SENSITIVE and addr not in stores and "/" not in addr:
            findings.append(("SPK_RET_1", "missing", addr, f"tagged data-class {tags_of(r['values'])['data-class']} but has no entry in {args.retention}", "-", "-"))
            rows.append((addr, "-", "-", "-", "missing"))

    # SPK_RES_1: residency
    for addr, r in model.resources.items():
        if "/" in addr:
            continue
        cls = tags_of(r["values"]).get("data-class")
        if cls not in SENSITIVE:
            continue
        allowed_here = set((stores.get(addr) or {}).get("residency") or allowed)
        if allowed_here and r["region"] and r["region"] not in allowed_here:
            findings.append(("SPK_RES_1", "residency", addr, f"created in {r['region']}, allowed {', '.join(sorted(allowed_here))}", "-", r["region"]))
        elif allowed_here and not r["region"]:
            findings.append(("SPK_RES_1", "orphan", addr, "region unknown (no provider region or manifest environment; pass --region)", "-", "?"))
        if r["type"] == "aws_s3_bucket":
            for rep in model.referencing("aws_s3_bucket_replication_configuration", "bucket", addr):
                for rule in rep["values"].get("rule", []):
                    dest = first(rule.get("destination")).get("bucket")
                    dest_refs = [x for x in rep["refs"].get("rule", []) if x.startswith("aws_s3_bucket.")]
                    target = next((model.resources[x] for x in dest_refs if x in model.resources), None)
                    dregion = target["region"] if target else arn_region(dest)
                    if dregion and allowed_here and dregion not in allowed_here:
                        findings.append(("SPK_RES_1", "residency", addr, f"replicated to {dregion}, allowed {', '.join(sorted(allowed_here))}", "-", dregion))
    # SPK_RET_6: backup plans
    longest = max([d for d in (days((s or {}).get("retention")) for s in stores.values()) if d is not None] or [0])
    for addr, r in model.resources.items():
        if r["type"] not in ("aws_backup_plan", "AWS::Backup::BackupPlan"):
            continue
        rules = r["values"].get("rule", []) if r["type"] == "aws_backup_plan" else (r["values"].get("BackupPlan") or {}).get("BackupPlanRule", [])
        for rule in rules:
            lc = first(rule.get("lifecycle")) if r["type"] == "aws_backup_plan" else (rule.get("Lifecycle") or {})
            keep = lc.get("delete_after", lc.get("DeleteAfterDays"))
            name = rule.get("rule_name", rule.get("RuleName", "?"))
            if keep is None:
                findings.append(("SPK_RET_6", "mismatch", addr, f"rule {name} has no delete_after: backups never expire", f"{longest + grace}d max", "never"))
            elif int(keep) > longest + grace:
                findings.append(("SPK_RET_6", "mismatch", addr, f"rule {name} keeps backups {keep} days; longest declared retention {longest}d plus grace {grace}d", f"{longest + grace}d max", f"{keep}d"))
            for copy in (rule.get("copy_action", []) if r["type"] == "aws_backup_plan" else rule.get("CopyActions", [])):
                dreg = arn_region(copy.get("destination_vault_arn", copy.get("DestinationBackupVaultArn", "")))
                if dreg and allowed and dreg not in allowed:
                    findings.append(("SPK_RES_1", "residency", addr, f"rule {name} copies backups to {dreg}, allowed {', '.join(sorted(allowed))}", "-", dreg))

    failing = {"none": set(), "mismatch": {"mismatch", "missing"}, "all": {"mismatch", "missing", "residency", "orphan"}}[args.fail_on]
    errors = [f for f in findings if f[1] in failing]
    for pid, kind, addr, msg, declared, got in findings:
        level = "error" if kind in failing else "warning"
        print(f"::{level} title={pid}::{addr}: {msg}")

    lines = [f"## Retention check: {len(stores)} store(s) declared, {len(rows)} row(s), {len(findings)} finding(s), {len(errors)} failing (fail-on: {args.fail_on})", "",
             "| Store | Declared | Mechanism | Implemented | Status |", "|---|---|---|---|---|"]
    lines += [f"| `{k}` | {d} | {m} | {g} | {'**' + s + '**' if s != 'ok' else 'ok'} |" for k, d, m, g, s in rows]
    if findings:
        lines += ["", "| Policy | Resource | Finding |", "|---|---|---|"] + [f"| `{p}` | `{a}` | {m} |" for p, _, a, m, _, _ in findings]
    lines += ["", f"Allowed regions: {', '.join(sorted(allowed)) or 'any'}; backup expiry grace {grace}d. Mechanisms and the backup-expiry position: docs/retention.md (#120); stores named as in the asset inventory (#115) and ropa.yml (#119)."]
    text = "\n".join(lines) + "\n"
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(text)
    print(text)
    if args.comment:
        with open(args.comment, "w") as fh:
            fh.write("<!-- retention-check -->\n" + text)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"store-count={len(stores)}\nfinding-count={len(findings)}\nerror-count={len(errors)}\n")
    if args.output:
        with open(args.output, "w") as fh:
            json.dump({"rows": [dict(zip(("store", "declared", "mechanism", "implemented", "status"), r)) for r in rows],
                       "findings": [dict(zip(("policy", "kind", "resource", "message", "declared", "implemented"), f)) for f in findings],
                       "errors": len(errors)}, fh, indent=1)
            fh.write("\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
