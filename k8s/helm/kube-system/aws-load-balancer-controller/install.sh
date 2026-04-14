#!/bin/bash
set -e
# install script for aws load balancer to prevent sensitive strings from being in public repository
# this must be run from the same directory where the values.yaml file is located. 
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  -f ./values.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(aws iam get-role --role-name iss-tracker-eks-lb-controller --query Role.Arn --output text) \
  --set vpcId=$(aws eks describe-cluster --name iss-tracker-eks --query cluster.resourcesVpcConfig.vpcId --output text)
