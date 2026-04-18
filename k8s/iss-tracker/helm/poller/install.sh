#!/bin/bash
set -e
# install script for poller to prevent sensitive strings from being in public repository
# this must be run from the same directory where the values.yaml file is located. 
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"

helm install poller . \
  -n iss-tracker \
  -f ./values.yaml \
  --set "jobs.iss-tracker-poller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(aws iam get-role --role-name iss-tracker-eks-poller --query Role.Arn --output text)" \
  --set "jobs.iss-tracker-poller.image.repository=${REGISTRY}/iss-tracker-poller"

