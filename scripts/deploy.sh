#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$ROOT_DIR/terraform"
K8S_DIR="$ROOT_DIR/k8s"

# ---------- Defaults (overridable via env) ----------
export VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
export VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen3.5-122B-A10B}"
export VLLM_GPU_COUNT="${VLLM_GPU_COUNT:-8}"
export VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-32768}"
export VLLM_REPLICAS="${VLLM_REPLICAS:-1}"
export HF_TOKEN="${HF_TOKEN:?HF_TOKEN environment variable is required}"

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- Pre-flight checks ----------
for cmd in terraform az kubectl envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd is required but not found in PATH"
    exit 1
  fi
done

# ---------- Pre-flight: GPU Quota Check ----------
# Read GPU VM size from terraform.tfvars if not set via env
if [[ -z "${GPU_VM_SIZE:-}" && -f "$TF_DIR/terraform.tfvars" ]]; then
  GPU_VM_SIZE=$(grep -E '^\s*gpu_node_vm_size\s*=' "$TF_DIR/terraform.tfvars" | sed 's/.*=\s*"\(.*\)".*/\1/' | tr -d ' ' || true)
fi
GPU_VM_SIZE="${GPU_VM_SIZE:-Standard_ND96amsr_A100_v4}"

# Read GPU count from terraform.tfvars if not set via env
if [[ -z "${VLLM_GPU_COUNT:-}" || "$VLLM_GPU_COUNT" == "8" ]] && [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  TF_GPU=$(grep -E '^\s*vllm_gpu_count\s*=' "$TF_DIR/terraform.tfvars" | sed 's/.*=\s*\([0-9]*\).*/\1/' | tr -d ' ' || true)
  if [[ -n "$TF_GPU" ]]; then
    export VLLM_GPU_COUNT="$TF_GPU"
  fi
fi
SKIP_QUOTA_CHECK="${SKIP_QUOTA_CHECK:-0}"

if [[ "$SKIP_QUOTA_CHECK" != "1" ]]; then
  info "Checking GPU Spot quota for $GPU_VM_SIZE..."

  # Read location from terraform.tfvars if it exists
  TF_LOCATION=""
  if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
    TF_LOCATION=$(grep -E '^\s*location\s*=' "$TF_DIR/terraform.tfvars" | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' ' || true)
  fi

  if [[ -n "$TF_LOCATION" ]]; then
    info "Checking quota in configured region: $TF_LOCATION"
    if ! LOCATION="$TF_LOCATION" SKIP_RANKING=1 bash "$SCRIPT_DIR/check_quota.sh" "$GPU_VM_SIZE" spot; then
      error "Insufficient GPU quota in $TF_LOCATION for $GPU_VM_SIZE"
      echo ""
      warn "Options:"
      warn "  1. Request quota increase in Azure Portal"
      warn "  2. Run 'make check-quota' to find a region with quota"
      warn "  3. Set SKIP_QUOTA_CHECK=1 to bypass this check"
      exit 1
    fi
  else
    info "No location configured. Scanning all regions for best region..."
    if bash "$SCRIPT_DIR/check_quota.sh" "$GPU_VM_SIZE" spot; then
      BEST=$(cat /tmp/vllm_best_region 2>/dev/null || true)
      if [[ -n "$BEST" ]]; then
        warn "Recommended region: $BEST"
        warn "Set 'location = \"$BEST\"' in terraform/terraform.tfvars before deploying."
      fi
      exit 0
    else
      error "No region has sufficient quota for $GPU_VM_SIZE"
      exit 1
    fi
  fi

  info "Quota check passed!"
  echo ""
fi

# ---------- Step 1: Terraform ----------
info "Initializing Terraform..."
terraform -chdir="$TF_DIR" init -input=false

info "Applying Terraform (AKS + networking + APIM)..."
terraform -chdir="$TF_DIR" apply -auto-approve -input=false

# ---------- Step 2: Get kubeconfig ----------
RESOURCE_GROUP=$(terraform -chdir="$TF_DIR" output -raw resource_group_name)
CLUSTER_NAME=$(terraform -chdir="$TF_DIR" output -raw cluster_name)
APIM_ENABLED=$(terraform -chdir="$TF_DIR" output -raw apim_enabled)

info "Fetching AKS credentials..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

# ---------- Step 3: Install NVIDIA device plugin ----------
info "Installing NVIDIA device plugin..."
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml

# ---------- Step 4: Deploy Kubernetes manifests ----------
info "Creating namespace..."
kubectl apply -f "$K8S_DIR/namespace.yaml"

info "Creating HuggingFace token secret..."
kubectl create secret generic hf-token \
  --namespace vllm \
  --from-literal=token="$HF_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Creating PVC for model cache..."
kubectl apply -f "$K8S_DIR/pvc.yaml"

info "Deploying vLLM..."
envsubst < "$K8S_DIR/vllm-deployment.yaml" | kubectl apply -f -

info "Creating vLLM service..."
kubectl apply -f "$K8S_DIR/vllm-service.yaml"

info "Deploying gateway (eviction-resilient proxy)..."
kubectl apply -f "$K8S_DIR/gateway-configmap.yaml"
kubectl apply -f "$K8S_DIR/gateway-deployment.yaml"
kubectl apply -f "$K8S_DIR/gateway-service.yaml"
kubectl apply -f "$K8S_DIR/pdb.yaml"

# ---------- Step 5: Wait for rollout ----------
info "Waiting for gateway to be ready..."
kubectl rollout status deployment/vllm-gateway \
  --namespace vllm \
  --timeout=120s

info "Waiting for vLLM deployment to be ready (model download + loading can take 10-20 min for 122B)..."
kubectl rollout status deployment/vllm \
  --namespace vllm \
  --timeout=1200s || {
    warn "vLLM not ready within timeout. The gateway will return maintenance messages until it's up."
    warn "Check logs with: kubectl logs -n vllm -l app.kubernetes.io/name=vllm --tail=100"
  }

# ---------- Step 6: Configure APIM backend ----------
if [[ "$APIM_ENABLED" == "true" ]]; then
  APIM_NAME=$(terraform -chdir="$TF_DIR" output -raw apim_name)

  info "Waiting for gateway LoadBalancer public IP..."
  LB_IP=""
  for i in $(seq 1 60); do
    LB_IP=$(kubectl get svc vllm-gateway-lb -n vllm -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$LB_IP" ]]; then
      break
    fi
    sleep 5
  done

  if [[ -z "$LB_IP" ]]; then
    warn "Could not get LB IP after 5 minutes. APIM backend must be configured manually."
    warn "  az apim api update --resource-group $RESOURCE_GROUP --service-name $APIM_NAME --api-id vllm-inference --service-url http://<LB_IP>:80"
  else
    info "Gateway LB public IP: $LB_IP"
    info "Updating APIM backend URL to http://$LB_IP:80 ..."
    az apim api update \
      --resource-group "$RESOURCE_GROUP" \
      --service-name "$APIM_NAME" \
      --api-id vllm-inference \
      --service-url "http://$LB_IP:80" \
      --output none

    APIM_URL=$(terraform -chdir="$TF_DIR" output -raw apim_gateway_url)
    APIM_KEY=$(terraform -chdir="$TF_DIR" output -raw apim_subscription_key)

    echo ""
    info "====================================================="
    info " APIM PUBLIC ENDPOINT READY"
    info "====================================================="
    echo ""
    echo -e "  ${CYAN}APIM URL:${NC}  $APIM_URL"
    echo -e "  ${CYAN}API Key:${NC}   $APIM_KEY"
    echo ""
    echo "  # Test (public, authenticated):"
    echo "  curl $APIM_URL/v1/models -H 'api-key: $APIM_KEY'"
    echo ""
    echo "  curl $APIM_URL/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -H 'api-key: $APIM_KEY' \\"
    echo "    -d '{\"model\": \"$VLLM_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}'"
    echo ""
    echo -e "  ${YELLOW}Rate limit: $(terraform -chdir="$TF_DIR" output -json | python3 -c 'import sys,json; print("configured in terraform.tfvars")' 2>/dev/null || echo "see terraform.tfvars")${NC}"
  fi
fi

# ---------- Done ----------
echo ""
info "Deployment complete!"
echo ""
info "Access vLLM API via gateway (eviction-resilient):"
echo "  # Port-forward gateway (local):"
echo "  kubectl port-forward -n vllm svc/vllm-gateway 8080:8080"
echo ""
echo "  # Test:"
echo '  curl http://localhost:8080/v1/models'
echo ""
echo "  # Gateway status (eviction count, backend health):"
echo '  curl http://localhost:8080/gateway/status'
echo ""
echo "  # Direct vLLM access (bypasses gateway):"
echo "  kubectl port-forward -n vllm svc/vllm 8000:8000"
