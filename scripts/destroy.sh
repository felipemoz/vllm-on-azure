#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$ROOT_DIR/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ---------- Step 1: Delete K8s resources ----------
info "Deleting vLLM Kubernetes resources..."
kubectl delete namespace vllm --ignore-not-found --timeout=120s || true

# ---------- Step 2: Terraform destroy ----------
info "Destroying infrastructure..."
terraform -chdir="$TF_DIR" destroy -auto-approve -input=false

info "All resources destroyed."
