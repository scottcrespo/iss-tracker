#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Namespace must exist before any namespaced resources
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# 2. SecurityGroupPolicy — requires namespace and the VPC CNI SGP CRD
ARGOCD_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=iss-tracker-eks-argocd" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
export ARGOCD_SG_ID
envsubst < "${SCRIPT_DIR}/sgp-argocd.yaml" | kubectl apply -f -