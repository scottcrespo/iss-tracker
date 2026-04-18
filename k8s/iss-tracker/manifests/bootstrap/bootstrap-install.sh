#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../../../../terraform/environments/dev/us-east-2/eks"

# 1. Namespace must exist before any namespaced resources
kubectl apply -f "${SCRIPT_DIR}/ns-iss-tracker.yaml"

# 2. SecurityGroupPolicy — requires namespace and the VPC CNI SGP CRD
FARGATE_PRIVATE_SG_ID=$(terraform -chdir="${TF_DIR}" output -raw fargate_private_sg_id)
export FARGATE_PRIVATE_SG_ID
envsubst < "${SCRIPT_DIR}/sgp-iss-tracker.yaml" | kubectl apply -f -