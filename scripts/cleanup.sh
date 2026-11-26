#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

export AWS_PROFILE=devops-admin
export AWS_REGION=eu-west-1
export AWS_DEFAULT_REGION=eu-west-1
export AWS_PAGER=""

STATE_FILE=".aws-resources.env"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No local resource state file found."
    exit 1
fi

source "$STATE_FILE"

echo "===== RESOURCES MARKED FOR CLEANUP ====="

echo "Instance: ${INSTANCE_ID:-Not recorded}"
echo "Security group: ${SG_ID:-Not recorded}"
echo "Key pair: ${KEY_ID:-Not recorded}"

read -r -p "Type DESTROY to confirm cleanup: " CONFIRM

if [[ "$CONFIRM" != "DESTROY" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

if [[ -n "${INSTANCE_ID:-}" ]]; then
    echo "===== TERMINATING EC2 INSTANCE ====="

    aws ec2 terminate-instances \
        --instance-ids "$INSTANCE_ID"

    aws ec2 wait instance-terminated \
        --instance-ids "$INSTANCE_ID"
fi

if [[ -n "${SG_ID:-}" ]]; then
    echo "===== DELETING SECURITY GROUP ====="

    aws ec2 delete-security-group \
        --group-id "$SG_ID"
fi

if [[ -n "${KEY_ID:-}" ]]; then
    echo "===== DELETING AWS KEY PAIR ====="

    aws ec2 delete-key-pair \
        --key-pair-id "$KEY_ID"
fi

echo "===== REMAINING PROJECT EBS VOLUMES ====="

aws ec2 describe-volumes \
    --filters "Name=tag:Project,Values=$PROJECT" \
    --output table

echo "===== CLEANUP COMMANDS COMPLETE ====="

echo "Resource state retained for final verification."
