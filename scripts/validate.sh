#!/usr/bin/env bash
#
# Static validation of the CloudFormation templates.
#
# Runs cfn-lint if it is installed (pip install cfn-lint) and always runs the
# server-side validator, which catches anything cfn-lint's local schema misses.
#
# Usage: scripts/validate.sh [region]

set -euo pipefail

REGION="${1:-${AWS_REGION:-eu-west-1}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES=("$ROOT"/templates/*.yaml)

failed=0

echo "==> cfn-lint"
if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint "${TEMPLATES[@]}" --region "$REGION" || failed=1
else
  echo "    cfn-lint not installed, skipping (pip install cfn-lint)"
fi

echo
echo "==> aws cloudformation validate-template (region: $REGION)"
for template in "${TEMPLATES[@]}"; do
  printf '    %-24s ' "$(basename "$template")"
  if aws cloudformation validate-template \
      --region "$REGION" \
      --template-body "file://$template" \
      --output text --query 'Description' >/dev/null 2>&1; then
    echo "ok"
  else
    echo "FAILED"
    aws cloudformation validate-template \
      --region "$REGION" \
      --template-body "file://$template" >/dev/null || true
    failed=1
  fi
done

echo
if [[ "$failed" -eq 0 ]]; then
  echo "All templates validated."
else
  echo "Validation reported problems." >&2
fi
exit "$failed"
