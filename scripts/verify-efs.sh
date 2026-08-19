#!/usr/bin/env bash
#
# End-to-end proof that the architecture meets the brief. Every check runs
# through Systems Manager - there is no SSH path, by design.
#
#   1. instances carry no public IP address
#   2. the VPC contains no internet gateway and no NAT gateway
#   3. every instance is registered and Online in Systems Manager
#   4. the shared file system is mounted, over TLS
#   5. a file written on one instance is readable from every other instance
#
# Usage: scripts/verify-efs.sh [project-name] [region]
#   defaults: efs-shared, $AWS_REGION or eu-west-1

set -euo pipefail

# Git Bash rewrites arguments that look like Unix paths, which would corrupt the
# /mnt/efs paths inside the SSM command strings below. Ignored on Linux/macOS.
export MSYS_NO_PATHCONV=1

PROJECT="${1:-efs-shared}"
REGION="${2:-${AWS_REGION:-eu-west-1}}"
ASG="${PROJECT}-asg"
MOUNT_POINT="/mnt/efs"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILURES=0

# Run a shell snippet on one instance via SSM and echo its stdout.
run_on() {
  local instance="$1" script="$2" command_id
  command_id=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$instance" \
    --document-name AWS-RunShellScript \
    --comment "efs verification" \
    --parameters "commands=[\"$script\"]" \
    --query 'Command.CommandId' --output text)

  aws ssm wait command-executed \
    --region "$REGION" \
    --command-id "$command_id" \
    --instance-id "$instance" >/dev/null 2>&1 || true

  aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$command_id" \
    --instance-id "$instance" \
    --query 'StandardOutputContent' --output text
}

section "Auto Scaling group: $ASG (region $REGION)"

INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
  --output text)

if [[ -z "$INSTANCE_IDS" ]]; then
  echo "No InService instances found in $ASG. Is the compute stack deployed?" >&2
  exit 1
fi

# shellcheck disable=SC2206
INSTANCES=($INSTANCE_IDS)
echo "  instances: ${INSTANCES[*]}"

aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]' \
  --output text | while read -r min desired max; do
    echo "  capacity:  min=$min desired=$desired max=$max"
  done

AZS=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "${INSTANCES[@]}" \
  --query 'Reservations[].Instances[].Placement.AvailabilityZone' \
  --output text | tr '\t' '\n' | sort -u | tr '\n' ' ')
echo "  zones:     $AZS"

section "1. No public exposure"

PUBLIC_IPS=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "${INSTANCES[@]}" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)
if [[ -z "$PUBLIC_IPS" || "$PUBLIC_IPS" == "None" ]]; then
  pass "no instance has a public IP address"
else
  fail "public IP addresses found: $PUBLIC_IPS"
fi

VPC_ID=$(aws ec2 describe-instances --region "$REGION" \
  --instance-ids "${INSTANCES[0]}" \
  --query 'Reservations[0].Instances[0].VpcId' --output text)

IGW_COUNT=$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'length(InternetGateways)' --output text)
NAT_COUNT=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'length(NatGateways[?State!=`deleted`])' --output text)

[[ "$IGW_COUNT" == "0" ]] && pass "VPC $VPC_ID has no internet gateway" \
                          || fail "VPC $VPC_ID has $IGW_COUNT internet gateway(s)"
[[ "$NAT_COUNT" == "0" ]] && pass "VPC $VPC_ID has no NAT gateway" \
                          || fail "VPC $VPC_ID has $NAT_COUNT NAT gateway(s)"

section "2. Systems Manager reachability"

for instance in "${INSTANCES[@]}"; do
  status=$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$instance" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  [[ "$status" == "Online" ]] && pass "$instance is Online in SSM" \
                              || fail "$instance SSM ping status: $status"
done

section "3. Shared file system is mounted"

for instance in "${INSTANCES[@]}"; do
  out=$(run_on "$instance" "findmnt -no FSTYPE,SOURCE $MOUNT_POINT || echo NOTMOUNTED")
  if [[ "$out" == *NOTMOUNTED* || -z "$out" ]]; then
    fail "$instance: $MOUNT_POINT is not mounted"
  else
    pass "$instance: $MOUNT_POINT mounted ($(echo "$out" | tr -s ' '))"
  fi
done

section "4. Read/write and cross-instance consistency"

WRITER="${INSTANCES[0]}"
MARKER="verify-$(date -u +%Y%m%d-%H%M%S)"
PAYLOAD="written by $WRITER"

run_on "$WRITER" "echo '$PAYLOAD' > $MOUNT_POINT/$MARKER.txt && sync" >/dev/null
pass "$WRITER wrote $MOUNT_POINT/$MARKER.txt"

for instance in "${INSTANCES[@]}"; do
  [[ "$instance" == "$WRITER" ]] && continue
  out=$(run_on "$instance" "cat $MOUNT_POINT/$MARKER.txt 2>/dev/null || echo MISSING")
  if [[ "$out" == *"$PAYLOAD"* ]]; then
    pass "$instance read the file written by $WRITER"
  else
    fail "$instance could not read $MARKER.txt (got: $out)"
  fi
done

# Each instance drops a marker at boot; every instance should see all of them.
EXPECTED="${#INSTANCES[@]}"
for instance in "${INSTANCES[@]}"; do
  count=$(run_on "$instance" "ls -1 $MOUNT_POINT/hosts | wc -l")
  count=$(echo "$count" | tr -d '[:space:]')
  if [[ "$count" == "$EXPECTED" ]]; then
    pass "$instance sees all $EXPECTED boot markers in $MOUNT_POINT/hosts"
  else
    fail "$instance sees $count boot markers, expected $EXPECTED"
  fi
done

# Prove the writer sees the reader's write too, not just the other direction.
READER="${INSTANCES[1]:-}"
if [[ -n "$READER" ]]; then
  run_on "$READER" "echo 'reply from $READER' >> $MOUNT_POINT/$MARKER.txt && sync" >/dev/null
  out=$(run_on "$WRITER" "cat $MOUNT_POINT/$MARKER.txt")
  if [[ "$out" == *"reply from $READER"* ]]; then
    pass "$WRITER sees the append made by $READER (bidirectional)"
  else
    fail "$WRITER did not see $READER's append"
  fi
fi

run_on "$WRITER" "rm -f $MOUNT_POINT/$MARKER.txt" >/dev/null

section "Result"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "  All checks passed."
else
  echo "  $FAILURES check(s) failed." >&2
fi
exit "$FAILURES"
