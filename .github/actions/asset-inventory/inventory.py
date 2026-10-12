#!/usr/bin/env python3
"""Asset inventory from OpenTofu plan JSON or CDK synth templates (issue #115).

Usage: inventory.py --stack tofu|cdk --input DIR --repo OWNER/NAME --output inventory.json
                    [--required-tags owner,project,environment,data-class] [--account ID]
                    [--dot FILE] [--svg FILE] [--mermaid FILE] [--mermaid-max-nodes 60]
                    [--diff-base inventory.json] [--report report.md] [--now ISO8601]

tofu: every *.json under --input with planned_values; root_module and nested
child_modules are walked, so module, for_each and count instances appear with
their full address. Tags come from tags_all, tags, effective_labels or labels;
a type that has none of those attributes is recorded as not taggable. Region
comes from the provider configuration; plan JSON has no source positions.
cdk: every *.template.json; tags from Properties.Tags, source path from
Metadata["aws:cdk:path"]. Resources with no required tag get tag_violations.

Output schema: docs/asset-inventory.schema.json. Exit 0 unless usage error (2);
enforcement is the tagging gates' job (#114), this is the register.
Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

TITLE = "asset-inventory"
DEFAULT_REQUIRED = "owner,project,environment,data-class"
TOFU_TAG_ATTRS = ("tags_all", "tags", "effective_labels", "labels")
CFN_TAGGABLE = {
    "AWS::S3::Bucket", "AWS::IAM::Role", "AWS::IAM::User", "AWS::SNS::Topic", "AWS::SQS::Queue",
    "AWS::Lambda::Function", "AWS::DynamoDB::Table", "AWS::EC2::Instance", "AWS::EC2::VPC", "AWS::EC2::Subnet",
    "AWS::EC2::SecurityGroup", "AWS::EC2::Volume", "AWS::RDS::DBInstance", "AWS::RDS::DBCluster",
    "AWS::ECS::Cluster", "AWS::ECS::Service", "AWS::ECS::TaskDefinition", "AWS::EKS::Cluster", "AWS::KMS::Key",
    "AWS::Logs::LogGroup", "AWS::SecretsManager::Secret", "AWS::CloudFront::Distribution",
    "AWS::ElasticLoadBalancingV2::LoadBalancer", "AWS::ApiGateway::RestApi", "AWS::ApiGatewayV2::Api",
    "AWS::StepFunctions::StateMachine", "AWS::Events::Rule", "AWS::CloudWatch::Alarm", "AWS::ECR::Repository",
    "AWS::Cognito::UserPool", "AWS::Kinesis::Stream", "AWS::ElastiCache::ReplicationGroup",
    "AWS::OpenSearchService::Domain", "AWS::SSM::Parameter", "AWS::Backup::BackupVault", "AWS::EFS::FileSystem",
    "AWS::CodeBuild::Project", "AWS::Glue::Job", "AWS::SageMaker::NotebookInstance", "AWS::Route53::HostedZone",
}
CFN_SKIP = {"AWS::CDK::Metadata"}
# Cloud-side name of a resource, when the plan or template states it. Used by
# asset-drift to match register records to live ARNs; null when generated at
# apply time (vpc ids, CDK-generated names).
TOFU_IDENTIFIER_ATTRS = ("bucket", "function_name", "identifier", "cluster_identifier", "cluster_name", "table_name",
                         "repository_name", "domain_name", "name")
CFN_IDENTIFIER_PROPS = ("BucketName", "FunctionName", "RoleName", "TableName", "TopicName", "QueueName", "ClusterName",
                        "RepositoryName", "DBInstanceIdentifier", "DomainName", "LogGroupName", "StreamName",
                        "UserPoolName", "AlarmName", "StateMachineName", "Name")
FILL = {"public": "#d9ead3", "internal": "#cfe2f3", "confidential": "#fff2cc", "restricted": "#f4cccc", None: "#eeeeee"}


def warn(msg):
    print(f"::warning title={TITLE}::{msg}")


def usage_error(msg):
    print(f"::error title={TITLE}::{msg}")
    return 2


def identifier_from(mapping, keys):
    for k in keys:
        v = mapping.get(k)
        if isinstance(v, str) and v:
            return v
    return None


def record(id_, typ, name, stack, account, region, taggable, tags, required, repo, path=None, line=None, identifier=None):
    tags = {str(k): str(v) for k, v in (tags or {}).items() if v is not None}
    return {
        "id": id_, "type": typ, "name": name, "stack": stack, "account": account, "region": region,
        "identifier": identifier, "taggable": taggable, "tags": tags,
        "tag_violations": [k for k in required if k not in tags] if taggable else [],
        "source": {"repo": repo, "path": path, "line": line},
    }


# --- OpenTofu plan JSON ------------------------------------------------------

def tofu_regions(plan):
    out = {}
    for key, cfg in (plan.get("configuration") or {}).get("provider_config", {}).items():
        region = ((cfg.get("expressions") or {}).get("region") or {}).get("constant_value")
        out[cfg.get("name", key)] = region
        out[key] = region
    return out


def tofu_resources(plan, stack, account, required, repo):
    regions = tofu_regions(plan)

    def walk(module):
        for r in module.get("resources", []):
            if r.get("mode") != "managed":
                continue
            values = r.get("values") or {}
            tags = {}
            for attr in TOFU_TAG_ATTRS:
                if values.get(attr):
                    tags = values[attr]
                    break
            taggable = any(attr in values for attr in TOFU_TAG_ATTRS)
            provider = (r.get("provider_name") or "").rsplit("/", 1)[-1]
            yield record(r["address"], r["type"], r["name"], stack, account, regions.get(provider),
                         taggable, tags, required, repo, identifier=identifier_from(values, TOFU_IDENTIFIER_ATTRS))
        for child in module.get("child_modules", []):
            yield from walk(child)

    yield from walk((plan.get("planned_values") or {}).get("root_module", {}))


def load_tofu(root, account, required, repo):
    found = 0
    for path in sorted(Path(root).rglob("*.json")):
        try:
            with open(path) as f:
                plan = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(plan, dict) or "planned_values" not in plan:
            continue
        found += 1
        stack = path.parent.relative_to(root).as_posix()
        stack = "." if stack == "" else stack
        yield from tofu_resources(plan, stack, account, required, repo)
    if not found:
        warn(f"no plan JSON with planned_values found under {root}")


# --- CDK / CloudFormation templates -----------------------------------------

def load_cdk(root, account, required, repo):
    found = 0
    for path in sorted(Path(root).rglob("*.template.json")):
        with open(path) as f:
            template = json.load(f)
        resources = template.get("Resources")
        if not isinstance(resources, dict):
            continue
        found += 1
        stack = path.name[: -len(".template.json")]
        for logical_id, res in resources.items():
            typ = res.get("Type", "")
            if typ in CFN_SKIP:
                continue
            props = res.get("Properties") or {}
            raw = props.get("Tags")
            tags = {t["Key"]: t["Value"] for t in raw if isinstance(t, dict) and "Key" in t} if isinstance(raw, list) else {}
            taggable = typ in CFN_TAGGABLE or raw is not None
            yield record(logical_id, typ, logical_id, stack, account, None, taggable, tags, required, repo,
                         path=(res.get("Metadata") or {}).get("aws:cdk:path"),
                         identifier=identifier_from(props, CFN_IDENTIFIER_PROPS))
    if not found:
        warn(f"no plan or template JSON found under {root}")


# --- grouping and renderers --------------------------------------------------

def grouped(resources):
    """{project: {environment: {owner: [resource]}}} with "(none)" for missing tags."""
    tree = {}
    for r in resources:
        p = r["tags"].get("project", "(none)")
        e = r["tags"].get("environment", "(none)")
        o = r["tags"].get("owner", "(none)")
        tree.setdefault(p, {}).setdefault(e, {}).setdefault(o, []).append(r)
    return tree


def dot_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def render_dot(resources):
    lines = ["digraph inventory {",
             '  graph [rankdir=LR, fontname="Helvetica", fontsize=11, style="rounded", color="#999999"];',
             '  node [shape=box, style="filled,rounded", fontname="Helvetica", fontsize=10, color="#999999"];']
    n = 0
    for project, envs in sorted(grouped(resources).items()):
        n += 1
        lines.append(f'  subgraph "cluster_{n}" {{ label="project: {dot_escape(project)}";')
        for env, owners in sorted(envs.items()):
            n += 1
            lines.append(f'    subgraph "cluster_{n}" {{ label="environment: {dot_escape(env)}";')
            for owner, items in sorted(owners.items()):
                n += 1
                lines.append(f'      subgraph "cluster_{n}" {{ label="owner: {dot_escape(owner)}";')
                for r in items:
                    attrs = [f'label="{dot_escape(r["type"])}\\n{dot_escape(r["name"])}"',
                             f'fillcolor="{FILL.get(r["tags"].get("data-class"), FILL[None])}"']
                    if r["tag_violations"]:
                        attrs.append('color="red", penwidth=2')
                    lines.append(f'        "{dot_escape(r["stack"] + ":" + r["id"])}" [{", ".join(attrs)}];')
                lines.append("      }")
            lines.append("    }")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def mermaid_id(s):
    return re.sub(r"[^A-Za-z0-9_]", "_", s)


def render_mermaid(resources):
    lines = ["flowchart LR"]
    n = 0
    for project, envs in sorted(grouped(resources).items()):
        pid = f"p_{mermaid_id(project)}"
        lines.append(f'  subgraph {pid}["project: {project}"]')
        for env, owners in sorted(envs.items()):
            eid = f"{pid}_e_{mermaid_id(env)}"
            lines.append(f'    subgraph {eid}["environment: {env}"]')
            for owner, items in sorted(owners.items()):
                oid = f"{eid}_o_{mermaid_id(owner)}"
                lines.append(f'      subgraph {oid}["owner: {owner}"]')
                for r in items:
                    n += 1
                    cls = "violation" if r["tag_violations"] else (r["tags"].get("data-class") or "unclassified")
                    lines.append(f'        n{n}["{r["type"]}<br/>{r["name"]}"]:::{cls}')
                lines.append("      end")
            lines.append("    end")
        lines.append("  end")
    for cls, fill in FILL.items():
        lines.append(f"  classDef {cls or 'unclassified'} fill:{fill},stroke:#999999")
    lines.append("  classDef violation fill:#ffffff,stroke:#ff0000,stroke-width:2px")
    return "\n".join(lines) + "\n"


# --- diff and report ---------------------------------------------------------

def diff_against(base, resources):
    key = lambda r: f'{r["stack"]}:{r["id"]}'  # noqa: E731
    before = {key(r): r for r in base.get("resources", [])}
    after = {key(r): r for r in resources}
    added = [after[k]["id"] for k in after if k not in before]
    removed = [before[k]["id"] for k in before if k not in after]
    retagged = []
    for k in after:
        if k not in before:
            continue
        b, a = before[k]["tags"], after[k]["tags"]
        for tag in sorted(set(b) | set(a)):
            if b.get(tag) != a.get(tag):
                retagged.append({"id": after[k]["id"], "key": tag, "before": b.get(tag), "after": a.get(tag)})
    return {"base_generated_at": base.get("generated_at"), "added": added, "removed": removed, "retagged": retagged}


def code(v):
    return f"`{v}`" if v is not None else ""


def render_report(inv, mermaid, max_nodes):
    res = inv["resources"]
    violations = [r for r in res if r["tag_violations"]]
    lines = ["<!-- asset-inventory -->",
             f"## Asset inventory: {len(res)} resources, {len(violations)} with missing tags", ""]
    stacks = {}
    for r in res:
        s = stacks.setdefault(r["stack"], [0, 0])
        s[0] += 1
        s[1] += 1 if r["tag_violations"] else 0
    lines += ["| Stack | Resources | Missing tags |", "|---|---|---|"]
    lines += [f"| `{s}` | {c[0]} | {c[1]} |" for s, c in sorted(stacks.items())]
    if violations:
        lines += ["", "### Resources missing required tags", "", "| Resource | Stack | Missing | Owner |", "|---|---|---|---|"]
        lines += [f'| `{r["id"]}` | `{r["stack"]}` | {", ".join(r["tag_violations"])} | {r["tags"].get("owner", "")} |'
                  for r in violations]
    d = inv.get("diff")
    if d:
        lines += ["", f"### Changes since the published inventory ({d['base_generated_at'] or 'unknown date'})", "",
                  f"Added {len(d['added'])}, removed {len(d['removed'])}, retagged {len(d['retagged'])}."]
        if d["added"]:
            lines += ["", "**Added:** " + ", ".join(f"`{i}`" for i in d["added"])]
        if d["removed"]:
            lines += ["", "**Removed:** " + ", ".join(f"`{i}`" for i in d["removed"])]
        if d["retagged"]:
            lines += ["", "| Resource | Tag | Before | After |", "|---|---|---|---|"]
            for t in d["retagged"]:
                after = f"**{code(t['after'])}**" if t["key"] == "owner" else code(t["after"])
                lines.append(f"| `{t['id']}` | {t['key']} | {code(t['before'])} | {after} |")
    lines += ["", "### Diagram", ""]
    if len(res) <= max_nodes:
        lines += ["```mermaid", mermaid.rstrip("\n"), "```"]
    else:
        lines.append(f"{len(res)} resources exceed the Mermaid limit of {max_nodes}; see `inventory.svg` in the `asset-inventory` artefact.")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--required-tags", default=DEFAULT_REQUIRED)
    ap.add_argument("--account", default=None)
    ap.add_argument("--dot")
    ap.add_argument("--svg")
    ap.add_argument("--mermaid")
    ap.add_argument("--mermaid-max-nodes", type=int, default=60)
    ap.add_argument("--diff-base")
    ap.add_argument("--report")
    ap.add_argument("--now")
    args = ap.parse_args()

    if args.stack not in ("tofu", "cdk"):
        return usage_error(f"stack must be tofu or cdk, got '{args.stack}'")
    if not Path(args.input).is_dir():
        return usage_error(f"input directory {args.input} does not exist")
    required = [t.strip() for t in args.required_tags.split(",") if t.strip()]
    now = args.now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    loader = load_tofu if args.stack == "tofu" else load_cdk
    resources = sorted(loader(args.input, args.account, required, args.repo), key=lambda r: (r["stack"], r["id"]))
    violations = [r for r in resources if r["tag_violations"]]
    inv = {
        "generated_at": now, "repo": args.repo, "stack_kind": args.stack, "required_tags": required,
        "counts": {"resources": len(resources), "taggable": sum(1 for r in resources if r["taggable"]),
                   "violations": len(violations)},
        "resources": resources,
    }
    if args.diff_base:
        with open(args.diff_base) as f:
            inv["diff"] = diff_against(json.load(f), resources)

    for r in violations:
        warn(f'{r["stack"]} {r["id"]} is missing {", ".join(r["tag_violations"])}')

    with open(args.output, "w") as f:
        json.dump(inv, f, indent=1)
        f.write("\n")
    dot = render_dot(resources)
    mermaid = render_mermaid(resources)
    if args.dot:
        with open(args.dot, "w") as f:
            f.write(dot)
    if args.mermaid:
        with open(args.mermaid, "w") as f:
            f.write(mermaid)
    if args.svg:
        if shutil.which("dot"):
            subprocess.run(["dot", "-Tsvg", "-o", args.svg], input=dot, text=True, check=True)
        else:
            warn("graphviz dot not installed; SVG not rendered")
    report = render_report(inv, mermaid, args.mermaid_max_nodes)
    if args.report:
        with open(args.report, "w") as f:
            f.write(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"resource-count={len(resources)}\nviolation-count={len(violations)}\n"
                    f"added-count={len(inv.get('diff', {}).get('added', []))}\nreport-path={args.report or ''}\n")
    print(f"{TITLE}: {len(resources)} resources, {len(violations)} with missing tags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
