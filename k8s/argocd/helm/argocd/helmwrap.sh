#!/bin/bash
set -e

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="argocd"
NAMESPACE="argocd"
CHART="argo/argo-cd"
VERSION="9.5.4"

usage() {
  echo "Usage: $0 {install|upgrade|uninstall}"
  exit 1
}

[[ $# -ne 1 ]] && usage

ensure_repo() {
  if ! helm repo list 2>/dev/null | grep -q '^argo\s'; then
    echo "==> Adding argo helm repo"
    helm repo add argo https://argoproj.github.io/argo-helm
  fi
  helm repo update argo
}

case "$1" in
  install)
    ensure_repo
    echo "==> helm install ${RELEASE} (chart ${CHART} v${VERSION})"
    helm install "${RELEASE}" "${CHART}" \
      --version "${VERSION}" \
      -n "${NAMESPACE}" \
      -f "${CHART_DIR}/values.yaml"
    echo "==> Release status"
    helm status "${RELEASE}" -n "${NAMESPACE}"
    echo ""
    echo "Retrieve initial admin password:"
    echo "  kubectl get secret argocd-initial-admin-secret -n argocd \\"
    echo "    -o jsonpath='{.data.password}' | base64 -d && echo"
    ;;
  upgrade)
    ensure_repo
    echo "==> helm upgrade ${RELEASE} (chart ${CHART} v${VERSION})"
    helm upgrade "${RELEASE}" "${CHART}" \
      --version "${VERSION}" \
      -n "${NAMESPACE}" \
      -f "${CHART_DIR}/values.yaml"
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
