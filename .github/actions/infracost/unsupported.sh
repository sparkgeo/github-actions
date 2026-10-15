#!/usr/bin/env bash
# Markdown table of the resource types Infracost did not estimate (issue #90).
# Usage: unsupported.sh <infracost.json>  (breakdown or diff output)
# CloudFormation coverage in Infracost is narrower than Terraform's, so the
# CDK cost diff lists what it could not price instead of implying a full total.
set -euo pipefail
echo "### Resources Infracost did not estimate"
echo
jq -r '[.projects[].summary.unsupportedResourceCounts // {} | to_entries[]]
  | group_by(.key) | map({type: .[0].key, count: (map(.value) | add)})
  | if length == 0 then "None: every resource type is priced or free."
    else (["| Resource type | Count |", "|---|---|"] + map("| `\(.type)` | \(.count) |")) | join("\n") end' "$1"
