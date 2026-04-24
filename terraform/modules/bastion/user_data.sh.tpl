#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Wait for outbound network readiness before any network operation.
# EC2 first-boot race: NAT route, DNS, and egress SG rules can all be in
# transition when user_data begins executing. Probe github.com (first
# external dependency) until it responds or we give up.
# ---------------------------------------------------------------------------
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 https://github.com -o /dev/null; then
    echo "[bastion user_data] network ready after $i attempt(s)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "[bastion user_data] network did not become ready after 5 minutes" >&2
    exit 1
  fi
  echo "[bastion user_data] network not ready (attempt $i/30), sleeping 10s"
  sleep 10
done

# ---------------------------------------------------------------------------
# Install tooling (root)
# ---------------------------------------------------------------------------
dnf install -y git

curl -Lo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ---------------------------------------------------------------------------
# Per-user bootstrap (runs as ec2-user so ownership lands under the
# operator's home directory rather than root's).
# ---------------------------------------------------------------------------
%{ if repo_url != null ~}
sudo -u ec2-user git clone '${repo_url}' "/home/ec2-user/$(basename '${repo_url}' .git)"
%{ endif ~}

sudo -u ec2-user aws eks update-kubeconfig --name '${cluster_name}' --region '${region}'

sudo -u ec2-user helm repo add eks https://aws.github.io/eks-charts
sudo -u ec2-user helm repo update