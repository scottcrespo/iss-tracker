#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Namespace must exist before any namespaced resources
kubectl apply -f "${SCRIPT_DIR}/ns-iss-tracker.yaml"

# 2. SecurityGroupPolicy — requires namespace and the VPC CNI SGP CRD
FARGATE_PRIVATE_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=iss-tracker-eks-iss-tracker" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
export FARGATE_PRIVATE_SG_ID
envsubst < "${SCRIPT_DIR}/sgp-iss-tracker.yaml" | kubectl apply -f -