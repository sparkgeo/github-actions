#!/usr/bin/env python3
"""Flag IAM roles shared by more than one function in CloudFormation, SAM or
CDK JSON templates (issue #183, plan Step 17 Standard: one least-privilege
role per function).

Usage: serverless-roles.py --template FILE_OR_DIR [--template ...] [--fail]

Reads every *.json under the given paths that has a top-level "Resources"
map, collects AWS::Lambda::Function and AWS::Serverless::Function resources
and the role each references (Ref, Fn::GetAtt, or a literal ARN), and reports
any role used by two or more functions as one error annotation per role. YAML
templates are skipped with a notice: the runner's Python has no YAML parser
and CloudFormation YAML needs the intrinsic tags; run `sam build` or
`cdk synth` and point at the JSON output. Exit 1 with --fail when a shared
role exists. Standard library only; run with python3 -I.
"""

import argparse
import json
import os
import sys

FUNCTION_TYPES = {"AWS::Lambda::Function", "AWS::Serverless::Function"}


def role_key(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if "Ref" in value:
            return str(value["Ref"])
        if "Fn::GetAtt" in value:
            att = value["Fn::GetAtt"]
            return att[0] if isinstance(att, list) and att else str(att)
        if "Fn::Sub" in value:
            return f'Sub({value["Fn::Sub"]})'
    return json.dumps(value, sort_keys=True)


def templates(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in sorted(files):
                    yield os.path.join(root, f)
        else:
            yield p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", action="append", required=True)
    ap.add_argument("--fail", action="store_true")
    args = ap.parse_args()

    shared_total, functions_seen, skipped = 0, 0, []
    for path in templates(args.template):
        if path.endswith((".yaml", ".yml")):
            skipped.append(path)
            continue
        if not path.endswith(".json"):
            continue
        try:
            with open(path) as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        resources = doc.get("Resources") if isinstance(doc, dict) else None
        if not isinstance(resources, dict):
            continue
        by_role = {}
        for logical_id, res in resources.items():
            if not isinstance(res, dict) or res.get("Type") not in FUNCTION_TYPES:
                continue
            functions_seen += 1
            role = (res.get("Properties") or {}).get("Role")
            if role is None:
                print(f"::warning file={path},title=serverless-roles::{logical_id} declares no Role; SAM will create one per function, CDK and raw CloudFormation will not deploy")
                continue
            by_role.setdefault(role_key(role), []).append(logical_id)
        for role, fns in sorted(by_role.items()):
            if len(fns) > 1:
                shared_total += 1
                print(f'::error file={path},title=serverless-roles SPK_SLS_1::role {role} is shared by {len(fns)} functions ({", ".join(fns)}); give each function its own least-privilege role')
    for path in skipped:
        print(f"::notice file={path},title=serverless-roles::YAML template skipped; point template-path at the JSON output of sam build or cdk synth for the shared-role check")
    print(f"serverless-roles: {functions_seen} functions, {shared_total} shared role(s), {len(skipped)} YAML template(s) skipped")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"shared-roles={shared_total}\nfunctions={functions_seen}\n")
    return 1 if (args.fail and shared_total) else 0


if __name__ == "__main__":
    sys.exit(main())
