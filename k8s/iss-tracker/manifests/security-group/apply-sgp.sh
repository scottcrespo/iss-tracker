#!/bin/bash
set -e

export FARGATE_PRIVATE_SG_ID=$(terraform -chdir=../../../../terraform/environments/dev/us-east-2/eks output -raw fargate_private_sg_id)

envsubst < sgp-iss-tracker.yaml | kubectl apply -f -