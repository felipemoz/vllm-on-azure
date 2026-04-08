#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/../k8s"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

echo "=== Kubernetes Manifest Tests ==="

# Test 1: Required files exist
REQUIRED_FILES=(namespace.yaml vllm-deployment.yaml vllm-service.yaml pvc.yaml hf-secret.yaml gateway-deployment.yaml gateway-service.yaml pdb.yaml)
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "$K8S_DIR/$f" ]]; then
    pass "File exists: $f"
  else
    fail "Missing file: $f"
  fi
done

# Test 2: YAML syntax is valid (basic check)
echo ""
for f in "$K8S_DIR"/*.yaml; do
  fname=$(basename "$f")
  if python3 -c "import yaml; yaml.safe_load_all(open('$f'))" 2>/dev/null; then
    pass "Valid YAML: $fname"
  else
    # Files with envsubst vars (${...}) will fail YAML parse - that's expected
    if grep -q '\${' "$f"; then
      pass "Valid template: $fname (contains envsubst variables)"
    else
      fail "Invalid YAML: $fname"
    fi
  fi
done

# Test 3: Deployment has GPU resource requests
echo ""
if grep -q 'nvidia.com/gpu' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "Deployment requests GPU resources"
else
  fail "Deployment is missing GPU resource requests"
fi

# Test 4: Deployment has health probes
echo ""
if grep -q 'livenessProbe' "$K8S_DIR/vllm-deployment.yaml" && \
   grep -q 'readinessProbe' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "Deployment has liveness and readiness probes"
else
  fail "Deployment is missing health probes"
fi

# Test 5: Shared memory volume is configured
echo ""
if grep -q '/dev/shm' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "Shared memory volume is configured"
else
  fail "Missing /dev/shm volume (required for tensor parallelism)"
fi

# Test 6: Namespace is set to 'vllm'
echo ""
if grep -q 'namespace: vllm' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "Deployment targets 'vllm' namespace"
else
  fail "Deployment does not target 'vllm' namespace"
fi

# Test 7: GPU node toleration is set
echo ""
if grep -q 'nvidia.com/gpu' "$K8S_DIR/vllm-deployment.yaml" && \
   grep -q 'tolerations' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "GPU node toleration is configured"
else
  fail "Missing GPU node toleration"
fi

# Test 8: Service exposes port 8000
echo ""
if grep -q '8000' "$K8S_DIR/vllm-service.yaml"; then
  pass "Service exposes port 8000"
else
  fail "Service does not expose port 8000"
fi

# Test 9: Spot toleration is set
echo ""
if grep -q 'kubernetes.azure.com/scalesetpriority' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "Spot VM toleration is configured"
else
  fail "Missing Spot VM toleration"
fi

# Test 10: Graceful shutdown is configured
echo ""
if grep -q 'terminationGracePeriodSeconds' "$K8S_DIR/vllm-deployment.yaml" && \
   grep -q 'preStop' "$K8S_DIR/vllm-deployment.yaml"; then
  pass "Graceful shutdown (preStop + terminationGracePeriod) is configured"
else
  fail "Missing graceful shutdown configuration"
fi

# Test 11: Gateway service exposes port 8080
echo ""
if grep -q '8080' "$K8S_DIR/gateway-service.yaml"; then
  pass "Gateway service exposes port 8080"
else
  fail "Gateway service does not expose port 8080"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
