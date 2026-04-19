#!/bin/bash
set -e

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="api"
NAMESPACE="iss-tracker"

usage() {
  echo "Usage: $0 {install|upgrade|uninstall}"
  exit 1
}

[[ $# -ne 1 ]] && usage

inject_values() {
  local account_id region registry role_arn
  account_id=$(aws sts get-caller-identity --query Account --output text)
  region=$(aws configure get region)
  registry="${account_id}.dkr.ecr.${region}.amazonaws.com"
  role_arn=$(aws iam get-role --role-name iss-tracker-eks-api --query Role.Arn --output text)

  echo "  image.repository : ${registry}/iss-tracker-api"
  echo "  role-arn         : ${role_arn}"

  INJECT=(
    --set "image.repository=${registry}/iss-tracker-api"
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${role_arn}"
  )
}

case "$1" in
  install)
    echo "==> Resolving inject values..."
    inject_values
    echo "==> helm install ${RELEASE}"
    helm install "${RELEASE}" "${CHART_DIR}" \
      -n "${NAMESPACE}" \
      -f "${CHART_DIR}/values.yaml" \
      "${INJECT[@]}"
    echo "==> Release status"
    helm status "${RELEASE}" -n "${NAMESPACE}"
    ;;
  upgrade)
    echo "==> Resolving inject values..."
    inject_values
    echo "==> helm upgrade ${RELEASE}"
    helm upgrade "${RELEASE}" "${CHART_DIR}" \
      -n "${NAMESPACE}" \
      -f "${CHART_DIR}/values.yaml" \
      "${INJECT[@]}"
    echo "==> Release status"
    helm status "${RELEASE}" -n "${NAMESPACE}"
    ;;
  uninstall)
    echo "==> helm uninstall ${RELEASE}"
    helm uninstall "${RELEASE}" -n "${NAMESPACE}"
    ;;
  *)
    usage
    ;;
esac