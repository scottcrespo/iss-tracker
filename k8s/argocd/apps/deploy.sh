#!/bin/bash
# ---------------------------------------------------------------------------
# ArgoCD Application deploy script
# ---------------------------------------------------------------------------
#
# Reads sensitive Helm parameters from ESO-managed K8s Secrets in the argocd
# namespace and applies the Application manifest with those values injected.
# This keeps sensitive values (account ID in ECR URL, IRSA ARNs) out of Git.
#
# NOTE: This is not a production pattern.
#
# In a production GitOps setup, Application manifests live entirely in Git and
# sensitive Helm parameters are injected transparently at sync time using a
# Config Management Plugin (CMP) such as argocd-vault-plugin (AVP). AVP allows
# placeholder substitution (e.g. <path:secret#key>) directly in values.yaml or
# Application specs, so the full Application definition is declarative and
# version-controlled without exposing sensitive values.
#
# This script exists because:
#   1. This is a public repository — committing Application manifests with
#      AWS account IDs (embedded in ECR URLs and IRSA ARNs) is not acceptable.
#   2. Installing and configuring AVP as an ArgoCD CMP sidecar is out of scope
#      for this portfolio project's current iteration.
#
# The trade-off is accepted and documented. The ESO + ClusterSecretStore
# wiring is correct and production-ready — only the final injection step into
# the ArgoCD Application spec deviates from the standard pattern. AVP or an
# equivalent plugin is the path forward when this moves to production.
#
# Usage:
#   ./deploy.sh apply api
#   ./deploy.sh apply poller
#   ./deploy.sh delete api
#   ./deploy.sh delete poller
# ---------------------------------------------------------------------------
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 {apply|delete} {api|poller}"
  exit 1
}

[[ $# -ne 2 ]] && usage

ACTION=$1
APP=$2

read_secret() {
  local secret=$1 key=$2
  kubectl get secret "${secret}" -n argocd \
    -o jsonpath="{.data.${key}}" | base64 -d
}

apply_api() {
  local image_repo irsa_arn
  image_repo=$(read_secret api-helm-values imageRepository)
  irsa_arn=$(read_secret api-helm-values irsaRoleArn)

  echo "==> Applying ArgoCD Application: api"
  echo "    image.repository : ${image_repo}"
  echo "    irsaRoleArn      : ${irsa_arn}"

  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/scottcrespo/iss-tracker.git
    targetRevision: develop
    path: k8s/iss-tracker/helm/api
    helm:
      valueFiles:
        - values.yaml
      parameters:
      - name: image.repository
        value: "${image_repo}"
      - name: serviceAccount.annotations.eks\.amazonaws\.com/role-arn
        value: "${irsa_arn}"
  destination:
    server: https://kubernetes.default.svc
    namespace: iss-tracker
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

apply_poller() {
  local image_repo irsa_arn
  image_repo=$(read_secret poller-helm-values imageRepository)
  irsa_arn=$(read_secret poller-helm-values irsaRoleArn)

  echo "==> Applying ArgoCD Application: poller"
  echo "    image.repository : ${image_repo}"
  echo "    irsaRoleArn      : ${irsa_arn}"

  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: poller
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/scottcrespo/iss-tracker.git
    targetRevision: develop
    path: k8s/iss-tracker/helm/poller
    helm:
      valueFiles:
        - values.yaml
      parameters:
      - name: jobs.iss-tracker-poller.image.repository
        value: "${image_repo}"
      - name: jobs.iss-tracker-poller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn
        value: "${irsa_arn}"
  destination:
    server: https://kubernetes.default.svc
    namespace: iss-tracker
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

case "${ACTION}" in
  apply)
    case "${APP}" in
      api)    apply_api ;;
      poller) apply_poller ;;
      *)      usage ;;
    esac
    ;;
  delete)
    echo "==> Deleting ArgoCD Application: ${APP}"
    kubectl delete application "${APP}" -n argocd
    ;;
  *)
    usage
    ;;
esac