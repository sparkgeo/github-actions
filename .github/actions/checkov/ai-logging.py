#!/usr/bin/env python3
"""SPK_AI_1: Bedrock model invocation logging is declared wherever Bedrock
resources are (issue #189, plan Step 17 Standard: "invocation logging on").

Usage: ai-logging.py --directory DIR [--fail]

Scans *.tf and *.tf.json under the directory. When any file declares a
Bedrock agent, custom model, inference profile or provisioned throughput and
no file declares aws_bedrock_model_invocation_logging_configuration, emits one
error per Bedrock resource. CloudFormation templates get a notice: invocation
logging is an account setting with no CloudFormation resource, so it is
verified by the scheduled posture scan instead. A checkov graph policy cannot
express "resource B exists when resource A exists", hence this script.
Exit 1 with --fail when the error fires. Standard library only; run with
python3 -I.
"""

import argparse
import json
import os
import re
import sys

BEDROCK_RE = re.compile(r'^\s*resource\s+"(aws_bedrockagent_agent|aws_bedrock_custom_model|aws_bedrock_inference_profile|aws_bedrock_provisioned_model_throughput)"\s+"([^"]+)"', re.M)
LOGGING_TYPE = "aws_bedrock_model_invocation_logging_configuration"
LOGGING_RE = re.compile(r'^\s*resource\s+"' + LOGGING_TYPE + r'"', re.M)
CFN_BEDROCK = ("AWS::Bedrock::Agent", "AWS::Bedrock::Guardrail", "AWS::Bedrock::KnowledgeBase")


def tf_json_resources(doc):
    out, logging = [], False
    for typ, items in (doc.get("resource") or {}).items():
        if typ == LOGGING_TYPE:
            logging = True
        elif typ.startswith("aws_bedrock"):
            out += [(typ, name) for name in (items or {})]
    return out, logging


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--directory", required=True)
    ap.add_argument("--fail", action="store_true")
    args = ap.parse_args()

    bedrock, logging_seen, cfn_notices = [], False, []
    for root, dirs, files in os.walk(args.directory):
        dirs[:] = [d for d in dirs if d not in (".terraform", ".git", "node_modules")]
        for name in sorted(files):
            path = os.path.join(root, name)
            try:
                if name.endswith(".tf"):
                    text = open(path).read()
                    bedrock += [(path, f"{m.group(1)}.{m.group(2)}") for m in BEDROCK_RE.finditer(text)]
                    logging_seen |= bool(LOGGING_RE.search(text))
                elif name.endswith(".tf.json"):
                    res, has_logging = tf_json_resources(json.load(open(path)))
                    bedrock += [(path, f"{t}.{n}") for t, n in res]
                    logging_seen |= has_logging
                elif name.endswith((".json", ".yaml", ".yml", ".template")):
                    text = open(path, errors="replace").read()
                    if any(t in text for t in CFN_BEDROCK):
                        cfn_notices.append(path)
            except (OSError, ValueError):
                continue

    failed = bool(bedrock) and not logging_seen
    if failed:
        for path, addr in bedrock:
            print(f"::error file={path},title=checkov SPK_AI_1::{addr} is declared but no {LOGGING_TYPE} is; turn on model invocation logging to CloudWatch or S3 in the same configuration")
    for path in cfn_notices:
        print(f"::notice file={path},title=checkov SPK_AI_1::Bedrock resources in a CloudFormation template: invocation logging is an account setting with no CloudFormation resource; the scheduled posture scan (cspm-scan.yml, ai-services) verifies it")
    print(f"ai-logging: {len(bedrock)} Bedrock resource(s), invocation logging {'declared' if logging_seen else 'not declared'}, {len(cfn_notices)} CloudFormation template(s) noted")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"bedrock-resources={len(bedrock)}\ninvocation-logging={'true' if logging_seen else 'false'}\n")
    return 1 if (failed and args.fail) else 0


if __name__ == "__main__":
    sys.exit(main())
