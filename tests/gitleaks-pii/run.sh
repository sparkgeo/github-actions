#!/usr/bin/env bash
# Checks policies/pii/gitleaks-pii.toml with the pinned gitleaks: generated
# true positives (never committed) are reported under PII-* ids, the
# documented placeholders are not, the default secret rules still apply, and
# the composite's merge with a consuming repo's .gitleaks.toml keeps that
# repo's allowlist. Needs gitleaks (GITLEAKS, default: on PATH), python3, jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
RULES="${ROOT}/policies/pii/gitleaks-pii.toml"
GITLEAKS="${GITLEAKS:-gitleaks}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
scan() {  # <name> <config> <path>; sets rc
  set +e
  "${GITLEAKS}" dir "$3" --config "$2" --report-format json --report-path "${TMP}/$1.json" --no-banner --redact --exit-code 1 > "${TMP}/$1.log" 2>&1
  rc=$?
  set -e
  [ -s "${TMP}/$1.json" ] || echo '[]' > "${TMP}/$1.json"
}
ids() { jq -r '[.[].RuleID] | sort | unique | join(",")' "${TMP}/$1.json"; }

# True positives are generated here so no real-looking value is ever committed.
python3 - "${TMP}/positives.txt" <<'PY'
import random, sys
random.seed(98)
def luhn(prefix, length):
    while True:
        body = prefix + "".join(str(random.randint(0, 9)) for _ in range(length - len(prefix) - 1))
        total = 0
        for i, ch in enumerate(reversed(body)):
            d = int(ch)
            if i % 2 == 0:
                d = d * 2 - 9 if d * 2 > 9 else d * 2
            total += d
        check = (10 - total % 10) % 10
        n = body + str(check)
        if n not in ("4111111111111111", "4242424242424242"):
            return n
visa, mc, amex = luhn("4", 16), luhn("51", 16), luhn("37", 15)
sin = luhn("13", 9)
lines = [
    "# generated true positives",
    f"card_visa = {visa[:4]} {visa[4:8]} {visa[8:12]} {visa[12:]}",
    f"card_mc = {mc}",
    f"card_amex = {amex[:4]}-{amex[4:10]}-{amex[10:]}",
    "ssn = 536-72-1849",
    f"sin = {sin[:3]} {sin[3:6]} {sin[6:]}",
    "iban = DE75512108001245126199",
    "phone = +1 604 731 2222",
    "phone_uk = +44 20 3456 7890",
    "aws = " + "AKIA" + "Q2J7T4XB" + "ZRLM3NPZ",  # assembled so the hook never sees a key; not the AWS docs example (allowlisted by default)
]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY

echo "== positives: every PII rule fires, plus the default aws-access-token rule"
scan pos "${RULES}" "${TMP}/positives.txt"
[ "${rc}" -eq 1 ] || fail "positives rc ${rc}: $(cat "${TMP}/pos.log")"
[ "$(ids pos)" = "PII-CA_SIN,PII-CREDIT_CARD,PII-E164_PHONE,PII-IBAN_CODE,PII-US_SSN,aws-access-token" ] || fail "rule ids: $(ids pos)"
[ "$(jq -r '[.[] | select(.RuleID == "PII-CREDIT_CARD")] | length' "${TMP}/pos.json")" = "3" ] || fail "three card findings"
[ "$(jq -r '[.[] | select(.RuleID == "PII-E164_PHONE")] | length' "${TMP}/pos.json")" = "2" ] || fail "two phone findings"
[ "$(jq -r '[.[] | select(.RuleID | startswith("PII-")) | .Tags[0]] | unique | join(",")' "${TMP}/pos.json")" = "pii" ] || fail "pii tag"
[ "$(jq -r '[.[].Secret] | unique | join(",")' "${TMP}/pos.json")" = "REDACTED" ] || fail "values must be redacted in the report"

echo "== placeholders: no finding"
scan ph "${RULES}" "${HERE}/fixtures/placeholders.txt"
[ "${rc}" -eq 0 ] || fail "placeholders reported: $(jq -c '[.[] | {RuleID, Line: .StartLine}]' "${TMP}/ph.json")"

echo "== merged config: a consuming repo's .gitleaks.toml allowlist survives the merge"
mkdir -p "${TMP}/repo/tests/fixtures"
cp "${TMP}/positives.txt" "${TMP}/repo/tests/fixtures/seed.txt"
cp "${TMP}/positives.txt" "${TMP}/repo/notes.txt"
cat > "${TMP}/repo/.gitleaks.toml" <<'EOT'
[extend]
useDefault = true

[[allowlists]]
description = "synthetic fixtures"
paths = ['''tests/fixtures/''']
EOT
{ printf '[extend]\npath = "%s"\n\n' "${TMP}/repo/.gitleaks.toml"; awk '/^\[\[rules\]\]/{p=1} p' "${RULES}"; } > "${TMP}/merged.toml"
scan merged "${TMP}/merged.toml" "${TMP}/repo"
[ "${rc}" -eq 1 ] || fail "merged rc ${rc}: $(cat "${TMP}/merged.log")"
[ "$(jq -r '[.[].File] | unique | join(",")' "${TMP}/merged.json")" = "${TMP}/repo/notes.txt" ] || fail "fixture path allowlisted: $(jq -r '[.[].File] | unique' "${TMP}/merged.json")"
[ "$(jq -r '[.[] | select(.RuleID | startswith("PII-"))] | length' "${TMP}/merged.json")" = "8" ] || fail "eight PII findings in notes.txt: $(jq -c '[.[].RuleID]' "${TMP}/merged.json")"

echo "all gitleaks-pii checks passed"
