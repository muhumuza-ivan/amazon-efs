#!/usr/bin/env bash
#
# Static validation of the CloudFormation templates.
#
# Runs cfn-lint if it is installed (pip install cfn-lint) and always runs the
# server-side validator, which catches anything cfn-lint's local schema misses.
#
# Usage: scripts/validate.sh [region]

set -euo pipefail

# Git Bash rewrites arguments that look like Unix paths. Ignored on Linux/macOS.
export MSYS_NO_PATHCONV=1

REGION="${1:-${AWS_REGION:-eu-west-1}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES=("$ROOT"/templates/*.yaml)

failed=0

# Git Bash hands out POSIX paths (/c/Users/...) that Windows-native tools - both
# the AWS CLI and cfn-lint - cannot open. Convert when cygpath is present;
# elsewhere this is a no-op.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

NATIVE_TEMPLATES=()
for template in "${TEMPLATES[@]}"; do
  NATIVE_TEMPLATES+=("$(native_path "$template")")
done

echo "==> cfn-lint"
if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint "${NATIVE_TEMPLATES[@]}" --region "$REGION" || failed=1
else
  echo "    cfn-lint not installed, skipping (pip install cfn-lint)"
fi

echo
echo "==> aws cloudformation validate-template (region: $REGION)"
for template in "${TEMPLATES[@]}"; do
  body="file://$(native_path "$template")"
  printf '    %-24s ' "$(basename "$template")"
  if aws cloudformation validate-template \
      --region "$REGION" \
      --template-body "$body" \
      --output text --query 'Description' >/dev/null 2>&1; then
    echo "ok"
  else
    echo "FAILED"
    aws cloudformation validate-template \
      --region "$REGION" \
      --template-body "$body" >/dev/null || true
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
