#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# check_quota.sh — Azure GPU Quota Scanner + Region Recommender
#
# Scans ALL Azure regions for GPU Spot/On-Demand quota, then ranks
# eligible regions by:
#   1. Lowest eviction risk  (spot price / on-demand price ratio)
#   2. Lowest network latency (TCP RTT to region blob endpoint)
#
# Usage:
#   ./check_quota.sh                                    # default VM
#   ./check_quota.sh Standard_ND96amsr_A100_v4          # specific VM
#   ./check_quota.sh Standard_ND96amsr_A100_v4 regular  # on-demand
#   LOCATION=eastus ./check_quota.sh                    # single region
#   SKIP_RANKING=1 ./check_quota.sh                     # skip phase 2
#   MAX_LATENCY_MS=3000 ./check_quota.sh                # custom latency limit
# ═══════════════════════════════════════════════════════════════════

VM_SIZE="${1:-Standard_ND96amsr_A100_v4}"
PRIORITY="${2:-spot}"
TARGET_LOCATION="${LOCATION:-}"
SKIP_RANKING="${SKIP_RANKING:-0}"
MAX_LATENCY_MS="${MAX_LATENCY_MS:-5000}"
PHASE1_CONCURRENCY="${PHASE1_CONCURRENCY:-8}"
PHASE2_CONCURRENCY="${PHASE2_CONCURRENCY:-12}"
AZ_TIMEOUT_SEC="${AZ_TIMEOUT_SEC:-120}"

if ! [[ "$PHASE1_CONCURRENCY" =~ ^[0-9]+$ ]] || [[ "$PHASE1_CONCURRENCY" -lt 1 ]]; then
  PHASE1_CONCURRENCY=8
fi
if ! [[ "$PHASE2_CONCURRENCY" =~ ^[0-9]+$ ]] || [[ "$PHASE2_CONCURRENCY" -lt 1 ]]; then
  PHASE2_CONCURRENCY=12
fi
if ! [[ "$AZ_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$AZ_TIMEOUT_SEC" -lt 5 ]]; then
  AZ_TIMEOUT_SEC=120
fi

# ── Full ND family + NC A100 family ──────────────────────────────
# Format: "vm_size|family_filter|vcpus|gpu_desc"
# family_filter = partial match in az vm list-usage name.value (lowercase)
declare -a VM_CATALOG=(
  "Standard_ND6s|standardndseries|6|1x P40 24GB"
  "Standard_ND12s|standardndseries|12|2x P40 24GB"
  "Standard_ND24s|standardndseries|24|4x P40 24GB"
  "Standard_ND24rs|standardndseries|24|4x P40 24GB (RDMA)"
  "Standard_ND40rs_v2|standardndv2series|40|8x V100 32GB"
  "Standard_ND96asr_v4|standardndasv4_a100|96|8x A100 40GB"
  "Standard_ND96amsr_A100_v4|standardndamsv4_a100|96|8x A100 80GB"
  "Standard_ND96isr_H100_v5|standardndh100v5|96|8x H100 80GB"
  "Standard_ND96isr_MI300X_v5|standardndmi300xv5|96|8x MI300X 192GB"
  "Standard_NC24ads_A100_v4|standardncadsa100v4|24|1x A100 80GB"
  "Standard_NC48ads_A100_v4|standardncadsa100v4|48|2x A100 80GB"
  "Standard_NC96ads_A100_v4|standardncadsa100v4|96|4x A100 80GB"
)

# ── Lookup helpers ───────────────────────────────────────────────
get_vm_info() {
  local target="$1"
  for entry in "${VM_CATALOG[@]}"; do
    local name
    name=$(echo "$entry" | cut -d'|' -f1)
    if [[ "$name" == "$target" ]]; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

VM_INFO=$(get_vm_info "$VM_SIZE" || true)
if [[ -z "$VM_INFO" ]]; then
  echo -e "\033[0;31m[ERROR]\033[0m Unknown VM: $VM_SIZE"
  echo ""
  echo "Supported VMs:"
  for entry in "${VM_CATALOG[@]}"; do
    local_name=$(echo "$entry" | cut -d'|' -f1)
    local_gpu=$(echo "$entry" | cut -d'|' -f4)
    local_vcpu=$(echo "$entry" | cut -d'|' -f3)
    printf "  %-40s %s (%s vCPUs)\n" "$local_name" "$local_gpu" "$local_vcpu"
  done
  exit 1
fi

FAMILY_FILTER=$(echo "$VM_INFO" | cut -d'|' -f2)
VCPUS_NEEDED=$(echo "$VM_INFO" | cut -d'|' -f3)
GPU_DESC=$(echo "$VM_INFO" | cut -d'|' -f4)

# ── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Azure GPU Quota Scanner + Region Recommender${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "  VM Size:       ${CYAN}$VM_SIZE${NC}"
echo -e "  GPUs:          ${CYAN}$GPU_DESC${NC}"
echo -e "  vCPUs needed:  ${CYAN}$VCPUS_NEEDED${NC}"
echo -e "  Priority:      ${CYAN}$PRIORITY${NC}"
echo -e "  Max latency:   ${CYAN}${MAX_LATENCY_MS}ms${NC}"
echo -e "  Phase 1 jobs:  ${CYAN}${PHASE1_CONCURRENCY}${NC}"
echo -e "  Phase 2 jobs:  ${CYAN}${PHASE2_CONCURRENCY}${NC}"
echo -e "  AZ timeout:    ${CYAN}${AZ_TIMEOUT_SEC}s${NC}"
echo ""

# ── Pre-flight ───────────────────────────────────────────────────
if ! command -v az &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Azure CLI (az) not found"; exit 1
fi
if ! az account show &>/dev/null 2>&1; then
  echo -e "${RED}[ERROR]${NC} Not logged in. Run: az login"; exit 1
fi
if ! command -v python3 &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} python3 not found"; exit 1
fi

SUB_NAME=$(az account show --query 'name' -o tsv)
SUB_ID=$(az account show --query 'id' -o tsv)
echo -e "  Subscription:  ${CYAN}$SUB_NAME${NC}"
echo -e "  Sub ID:        ${DIM}$SUB_ID${NC}"
echo ""

# ── Get regions ──────────────────────────────────────────────────
if [[ -n "$TARGET_LOCATION" ]]; then
  REGIONS=("$TARGET_LOCATION")
  echo -e "${YELLOW}[INFO]${NC} Checking single region: $TARGET_LOCATION"
else
  echo -e "${YELLOW}[INFO]${NC} Scanning all Azure regions (this takes 2-5 minutes)..."
  REGIONS=()
  while IFS= read -r line; do
    REGIONS+=("$line")
  done < <(az account list-locations --query "[].name" -o tsv --only-show-errors 2>/dev/null | sort)
fi
echo -e "${YELLOW}[INFO]${NC} Found ${#REGIONS[@]} regions to scan"
echo ""

# ── Phase 1: Quota Scan ─────────────────────────────────────────
RESULTS_FILE=$(mktemp)
READY_FILE=$(mktemp)
PHASE1_TMP_DIR=$(mktemp -d)
trap 'rm -f "$RESULTS_FILE" "$READY_FILE"; rm -rf "$PHASE1_TMP_DIR"' EXIT

TOTAL=${#REGIONS[@]}

render_progress() {
  local current="$1"
  local total="$2"
  local label="$3"
  local pct=100
  local filled=50
  local empty=0
  local bar spc
  if [[ "$total" -gt 0 ]]; then
    pct=$((current * 100 / total))
    filled=$((pct / 2))
    empty=$((50 - filled))
  fi
  bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
  spc=$(printf '%*s' "$empty" '' | tr ' ' '░')
  printf "\r  ${DIM}[%s%s] %3d%% (%d/%d) %-25s${NC}" "$bar" "$spc" "$pct" "$current" "$total" "$label"
}

az_json_with_timeout() {
  local timeout="$1"
  shift
  python3 - "$timeout" "$@" <<'PY'
import subprocess, sys
timeout = int(sys.argv[1])
cmd = sys.argv[2:]
try:
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=timeout,
        check=False
    )
    out = result.stdout.strip()
    print(out if out else "[]")
except Exception:
    print("[]")
PY
}

phase1_scan_region() {
  local REGION="$1"
  local region_file="${PHASE1_TMP_DIR}/${REGION}.result"
  local ready_file="${PHASE1_TMP_DIR}/${REGION}.ready"

  # Check SKU availability
  local SKU_JSON
  SKU_JSON=$(az_json_with_timeout "$AZ_TIMEOUT_SEC" az vm list-skus --location "$REGION" --size "$VM_SIZE" -o json --only-show-errors)

  local SKU_COUNT
  SKU_COUNT=$(echo "$SKU_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  if [[ "$SKU_COUNT" == "0" ]]; then
    echo "$REGION|NOT_AVAILABLE|0|0|0|0" > "$region_file"
    return
  fi

  local SKU_RESTRICTED
  SKU_RESTRICTED=$(echo "$SKU_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for sku in data:
  for r in sku.get('restrictions', []):
    if r.get('type') == 'Location' and r.get('reasonCode') == 'NotAvailableForSubscription':
      print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "no")

  if [[ "$SKU_RESTRICTED" == "yes" ]]; then
    echo "$REGION|RESTRICTED|0|0|0|0" > "$region_file"
    return
  fi

  # Get usage (family + spot/regional)
  local USAGE_JSON
  USAGE_JSON=$(az_json_with_timeout "$AZ_TIMEOUT_SEC" az vm list-usage --location "$REGION" -o json --only-show-errors)

  local QUOTA_INFO
  QUOTA_INFO=$(echo "$USAGE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
family_filter = '${FAMILY_FILTER}'.lower()
priority = '${PRIORITY}'
fq, fu, sq, su = 0, 0, 0, 0

for item in data:
    nv = item.get('name', {}).get('value', '').lower()
    lv = item.get('name', {}).get('localizedValue', '').lower()
    cur = item.get('currentValue', 0)
    lim = item.get('limit', 0)

    if family_filter in nv:
        fu, fq = cur, lim

    if priority == 'spot':
        if 'lowpriority' in nv or 'low-priority' in lv or 'low priority' in lv:
            su, sq = cur, lim
    else:
        if nv == 'cores' or 'total regional vcpus' == lv:
            su, sq = cur, lim

print(f'{fq}|{fu}|{sq}|{su}')
" 2>/dev/null || echo "0|0|0|0")

  local FAMILY_QUOTA FAMILY_USED SPOT_QUOTA SPOT_USED
  FAMILY_QUOTA=$(echo "$QUOTA_INFO" | cut -d'|' -f1)
  FAMILY_USED=$(echo "$QUOTA_INFO" | cut -d'|' -f2)
  SPOT_QUOTA=$(echo "$QUOTA_INFO" | cut -d'|' -f3)
  SPOT_USED=$(echo "$QUOTA_INFO" | cut -d'|' -f4)

  local FA SA STATUS
  FA=$((FAMILY_QUOTA - FAMILY_USED))
  SA=$((SPOT_QUOTA - SPOT_USED))

  if [[ "$PRIORITY" == "spot" ]]; then
    # Spot: only lowPriorityCores (regional spot quota) matters
    if [[ "$SPOT_QUOTA" -eq 0 ]]; then
      STATUS="NO_SPOT_QUOTA"
    elif [[ "$SA" -lt "$VCPUS_NEEDED" ]]; then
      STATUS="INSUF_SPOT"
    else
      STATUS="READY"
      echo "$REGION" > "$ready_file"
    fi
  else
    # Dedicated: family quota is required
    if [[ "$FAMILY_QUOTA" -eq 0 ]]; then
      STATUS="NO_FAMILY_QUOTA"
    elif [[ "$FA" -lt "$VCPUS_NEEDED" ]]; then
      STATUS="INSUF_FAMILY"
    elif [[ "$SPOT_QUOTA" -eq 0 ]]; then
      STATUS="NO_SPOT_QUOTA"
    elif [[ "$SA" -lt "$VCPUS_NEEDED" ]]; then
      STATUS="INSUF_SPOT"
    else
      STATUS="READY"
      echo "$REGION" > "$ready_file"
    fi
  fi

  echo "$REGION|$STATUS|$FAMILY_QUOTA|$FAMILY_USED|$SPOT_QUOTA|$SPOT_USED" > "$region_file"
}

echo -e "${BOLD}── Phase 1: Quota Scan ──────────────────────────────────────${NC}"
echo ""
echo -e "  ${DIM}Running quota checks with ${PHASE1_CONCURRENCY} parallel jobs...${NC}"

export VM_SIZE FAMILY_FILTER PRIORITY VCPUS_NEEDED PHASE1_TMP_DIR AZ_TIMEOUT_SEC
export -f az_json_with_timeout
export -f phase1_scan_region
printf '%s\n' "${REGIONS[@]}" | xargs -n 1 -P "$PHASE1_CONCURRENCY" bash -c 'phase1_scan_region "$1"' _ &
PHASE1_PID=$!
LAST_PHASE1_REPORT=0
while kill -0 "$PHASE1_PID" 2>/dev/null; do
  DONE_COUNT=$(find "$PHASE1_TMP_DIR" -type f -name '*.result' 2>/dev/null | wc -l | tr -d ' ')
  if [[ -t 1 ]]; then
    render_progress "$DONE_COUNT" "$TOTAL" "quota scan"
  else
    if [[ "$DONE_COUNT" -ne "$LAST_PHASE1_REPORT" ]]; then
      echo "  [phase1] completed $DONE_COUNT/$TOTAL regions..."
      LAST_PHASE1_REPORT="$DONE_COUNT"
    fi
  fi
  sleep 1
done
wait "$PHASE1_PID"
DONE_COUNT=$(find "$PHASE1_TMP_DIR" -type f -name '*.result' 2>/dev/null | wc -l | tr -d ' ')
if [[ -t 1 ]]; then
  render_progress "$DONE_COUNT" "$TOTAL" "quota scan"
  printf "\n"
else
  echo "  [phase1] completed $DONE_COUNT/$TOTAL regions."
fi

for REGION in "${REGIONS[@]}"; do
  region_file="${PHASE1_TMP_DIR}/${REGION}.result"
  ready_file="${PHASE1_TMP_DIR}/${REGION}.ready"
  [[ -f "$region_file" ]] && cat "$region_file" >> "$RESULTS_FILE"
  [[ -f "$ready_file" ]] && cat "$ready_file" >> "$READY_FILE"
done

# ── Phase 2: Rank READY regions by eviction risk + latency ───────
READY_COUNT=0
if [[ -f "$READY_FILE" ]]; then
  READY_COUNT=$(wc -l < "$READY_FILE" | tr -d ' ')
fi

RANKED_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE" "$READY_FILE" "$RANKED_FILE"; rm -rf "$PHASE1_TMP_DIR"' EXIT

if [[ "$READY_COUNT" -gt 0 && "$SKIP_RANKING" != "1" ]]; then
  echo -e "${BOLD}── Phase 2: Ranking by Eviction Risk + Latency ────────────${NC}"
  echo ""

  # 2a. Fetch spot prices from Azure Retail Pricing API (public, no auth)
  echo -e "  ${DIM}Fetching spot prices from Azure Retail Pricing API...${NC}"

  # Build ARM SKU name for pricing API (strip "Standard_" prefix)
  ARM_SKU="$VM_SIZE"

  PRICING_JSON=$(curl -s --max-time 30 \
    "https://prices.azure.com/api/retail/prices?\$filter=armSkuName%20eq%20%27${ARM_SKU}%27%20and%20serviceName%20eq%20%27Virtual%20Machines%27&\$top=500" \
    2>/dev/null || echo '{"Items":[]}')

  # Also try to get the next page if present
  NEXT_LINK=$(echo "$PRICING_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('NextPageLink',''))" 2>/dev/null || echo "")
  if [[ -n "$NEXT_LINK" && "$NEXT_LINK" != "None" ]]; then
    PAGE2=$(curl -s --max-time 30 "$NEXT_LINK" 2>/dev/null || echo '{"Items":[]}')
    PRICING_JSON=$(python3 -c "
import sys, json
p1 = json.loads('''$PRICING_JSON''')
p2 = json.loads('''$PAGE2''')
p1['Items'].extend(p2.get('Items', []))
print(json.dumps(p1))
" 2>/dev/null || echo "$PRICING_JSON")
  fi

  # Extract spot + on-demand prices per region
  # Eviction proxy: spot_price / ondemand_price ratio
  # Lower ratio = less demand = less likely to be evicted
  PRICE_MAP_FILE=$(mktemp)
  PHASE2_TMP_DIR=$(mktemp -d)
  trap 'rm -f "$RESULTS_FILE" "$READY_FILE" "$RANKED_FILE" "$PRICE_MAP_FILE"; rm -rf "$PHASE1_TMP_DIR" "$PHASE2_TMP_DIR"' EXIT

  echo "$PRICING_JSON" | python3 -c "
import sys, json

data = json.load(sys.stdin)
items = data.get('Items', [])

# Group by region
regions = {}
for item in items:
    region = item.get('armRegionName', '')
    meter = item.get('meterName', '')
    price = item.get('retailPrice', 0)
    price_type = item.get('type', '')
    currency = item.get('currencyCode', '')
    if currency != 'USD' or not region:
        continue
    if region not in regions:
        regions[region] = {'spot': None, 'ondemand': None}
    if 'Spot' in meter and 'Low Priority' not in meter:
        regions[region]['spot'] = price
    elif price_type == 'Consumption' and 'Spot' not in meter and 'Low Priority' not in meter:
        regions[region]['ondemand'] = price

for region, prices in regions.items():
    spot = prices['spot']
    ondemand = prices['ondemand']
    if spot is not None and ondemand is not None and ondemand > 0:
        ratio = spot / ondemand
        print(f'{region}|{spot:.4f}|{ondemand:.4f}|{ratio:.6f}')
    elif spot is not None:
        print(f'{region}|{spot:.4f}|0|1.000000')
    elif ondemand is not None:
        print(f'{region}|0|{ondemand:.4f}|0.000000')
" > "$PRICE_MAP_FILE" 2>/dev/null || true

  PRICE_COUNT=$(wc -l < "$PRICE_MAP_FILE" | tr -d ' ')
  echo -e "  ${DIM}Got pricing for $PRICE_COUNT regions${NC}"

  # 2b. Measure latency for READY regions
  echo -e "  ${DIM}Measuring latency to $READY_COUNT READY regions...${NC}"
  echo -e "  ${DIM}Using ${PHASE2_CONCURRENCY} parallel jobs...${NC}"
  echo ""

  phase2_probe_region() {
    local REGION="$1"
    local out_file="${PHASE2_TMP_DIR}/${REGION}.rank"
    local LATENCIES=()
    local LAT MEDIAN_LAT MEDIAN_MS
    local EVICTION_RATIO SPOT_PRICE ONDEMAND_PRICE PRICE_LINE TOO_HIGH

    # Measure TCP connect time (3 attempts, take median)
    for _ in 1 2 3; do
      LAT=$(curl -o /dev/null -s -w '%{time_connect}' \
        --connect-timeout 5 \
        "https://${REGION}.blob.core.windows.net" 2>/dev/null || echo "9.999")
      LATENCIES+=("$LAT")
    done

    MEDIAN_LAT=$(printf '%s\n' "${LATENCIES[@]}" | sort -n | sed -n '2p')
    MEDIAN_MS=$(python3 -c "print(f'{float(\"$MEDIAN_LAT\") * 1000:.1f}')" 2>/dev/null || echo "9999.0")

    EVICTION_RATIO="1.000000"
    SPOT_PRICE="N/A"
    ONDEMAND_PRICE="N/A"
    if [[ -s "$PRICE_MAP_FILE" ]]; then
      PRICE_LINE=$(grep "^${REGION}|" "$PRICE_MAP_FILE" || true)
      if [[ -n "$PRICE_LINE" ]]; then
        SPOT_PRICE=$(echo "$PRICE_LINE" | cut -d'|' -f2)
        ONDEMAND_PRICE=$(echo "$PRICE_LINE" | cut -d'|' -f3)
        EVICTION_RATIO=$(echo "$PRICE_LINE" | cut -d'|' -f4)
      fi
    fi

    TOO_HIGH=$(python3 -c "print(1 if float('$MEDIAN_MS') > float('$MAX_LATENCY_MS') else 0)" 2>/dev/null || echo "0")
    if [[ "$TOO_HIGH" == "1" ]]; then
      echo "FILTERED|$REGION|$MEDIAN_MS" > "$out_file"
      return
    fi

    echo "RANKED|$REGION|$EVICTION_RATIO|$MEDIAN_MS|$SPOT_PRICE|$ONDEMAND_PRICE" > "$out_file"
  }

  export MAX_LATENCY_MS PRICE_MAP_FILE PHASE2_TMP_DIR
  export -f phase2_probe_region
  xargs -n 1 -P "$PHASE2_CONCURRENCY" bash -c 'phase2_probe_region "$1"' _ < "$READY_FILE" &
  PHASE2_PID=$!
  LAST_PHASE2_REPORT=0
  while kill -0 "$PHASE2_PID" 2>/dev/null; do
    DONE_COUNT=$(find "$PHASE2_TMP_DIR" -type f -name '*.rank' 2>/dev/null | wc -l | tr -d ' ')
    if [[ -t 1 ]]; then
      render_progress "$DONE_COUNT" "$READY_COUNT" "latency probe"
    else
      if [[ "$DONE_COUNT" -ne "$LAST_PHASE2_REPORT" ]]; then
        echo "  [phase2] completed $DONE_COUNT/$READY_COUNT regions..."
        LAST_PHASE2_REPORT="$DONE_COUNT"
      fi
    fi
    sleep 1
  done
  wait "$PHASE2_PID"
  DONE_COUNT=$(find "$PHASE2_TMP_DIR" -type f -name '*.rank' 2>/dev/null | wc -l | tr -d ' ')
  if [[ -t 1 ]]; then
    render_progress "$DONE_COUNT" "$READY_COUNT" "latency probe"
    printf "\n"
  else
    echo "  [phase2] completed $DONE_COUNT/$READY_COUNT regions."
  fi

  while IFS= read -r REGION; do
    out_file="${PHASE2_TMP_DIR}/${REGION}.rank"
    [[ -f "$out_file" ]] || continue
    if grep -q '^FILTERED|' "$out_file"; then
      FILTERED_MS=$(cut -d'|' -f3 < "$out_file")
      echo -e "  ${DIM}  ✗ $REGION — ${FILTERED_MS}ms (exceeds ${MAX_LATENCY_MS}ms limit)${NC}"
      continue
    fi
    cut -d'|' -f2- < "$out_file" >> "$RANKED_FILE"
  done < "$READY_FILE"

  RANKED_COUNT=0
  if [[ -f "$RANKED_FILE" ]]; then
    RANKED_COUNT=$(wc -l < "$RANKED_FILE" | tr -d ' ')
  fi
  FILTERED=$((READY_COUNT - RANKED_COUNT))
  if [[ "$FILTERED" -gt 0 ]]; then
    echo ""
    echo -e "  ${DIM}Filtered out $FILTERED region(s) with latency > ${MAX_LATENCY_MS}ms${NC}"
  fi

  # Sort: eviction_ratio ASC (col2), then latency ASC (col3)
  sort -t'|' -k2,2n -k3,3n "$RANKED_FILE" -o "$RANKED_FILE"
fi

# ═══════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} RESULTS${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# ── READY regions (with ranking) ─────────────────────────────────
if [[ "$READY_COUNT" -gt 0 ]]; then
  DISPLAY_COUNT="$READY_COUNT"
  if [[ -s "$RANKED_FILE" ]]; then
    DISPLAY_COUNT=$(wc -l < "$RANKED_FILE" | tr -d ' ')
  fi
  echo -e "  ${GREEN}${BOLD}READY TO DEPLOY ($DISPLAY_COUNT regions, latency ≤ ${MAX_LATENCY_MS}ms)${NC}"
  echo ""

  if [[ -s "$RANKED_FILE" ]]; then
    printf "  ${DIM}%-4s %-25s %10s %10s %12s %12s${NC}\n" \
      "RANK" "REGION" "EVICT_RISK" "LATENCY" "SPOT \$/h" "ON-DEM \$/h"
    printf "  ${DIM}%-4s %-25s %10s %10s %12s %12s${NC}\n" \
      "────" "─────────────────────────" "──────────" "──────────" "────────────" "────────────"

    RANK=0
    while IFS='|' read -r REGION RATIO LAT_MS SPOT_P OND_P; do
      RANK=$((RANK + 1))

      # Eviction risk label
      if (( $(echo "$RATIO < 0.10" | bc -l 2>/dev/null || echo 0) )); then
        RISK_LABEL="very low"
        RISK_COLOR="$GREEN"
      elif (( $(echo "$RATIO < 0.15" | bc -l 2>/dev/null || echo 0) )); then
        RISK_LABEL="low"
        RISK_COLOR="$GREEN"
      elif (( $(echo "$RATIO < 0.25" | bc -l 2>/dev/null || echo 0) )); then
        RISK_LABEL="medium"
        RISK_COLOR="$YELLOW"
      else
        RISK_LABEL="high"
        RISK_COLOR="$RED"
      fi

      if [[ "$RANK" -eq 1 ]]; then
        printf "  ${GREEN}${BOLD}#%-3d %-25s %10s %8sms \$%11s \$%11s  ◄ BEST${NC}\n" \
          "$RANK" "$REGION" "$RISK_LABEL" "$LAT_MS" "$SPOT_P" "$OND_P"
      else
        printf "  ${RISK_COLOR}#%-3d${NC} %-25s ${RISK_COLOR}%10s${NC} %8sms \$%11s \$%11s\n" \
          "$RANK" "$REGION" "$RISK_LABEL" "$LAT_MS" "$SPOT_P" "$OND_P"
      fi
    done < "$RANKED_FILE"
  else
    # No ranking data, just list regions
    while IFS='|' read -r REGION STATUS FQ FU SQ SU; do
      if [[ "$STATUS" == "READY" ]]; then
        FA=$((FQ - FU)); SA=$((SQ - SU))
        printf "  ${GREEN}%-25s${NC} family:%d/%d  spot:%d/%d\n" "$REGION" "$FA" "$FQ" "$SA" "$SQ"
      fi
    done < "$RESULTS_FILE"
  fi
  echo ""
fi

# ── Need quota increase ──────────────────────────────────────────
if [[ "$PRIORITY" == "spot" ]]; then
  FIXABLE_COUNT=$(grep -cE '\|(NO_SPOT_QUOTA|INSUF_SPOT)\|' "$RESULTS_FILE" || true)
else
  FIXABLE_COUNT=$(grep -cE '\|(NO_FAMILY_QUOTA|INSUF_FAMILY|NO_SPOT_QUOTA|INSUF_SPOT)\|' "$RESULTS_FILE" || true)
fi
if [[ "$FIXABLE_COUNT" -gt 0 ]]; then
  echo -e "  ${YELLOW}${BOLD}NEED QUOTA INCREASE ($FIXABLE_COUNT regions)${NC}"
  echo ""
  if [[ "$PRIORITY" == "spot" ]]; then
    printf "  ${DIM}%-25s %12s %-28s${NC}\n" "REGION" "SPOT_LIMIT" "ISSUE"
    printf "  ${DIM}%-25s %12s %-28s${NC}\n" "─────────────────────────" "────────────" "────────────────────────────"
  else
    printf "  ${DIM}%-25s %12s %12s %-28s${NC}\n" "REGION" "FAMILY_LIMIT" "SPOT_LIMIT" "ISSUE"
    printf "  ${DIM}%-25s %12s %12s %-28s${NC}\n" "─────────────────────────" "────────────" "────────────" "────────────────────────────"
  fi

  grep -E '\|(NO_FAMILY_QUOTA|INSUF_FAMILY|NO_SPOT_QUOTA|INSUF_SPOT)\|' "$RESULTS_FILE" | sort | while IFS='|' read -r REGION STATUS FQ FU SQ SU; do
    FA=$((FQ - FU)); SA=$((SQ - SU))
    case "$STATUS" in
      NO_FAMILY_QUOTA) ISSUE="Family quota = 0" ;;
      INSUF_FAMILY)    ISSUE="Family: need $VCPUS_NEEDED, have $FA" ;;
      NO_SPOT_QUOTA)   ISSUE="Spot quota = 0" ;;
      INSUF_SPOT)      ISSUE="Spot: need $VCPUS_NEEDED, have $SA" ;;
    esac
    # For spot mode, skip family-only issues (they were already filtered from FIXABLE_COUNT)
    if [[ "$PRIORITY" == "spot" && ("$STATUS" == "NO_FAMILY_QUOTA" || "$STATUS" == "INSUF_FAMILY") ]]; then
      continue
    fi
    if [[ "$PRIORITY" == "spot" ]]; then
      printf "  ${YELLOW}%-25s %12d %-28s${NC}\n" "$REGION" "$SQ" "$ISSUE"
    else
      printf "  ${YELLOW}%-25s %12d %12d %-28s${NC}\n" "$REGION" "$FQ" "$SQ" "$ISSUE"
    fi
  done
  echo ""
fi

# ── Not available ────────────────────────────────────────────────
RESTRICTED_COUNT=$(grep -c '|RESTRICTED|' "$RESULTS_FILE" || true)
NOT_AVAIL_COUNT=$(grep -c '|NOT_AVAILABLE|' "$RESULTS_FILE" || true)
UNAVAIL=$((RESTRICTED_COUNT + NOT_AVAIL_COUNT))
if [[ "$UNAVAIL" -gt 0 ]]; then
  echo -e "  ${DIM}NOT AVAILABLE ($UNAVAIL regions) — SKU not offered or restricted${NC}"
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# SUMMARY + RECOMMENDATION
# ═══════════════════════════════════════════════════════════════════
echo -e "${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} SUMMARY${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  VM:                  $VM_SIZE ($GPU_DESC)"
echo -e "  vCPUs needed:        $VCPUS_NEEDED"
echo -e "  Priority:            $PRIORITY"
echo ""
echo -e "  ${GREEN}Ready to deploy:${NC}     $READY_COUNT regions (quota OK)"
if [[ -s "$RANKED_FILE" ]]; then
  FINAL_COUNT=$(wc -l < "$RANKED_FILE" | tr -d ' ')
  FILTERED_OUT=$((READY_COUNT - FINAL_COUNT))
  if [[ "$FILTERED_OUT" -gt 0 ]]; then
    echo -e "  ${DIM}  └─ After latency filter:${NC} $FINAL_COUNT regions (≤ ${MAX_LATENCY_MS}ms)"
  fi
fi
echo -e "  ${YELLOW}Need quota bump:${NC}     $FIXABLE_COUNT regions"
echo -e "  ${DIM}Not available:${NC}       $UNAVAIL regions"
echo ""

if [[ "$READY_COUNT" -gt 0 ]]; then
  if [[ -s "$RANKED_FILE" ]]; then
    BEST_REGION=$(head -1 "$RANKED_FILE" | cut -d'|' -f1)
    BEST_RATIO=$(head -1 "$RANKED_FILE" | cut -d'|' -f2)
    BEST_LAT=$(head -1 "$RANKED_FILE" | cut -d'|' -f3)
    BEST_SPOT=$(head -1 "$RANKED_FILE" | cut -d'|' -f4)
  elif [[ "$SKIP_RANKING" == "1" ]]; then
    BEST_REGION=$(head -1 "$READY_FILE")
    BEST_LAT="N/A"
    BEST_SPOT="N/A"
  else
    # All READY regions were filtered out by latency
    echo -e "  ${YELLOW}${BOLD}All $READY_COUNT READY regions exceeded ${MAX_LATENCY_MS}ms latency.${NC}"
    echo ""
    echo -e "  Try increasing the limit: ${CYAN}MAX_LATENCY_MS=10000 $0 $VM_SIZE $PRIORITY${NC}"
    echo ""
    exit 1
  fi

  echo -e "  ${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
  echo -e "  ${GREEN}${BOLD}  RECOMMENDED REGION: $BEST_REGION${NC}"
  echo -e "  ${GREEN}${BOLD}══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Criteria: lowest eviction risk, then lowest latency (≤ ${MAX_LATENCY_MS}ms)"
  echo -e "  Latency:  ${BEST_LAT}ms    Spot price: \$${BEST_SPOT}/h"
  echo ""
  echo -e "  Set in ${CYAN}terraform/terraform.tfvars${NC}:"
  echo -e "    location = \"$BEST_REGION\""
  echo ""

  # Export for scripted use
  echo "$BEST_REGION" > /tmp/vllm_best_region 2>/dev/null || true

  exit 0

elif [[ "$FIXABLE_COUNT" -gt 0 ]]; then
  # Pick the first fixable region for the instructions
  BEST_FIXABLE=$(grep -E '\|(NO_FAMILY_QUOTA|INSUF_FAMILY|NO_SPOT_QUOTA|INSUF_SPOT)\|' "$RESULTS_FILE" | head -1 | cut -d'|' -f1)

  echo -e "  ${YELLOW}${BOLD}No region has sufficient quota. Request an increase:${NC}"
  echo ""
  echo -e "  ${CYAN}Azure Portal:${NC}"
  echo "    Subscriptions > $SUB_NAME > Usage + quotas"
  echo "    Search for the VM family and request $VCPUS_NEEDED vCPUs"
  if [[ "$PRIORITY" == "spot" ]]; then
    echo "    Also search for 'Total Regional Low-priority' and request $VCPUS_NEEDED vCPUs"
  fi
  echo ""
  echo -e "  ${CYAN}Azure CLI:${NC}"
  echo "    az quota create \\"
  echo "      --resource-name \"$FAMILY_FILTER\" \\"
  echo "      --scope \"/subscriptions/$SUB_ID/providers/Microsoft.Compute/locations/$BEST_FIXABLE\" \\"
  echo "      --limit-object value=$VCPUS_NEEDED \\"
  echo "      --resource-type dedicated"
  echo ""
  exit 1

else
  echo -e "  ${RED}${BOLD}$VM_SIZE is not available in any region for this subscription.${NC}"
  echo ""
  echo -e "  Try a different VM size:"
  for entry in "${VM_CATALOG[@]}"; do
    local_name=$(echo "$entry" | cut -d'|' -f1)
    local_gpu=$(echo "$entry" | cut -d'|' -f4)
    printf "    %-40s %s\n" "$local_name" "$local_gpu"
  done
  echo ""
  exit 2
fi
