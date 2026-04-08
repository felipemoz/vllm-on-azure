#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/../benchmark"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

echo "=== Benchmark Tool Tests ==="

# Test 1: Python file exists
if [[ -f "$BENCH_DIR/bench.py" ]]; then
  pass "bench.py exists"
else
  fail "bench.py not found"
fi

# Test 2: Python syntax is valid
echo ""
if python3 -c "import py_compile; py_compile.compile('$BENCH_DIR/bench.py', doraise=True)" 2>/dev/null; then
  pass "bench.py has valid Python syntax"
else
  fail "bench.py has syntax errors"
fi

# Test 3: Required imports are available
echo ""
if python3 -c "import asyncio, json, statistics, time, argparse, dataclasses" 2>/dev/null; then
  pass "Standard library imports available"
else
  fail "Missing standard library imports"
fi

# Test 4: aiohttp dependency declared
echo ""
if grep -q 'aiohttp' "$BENCH_DIR/requirements.txt" 2>/dev/null; then
  pass "aiohttp declared in requirements.txt"
else
  fail "aiohttp missing from requirements.txt"
fi

# Test 5: Benchmark has all InferenceX metrics
echo ""
METRICS=("ttft" "itl" "output_tokens_per_sec" "input_tokens_per_sec" "cost_per_1m_tokens" "requests_per_sec")
ALL_FOUND=true
for m in "${METRICS[@]}"; do
  if ! grep -qi "$m" "$BENCH_DIR/bench.py"; then
    fail "Missing metric: $m"
    ALL_FOUND=false
  fi
done
if $ALL_FOUND; then
  pass "All InferenceX-style metrics present (TTFT, ITL, tok/s, cost/1M)"
fi

# Test 6: Spot pricing data is included
echo ""
if grep -q 'Standard_NC24ads_A100_v4' "$BENCH_DIR/bench.py" && \
   grep -q 'Standard_NC96ads_A100_v4' "$BENCH_DIR/bench.py"; then
  pass "Azure Spot pricing data included for all A100 SKUs"
else
  fail "Missing Azure Spot pricing data"
fi

# Test 7: CLI help works
echo ""
if python3 "$BENCH_DIR/bench.py" --help >/dev/null 2>&1; then
  pass "CLI --help works"
else
  fail "CLI --help failed"
fi

# Test 8: Test percentile function
echo ""
PERCENTILE_TEST=$(python3 -c "
import sys
sys.path.insert(0, '$BENCH_DIR')
from bench import percentile
assert percentile([1,2,3,4,5], 50) == 3.0, 'p50 failed'
assert percentile([1,2,3,4,5], 0) == 1.0, 'p0 failed'
assert percentile([], 50) == 0.0, 'empty failed'
print('ok')
" 2>&1)
if [[ "$PERCENTILE_TEST" == "ok" ]]; then
  pass "percentile() function works correctly"
else
  fail "percentile() function has errors: $PERCENTILE_TEST"
fi

# Test 9: Test compute_report
echo ""
REPORT_TEST=$(python3 -c "
import sys
sys.path.insert(0, '$BENCH_DIR')
from bench import compute_report, RequestResult

results = [
    RequestResult(ttft_ms=50.0, itl_ms=[10.0, 12.0, 11.0], total_latency_ms=500.0,
                  input_tokens=100, output_tokens=50, success=True),
    RequestResult(ttft_ms=60.0, itl_ms=[15.0, 13.0, 14.0], total_latency_ms=600.0,
                  input_tokens=100, output_tokens=50, success=True),
]
report = compute_report(results, 'test-model', 'Standard_NC24ads_A100_v4',
                         concurrency=2, input_seq_len=100, output_seq_len=50,
                         total_duration=1.0, num_gpus=1)
assert report.successful_requests == 2, f'expected 2, got {report.successful_requests}'
assert report.total_output_tokens == 100, f'expected 100, got {report.total_output_tokens}'
assert report.output_tokens_per_sec == 100.0, f'expected 100, got {report.output_tokens_per_sec}'
assert report.spot_cost_per_hour > 0, 'spot cost should be > 0'
assert report.spot_cost_per_1m_tokens > 0, 'spot cost per 1M tokens should be > 0'
assert report.spot_savings_pct > 80, f'expected >80% savings, got {report.spot_savings_pct}'
print('ok')
" 2>&1)
if [[ "$REPORT_TEST" == "ok" ]]; then
  pass "compute_report() produces correct metrics and cost"
else
  fail "compute_report() has errors: $REPORT_TEST"
fi

# Test 10: Test build_prompt
echo ""
PROMPT_TEST=$(python3 -c "
import sys
sys.path.insert(0, '$BENCH_DIR')
from bench import build_prompt
p = build_prompt(512)
assert len(p) > 1000, f'prompt too short: {len(p)}'
print('ok')
" 2>&1)
if [[ "$PROMPT_TEST" == "ok" ]]; then
  pass "build_prompt() generates correct-length prompts"
else
  fail "build_prompt() has errors: $PROMPT_TEST"
fi

# Test 11: JSON export
echo ""
EXPORT_TEST=$(python3 -c "
import sys, json, tempfile, os
sys.path.insert(0, '$BENCH_DIR')
from bench import BenchmarkReport, export_json
report = BenchmarkReport(model='test', vm_size='Standard_NC24ads_A100_v4',
    concurrency=1, num_requests=1, input_seq_len=128, output_seq_len=64,
    output_tokens_per_sec=100.0, spot_cost_per_1m_tokens=0.005)
f = tempfile.mktemp(suffix='.json')
export_json(report, f)
with open(f) as fp:
    data = json.load(fp)
assert 'throughput' in data
assert 'cost' in data
assert 'latency' in data
os.unlink(f)
print('ok')
" 2>&1)
if echo "$EXPORT_TEST" | grep -q "ok"; then
  pass "JSON export works correctly"
else
  fail "JSON export has errors: $EXPORT_TEST"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
