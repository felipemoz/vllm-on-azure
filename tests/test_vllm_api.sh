#!/usr/bin/env bash
set -euo pipefail

VLLM_ENDPOINT="${VLLM_ENDPOINT:-http://localhost:8000}"
VLLM_MODEL="${VLLM_MODEL:-mistralai/Mistral-7B-Instruct-v0.3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

echo "=== vLLM API Tests ==="
echo "Endpoint: $VLLM_ENDPOINT"
echo ""

# Test 1: Health check
if curl -sf "$VLLM_ENDPOINT/health" >/dev/null 2>&1; then
  pass "Health endpoint is reachable"
else
  fail "Health endpoint is not reachable"
  echo "  Make sure port-forward is running: make port-forward"
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

# Test 2: List models
echo ""
MODELS=$(curl -sf "$VLLM_ENDPOINT/v1/models" 2>/dev/null)
if echo "$MODELS" | python3 -c "import sys,json; data=json.load(sys.stdin); assert len(data['data']) > 0" 2>/dev/null; then
  pass "Models endpoint returns available models"
else
  fail "Models endpoint returned no models"
fi

# Test 3: Completions
echo ""
RESPONSE=$(curl -sf "$VLLM_ENDPOINT/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$VLLM_MODEL\", \"prompt\": \"Hello, world!\", \"max_tokens\": 16}" 2>/dev/null)

if echo "$RESPONSE" | python3 -c "import sys,json; data=json.load(sys.stdin); assert len(data['choices'][0]['text']) > 0" 2>/dev/null; then
  pass "Completions endpoint returns text"
else
  fail "Completions endpoint failed"
fi

# Test 4: Chat completions
echo ""
CHAT_RESPONSE=$(curl -sf "$VLLM_ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$VLLM_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}], \"max_tokens\": 16}" 2>/dev/null)

if echo "$CHAT_RESPONSE" | python3 -c "import sys,json; data=json.load(sys.stdin); assert len(data['choices'][0]['message']['content']) > 0" 2>/dev/null; then
  pass "Chat completions endpoint works"
else
  fail "Chat completions endpoint failed"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
