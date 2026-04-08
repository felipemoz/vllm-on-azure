#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

echo "=== Terraform Tests ==="

# Test 1: terraform fmt
echo ""
if terraform -chdir="$TF_DIR" fmt -check -recursive >/dev/null 2>&1; then
  pass "Terraform formatting is correct"
else
  fail "Terraform formatting needs fixing (run: terraform -chdir=terraform fmt -recursive)"
fi

# Test 2: terraform init
echo ""
if terraform -chdir="$TF_DIR" init -backend=false -input=false >/dev/null 2>&1; then
  pass "Terraform init succeeded"
else
  fail "Terraform init failed"
fi

# Test 3: terraform validate
echo ""
if terraform -chdir="$TF_DIR" validate >/dev/null 2>&1; then
  pass "Terraform validate passed"
else
  fail "Terraform validate failed"
fi

# Test 4: Required files exist
echo ""
REQUIRED_FILES=(providers.tf variables.tf main.tf network.tf aks.tf outputs.tf)
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "$TF_DIR/$f" ]]; then
    pass "File exists: $f"
  else
    fail "Missing file: $f"
  fi
done

# Test 5: Variables have descriptions
echo ""
VARS_WITHOUT_DESC=$(grep -c 'variable "' "$TF_DIR/variables.tf" || true)
VARS_WITH_DESC=$(grep -c 'description' "$TF_DIR/variables.tf" || true)
if [[ "$VARS_WITHOUT_DESC" -le "$VARS_WITH_DESC" ]]; then
  pass "All variables have descriptions"
else
  fail "Some variables are missing descriptions"
fi

# Test 6: Check GPU VM size is parameterized
echo ""
if grep -q 'gpu_node_vm_size' "$TF_DIR/variables.tf" && \
   grep -q 'gpu_node_vm_size' "$TF_DIR/aks.tf"; then
  pass "GPU VM size is parameterized"
else
  fail "GPU VM size is not properly parameterized"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
