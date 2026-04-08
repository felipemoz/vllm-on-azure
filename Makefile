.PHONY: help init plan deploy destroy test test-terraform test-k8s test-api test-bench test-gateway lint clean port-forward bench bench-quick bench-full apim-key apim-url apim-test check-quota check-quota-all

# ---------- Configuration ----------
VLLM_IMAGE       ?= vllm/vllm-openai:latest
VLLM_MODEL       ?= Qwen/Qwen3.5-122B-A10B
VLLM_GPU_COUNT   ?= 8
VLLM_MAX_MODEL_LEN ?= 32768
VLLM_REPLICAS    ?= 1
VLLM_URL         ?= http://localhost:8080
GATEWAY_IMAGE    ?= ghcr.io/vllm-on-azure/gateway:latest
VM_SIZE          ?= Standard_ND96amsr_A100_v4
TF_DIR           := terraform
K8S_DIR          := k8s

export VLLM_IMAGE VLLM_MODEL VLLM_GPU_COUNT VLLM_MAX_MODEL_LEN VLLM_REPLICAS GATEWAY_IMAGE VLLM_EXTRA_ARGS

# ---------- Default ----------
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------- Terraform ----------
init: ## Initialize Terraform
	terraform -chdir=$(TF_DIR) init -input=false

plan: init ## Plan infrastructure changes
	terraform -chdir=$(TF_DIR) plan -input=false

# ---------- Quota Check ----------
check-quota: ## Check GPU quota for VM_SIZE in all regions (ranked by eviction risk + latency)
	@bash scripts/check_quota.sh $(VM_SIZE) spot

check-quota-all: ## Check quota for ALL supported GPU VMs
	@for vm in Standard_ND96amsr_A100_v4 Standard_ND96isr_H100_v5 Standard_ND96asr_v4 Standard_NC96ads_A100_v4 Standard_ND96isr_MI300X_v5; do \
		echo ""; echo "━━━━━━━━━━━━━ $$vm ━━━━━━━━━━━━━"; \
		bash scripts/check_quota.sh $$vm spot || true; \
	done

# ---------- Deploy / Destroy ----------
deploy: ## Full deploy: infra + k8s (requires HF_TOKEN env var)
	@bash scripts/deploy.sh

destroy: ## Tear down everything
	@bash scripts/destroy.sh

# ---------- Docker ----------
docker-build: ## Build custom vLLM Docker image
	docker build -t vllm-on-azure:latest docker/

docker-build-gateway: ## Build gateway Docker image
	docker build -t vllm-gateway:latest docker/gateway/

docker-push: docker-build docker-build-gateway ## Push images to registry (set REGISTRY env var)
	@test -n "$(REGISTRY)" || (echo "ERROR: Set REGISTRY env var" && exit 1)
	docker tag vllm-on-azure:latest $(REGISTRY)/vllm-on-azure:latest
	docker push $(REGISTRY)/vllm-on-azure:latest
	docker tag vllm-gateway:latest $(REGISTRY)/vllm-gateway:latest
	docker push $(REGISTRY)/vllm-gateway:latest

# ---------- Testing ----------
test: test-terraform test-k8s test-bench test-gateway ## Run all tests

test-terraform: ## Validate Terraform configuration
	@bash tests/test_terraform.sh

test-k8s: ## Validate Kubernetes manifests
	@bash tests/test_k8s.sh

test-bench: ## Unit tests for benchmark tool
	@bash tests/test_benchmark.sh

test-gateway: ## Unit tests for gateway
	@bash tests/test_gateway.sh

test-api: ## Test vLLM API endpoint (requires running cluster + port-forward)
	@bash tests/test_vllm_api.sh

lint: ## Lint all config files
	terraform -chdir=$(TF_DIR) fmt -check -recursive
	terraform -chdir=$(TF_DIR) validate

# ---------- Utilities ----------
port-forward: ## Port-forward gateway to localhost:8080 (recommended)
	kubectl port-forward -n vllm svc/vllm-gateway 8080:8080

port-forward-direct: ## Port-forward vLLM directly to localhost:8000 (bypass gateway)
	kubectl port-forward -n vllm svc/vllm 8000:8000

logs: ## Stream vLLM pod logs
	kubectl logs -n vllm -l app.kubernetes.io/name=vllm -f --tail=100

logs-gateway: ## Stream gateway pod logs
	kubectl logs -n vllm -l app.kubernetes.io/name=vllm-gateway -f --tail=100

gateway-status: ## Show gateway status (backend health, eviction count)
	@kubectl port-forward -n vllm svc/vllm-gateway 8080:8080 &>/dev/null & PF_PID=$$!; \
	sleep 2; curl -s http://localhost:8080/gateway/status | python3 -m json.tool; \
	kill $$PF_PID 2>/dev/null || true

status: ## Show vLLM pod status
	kubectl get pods -n vllm -o wide

kubeconfig: ## Fetch AKS kubeconfig
	@RESOURCE_GROUP=$$(terraform -chdir=$(TF_DIR) output -raw resource_group_name) && \
	CLUSTER_NAME=$$(terraform -chdir=$(TF_DIR) output -raw cluster_name) && \
	az aks get-credentials --resource-group $$RESOURCE_GROUP --name $$CLUSTER_NAME --overwrite-existing

clean: ## Clean Terraform cache
	rm -rf $(TF_DIR)/.terraform $(TF_DIR)/.terraform.lock.hcl

# ---------- APIM ----------
apim-key: ## Show APIM API key
	@terraform -chdir=$(TF_DIR) output -raw apim_subscription_key

apim-url: ## Show APIM public URL
	@terraform -chdir=$(TF_DIR) output -raw apim_gateway_url

apim-test: ## Test APIM endpoint (requires deployed cluster + APIM)
	@APIM_URL=$$(terraform -chdir=$(TF_DIR) output -raw apim_gateway_url) && \
	APIM_KEY=$$(terraform -chdir=$(TF_DIR) output -raw apim_subscription_key) && \
	echo "Testing $$APIM_URL/v1/models ..." && \
	curl -s "$$APIM_URL/v1/models" -H "api-key: $$APIM_KEY" | python3 -m json.tool

# ---------- Benchmark ----------
bench-deps: ## Install benchmark dependencies
	pip install -r benchmark/requirements.txt

bench-quick: ## Quick benchmark (low concurrency, few requests)
	python3 benchmark/bench.py \
		--url $(VLLM_URL) --model $(VLLM_MODEL) --vm-size $(VM_SIZE) \
		--num-gpus $(VLLM_GPU_COUNT) \
		--concurrency 1 4 --num-requests 8 --isl 128 --osl 64

bench: ## Standard benchmark (multiple concurrency levels)
	python3 benchmark/bench.py \
		--url $(VLLM_URL) --model $(VLLM_MODEL) --vm-size $(VM_SIZE) \
		--num-gpus $(VLLM_GPU_COUNT) \
		--concurrency 1 4 16 32 --num-requests 32 --isl 512 --osl 128 \
		--output benchmark_report.json

bench-full: ## Full benchmark (high concurrency, large sequences)
	python3 benchmark/bench.py \
		--url $(VLLM_URL) --model $(VLLM_MODEL) --vm-size $(VM_SIZE) \
		--num-gpus $(VLLM_GPU_COUNT) \
		--concurrency 1 4 8 16 32 64 --num-requests 64 --isl 1024 --osl 512 \
		--output benchmark_report_full.json
