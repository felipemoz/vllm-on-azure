#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$SCRIPT_DIR/../docker/gateway"
K8S_DIR="$SCRIPT_DIR/../k8s"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

echo "=== Gateway Tests ==="

# Test 1: Gateway Python file exists
if [[ -f "$GATEWAY_DIR/gateway.py" ]]; then
  pass "gateway.py exists"
else
  fail "gateway.py not found"
fi

# Test 2: Python syntax is valid
echo ""
if python3 -c "import py_compile; py_compile.compile('$GATEWAY_DIR/gateway.py', doraise=True)" 2>/dev/null; then
  pass "gateway.py has valid Python syntax"
else
  fail "gateway.py has syntax errors"
fi

# Test 3: Dockerfile exists
echo ""
if [[ -f "$GATEWAY_DIR/Dockerfile" ]]; then
  pass "Gateway Dockerfile exists"
else
  fail "Gateway Dockerfile not found"
fi

# Test 4: Dockerfile uses slim base
echo ""
if grep -q 'python:.*slim' "$GATEWAY_DIR/Dockerfile"; then
  pass "Dockerfile uses slim Python base image"
else
  fail "Dockerfile should use slim base image"
fi

# Test 5: Maintenance message is present
echo ""
if grep -q 'trocando o pneu' "$GATEWAY_DIR/gateway.py"; then
  pass "Maintenance message (trocando o pneu) is present"
else
  fail "Maintenance message not found"
fi

# Test 6: Gateway handles health checking
echo ""
if grep -q 'health_checker' "$GATEWAY_DIR/gateway.py" && \
   grep -q 'HEALTH_INTERVAL' "$GATEWAY_DIR/gateway.py"; then
  pass "Background health checker is implemented"
else
  fail "Health checker not found"
fi

# Test 7: Gateway handles streaming responses
echo ""
if grep -q 'text/event-stream' "$GATEWAY_DIR/gateway.py" && \
   grep -q 'StreamResponse' "$GATEWAY_DIR/gateway.py"; then
  pass "Streaming response proxying is implemented"
else
  fail "Streaming support not found"
fi

# Test 8: Gateway handles mid-stream eviction
echo ""
if grep -q 'model_reloading' "$GATEWAY_DIR/gateway.py"; then
  pass "Mid-stream eviction error handling is implemented"
else
  fail "Mid-stream eviction handling not found"
fi

# Test 9: Eviction counter
echo ""
if grep -q 'eviction_count' "$GATEWAY_DIR/gateway.py"; then
  pass "Eviction counter is tracked"
else
  fail "Eviction counter not found"
fi

# Test 10: Gateway status endpoint
echo ""
if grep -q 'gateway/status' "$GATEWAY_DIR/gateway.py"; then
  pass "Gateway status endpoint exists"
else
  fail "Gateway status endpoint not found"
fi

# Test 11: K8s gateway deployment exists
echo ""
if [[ -f "$K8S_DIR/gateway-deployment.yaml" ]]; then
  pass "gateway-deployment.yaml exists"
else
  fail "gateway-deployment.yaml not found"
fi

# Test 12: Gateway runs on non-GPU nodes
echo ""
if grep -q 'NotIn' "$K8S_DIR/gateway-deployment.yaml" && \
   grep -q 'gpu' "$K8S_DIR/gateway-deployment.yaml"; then
  pass "Gateway is scheduled on non-GPU (non-Spot) nodes"
else
  fail "Gateway should avoid GPU/Spot nodes"
fi

# Test 13: Gateway has 2 replicas
echo ""
if grep -q 'replicas: 2' "$K8S_DIR/gateway-deployment.yaml"; then
  pass "Gateway has 2 replicas for HA"
else
  fail "Gateway should have at least 2 replicas"
fi

# Test 14: PDB exists
echo ""
if [[ -f "$K8S_DIR/pdb.yaml" ]] && grep -q 'PodDisruptionBudget' "$K8S_DIR/pdb.yaml"; then
  pass "PodDisruptionBudget exists for gateway"
else
  fail "PDB not found"
fi

# Test 15: Gateway service exists
echo ""
if [[ -f "$K8S_DIR/gateway-service.yaml" ]]; then
  pass "gateway-service.yaml exists"
else
  fail "gateway-service.yaml not found"
fi

# Test 16: Test BackendState logic
echo ""
STATE_TEST=$(python3 -c "
import sys
sys.path.insert(0, '$GATEWAY_DIR')
from gateway import BackendState, maintenance_response
from unittest.mock import MagicMock

# Test initial state
s = BackendState()
assert s.healthy == False, 'should start unhealthy'
assert s.eviction_count == 0, 'should start with 0 evictions'

# Test state tracking
s.healthy = True
s.eviction_count = 3
s.evicted_at = 1000.0
assert s.eviction_count == 3
print('ok')
" 2>&1)
if [[ "$STATE_TEST" == "ok" ]]; then
  pass "BackendState logic works correctly"
else
  fail "BackendState has errors: $STATE_TEST"
fi

# Test 17: Test maintenance_response format
echo ""
MAINT_TEST=$(python3 -c "
import sys, json
sys.path.insert(0, '$GATEWAY_DIR')
from gateway import maintenance_response, state
from unittest.mock import MagicMock

state.eviction_count = 2

# Test completions endpoint
req = MagicMock()
req.path = '/v1/completions'
resp = maintenance_response(req)
assert resp.status == 503, f'expected 503, got {resp.status}'
body = json.loads(resp.body)
assert 'error' in body, 'response should have error field'
assert 'trocando o pneu' in body['error']['message']
assert body['error']['code'] == 'model_reloading'

# Test health endpoint
req.path = '/health'
resp = maintenance_response(req)
body = json.loads(resp.body)
assert body['status'] == 'maintenance'
assert body['eviction_count'] == 2

print('ok')
" 2>&1)
if [[ "$MAINT_TEST" == "ok" ]]; then
  pass "maintenance_response returns correct format with message"
else
  fail "maintenance_response has errors: $MAINT_TEST"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
