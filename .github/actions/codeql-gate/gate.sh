#!/usr/bin/env bash
# CodeQL gate. Inputs via env: SARIF_DIR (directory of *.sarif written by
# github/codeql-action/analyze, one per language), FAIL_ON
# (critical|high|medium|low|none). Writes per-severity counts and
# max-severity to GITHUB_OUTPUT, a table to GITHUB_STEP_SUMMARY, and one
# inline annotation per result.
#
# Severity comes from the rule's `security-severity` property (a CVSS-like
# score CodeQL attaches to security queries) mapped per docs/gate-policy.md:
# critical >= 9.0, high >= 7.0, medium >= 4.0, low > 0. Results from rules
# without that property (code-quality queries) are reported as `info` and
# never block.
set -euo pipefail

case "${FAIL_ON}" in
  critical) THRESH=9.0 ;;
  high)     THRESH=7.0 ;;
  medium|moderate) THRESH=4.0 ;;
  low)      THRESH=0.1 ;;
  none)     THRESH="" ;;
  *) echo "::error title=codeql::invalid fail-on-severity '${FAIL_ON}' (critical|high|medium|low|none)"; exit 1 ;;
esac

shopt -s nullglob
files=("${SARIF_DIR}"/*.sarif)
if [ "${#files[@]}" -eq 0 ]; then
  echo "::warning title=codeql::no SARIF files found under ${SARIF_DIR}"
  { echo "critical-count=0"; echo "high-count=0"; echo "medium-count=0"; echo "low-count=0"; echo "info-count=0"; echo "max-severity=none"; } >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# One row per result: score \t file \t line \t ruleId \t message \t language
ROWS="$(jq -r '
  .runs[] as $run
  | ($run.automationDetails.id // "" | capture("language:(?<l>[^/]+)")? .l // "unknown") as $lang
  | $run.tool.driver.rules as $rules
  | ($run.results // [])[]
  | (.ruleId // .rule.id) as $rid
  | (if (.ruleIndex // .rule.index) != null then $rules[(.ruleIndex // .rule.index)]
     else (($rules // []) | map(select(.id == $rid)) | .[0]) end) as $rule
  | ($rule.properties["security-severity"] // "-") as $score   # "-" keeps the column; a leading empty tab field would be dropped by read
  | (.locations[0].physicalLocation.artifactLocation.uri // "") as $file
  | (.locations[0].physicalLocation.region.startLine // 0) as $line
  | "\($score)\t\($file)\t\($line)\t\($rid)\t\(.message.text | gsub("\n"; " "))\t\($lang)"
' "${files[@]}")"

CRIT=0; HIGH=0; MED=0; LOW=0; INFO=0; MAXSCORE=0
while IFS=$'\t' read -r score file line rid message lang; do
  [ -n "${rid:-}" ] || continue
  if [ "${score}" != "-" ]; then
    if   awk "BEGIN{exit !(${score} >= 9.0)}"; then sev=critical; CRIT=$((CRIT+1)); kind=error
    elif awk "BEGIN{exit !(${score} >= 7.0)}"; then sev=high;     HIGH=$((HIGH+1)); kind=error
    elif awk "BEGIN{exit !(${score} >= 4.0)}"; then sev=medium;   MED=$((MED+1));   kind=warning
    else sev=low; LOW=$((LOW+1)); kind=notice; fi
    if awk "BEGIN{exit !(${score} > ${MAXSCORE})}"; then MAXSCORE="${score}"; fi
  else
    sev=info; INFO=$((INFO+1)); kind=notice
  fi
  if [ -n "${file}" ]; then
    echo "::${kind} file=${file},line=${line},title=codeql ${sev} ${rid}::${message:0:300} [${lang}]"
  else
    echo "::${kind} title=codeql ${sev} ${rid}::${message:0:300} [${lang}]"
  fi
done <<< "${ROWS}"

if   [ "${CRIT}" -gt 0 ]; then MAX=critical
elif [ "${HIGH}" -gt 0 ]; then MAX=high
elif [ "${MED}"  -gt 0 ]; then MAX=medium
elif [ "${LOW}"  -gt 0 ]; then MAX=low
else MAX=none; fi

{
  echo "## CodeQL"
  echo
  echo "| Severity | Count |"
  echo "|---|---|"
  echo "| critical (≥ 9.0) | ${CRIT} |"
  echo "| high (≥ 7.0) | ${HIGH} |"
  echo "| medium (≥ 4.0) | ${MED} |"
  echo "| low | ${LOW} |"
  echo "| quality (no security score) | ${INFO} |"
  echo
  echo "SARIF files: ${#files[@]}. Gate: \`fail-on-severity: ${FAIL_ON}\`; highest security score: \`${MAXSCORE}\` (\`${MAX}\`)."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

{
  echo "critical-count=${CRIT}"
  echo "high-count=${HIGH}"
  echo "medium-count=${MED}"
  echo "low-count=${LOW}"
  echo "info-count=${INFO}"
  echo "max-severity=${MAX}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "codeql: critical ${CRIT}, high ${HIGH}, medium ${MED}, low ${LOW}, quality ${INFO}; threshold '${FAIL_ON}'"

if [ -n "${THRESH}" ] && awk "BEGIN{exit !(${MAXSCORE} >= ${THRESH})}"; then
  echo "::error title=codeql::security findings at or above '${FAIL_ON}' severity (max score ${MAXSCORE})."
  exit 1
fi
