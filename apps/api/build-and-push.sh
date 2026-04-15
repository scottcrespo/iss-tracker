#!/bin/bash
set -euo pipefail

REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
REPO="iss-tracker-api"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Authenticating to ECR..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "Building ${REPO}..."
docker build -t "${REGISTRY}/${REPO}:latest" "${SCRIPT_DIR}"

echo "Pushing ${REPO}..."
docker push "${REGISTRY}/${REPO}:latest"

echo "Done: ${REGISTRY}/${REPO}:latest"