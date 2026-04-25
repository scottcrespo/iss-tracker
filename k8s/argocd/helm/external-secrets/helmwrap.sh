#!/bin/bash
set -e

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="external-secrets"
NAMESPACE="argocd"
CHART="external-secrets/external-secrets"
VERSION="2.4.0"

usage() {
  echo "Usage: $0 {install|upgrade|uninstall}"
  exit 1
}

[[ $# -ne 1 ]] && usage

ensure_repo() {
  if ! helm repo list 2>/dev/null | grep -q '^external-secrets\s'; then
    echo "==> Adding external-secrets helm repo"
    helm repo add external-secrets https://charts.external-secrets.io
  fi
  helm repo update external-secrets
}

case "$1" in
  install)
    ensure_repo
    echo "==> helm install ${RELEASE} (chart ${CHART} v${VERSION})"
    helm install "${RELEASE}" "${CHART}" \
      --version "${VERSION}" \
      -n "${NAMESPACE}" \
      -f "${CHART_DIR}/values.yaml" \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(aws iam get-role --role-name iss-tracker-eks-eso --query Role.Arn --output text)
    echo "==> Release status"
    helm status "${RELEASE}" -n "${NAMESPACE}"
    ;;
  upgrade)
    ensure_repo
    echo "==> helm upgrade ${RELEASE} (chart ${CHART} v${VERSION})"
    helm upgrade "${RELEASE}" "${CHART}" \
      --version "${VERSION}" \
      -n "${NAMESPACE}" \
      -f "${CHART_DIR}/values.yaml" \
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(aws iam get-role --role-name iss-tracker-eks-eso --query Role.Arn --output text)
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