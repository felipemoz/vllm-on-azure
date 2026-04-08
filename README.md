# vLLM on Azure AKS

Deploy [Qwen3.5-122B-A10B](https://huggingface.co/Qwen/Qwen3.5-122B-A10B) via [vLLM](https://docs.vllm.ai/) no Azure Kubernetes Service com A100 GPUs (Spot instances), benchmark inference no estilo [InferenceX](https://inferencex.semianalysis.com/inference), e endpoint publico via Azure API Management com API key + rate limiting.

## TL;DR

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# editar subscription_id e apim_name

export HF_TOKEN="hf_..."
make deploy        # sobe AKS + 8x A100 Spot + vLLM + APIM (~15 min)
make apim-test     # testa endpoint publico com API key
make bench         # benchmark tokens/s estilo InferenceX
make destroy       # derruba tudo
```

**O que voce ganha:** Qwen3.5-122B-A10B (MoE, 122B params, 10B ativos) rodando em 8x A100 80GB Spot a **~$4.23/h** (vs $32.77 on-demand, **87% de economia**), com endpoint HTTPS publico protegido por API key + rate limiting, e resiliencia automatica a eviccao de Spot ("trocando o pneu do aviao voando").

## Modelo: Qwen3.5-122B-A10B

| Propriedade | Valor |
|-------------|-------|
| **Arquitetura** | Mixture-of-Experts (MoE) + Gated DeltaNet |
| **Parametros totais** | 122B |
| **Parametros ativos** | 10B por token |
| **Experts** | 256 total, 8 routed + 1 shared = 9 ativos |
| **Contexto nativo** | 262,144 tokens |
| **Contexto estendido** | 1,010,000 tokens (YaRN) |
| **GPUs necessarias** | 8x A100 (tensor parallelism) |
| **VM recomendada** | `Standard_ND96amsr_A100_v4` (8x A100 80GB) |

> MoE significa que apesar de ter 122B parametros, apenas ~10B sao ativados por token, resultando em throughput comparavel a modelos menores com qualidade de modelo grande.

## Arquitetura

```
                 Internet
                    |
                    v
         +------------------+
         |  Azure APIM      |  API key + rate limiting
         |  (Consumption)   |  100 req/min (configuravel)
         +--------+---------+
                  | HTTPS
                  v
+----------------------------------------------+
|              Azure Resource Group             |
|                                               |
|  +------------------------------------------+ |
|  |             AKS Cluster                   | |
|  |                                           | |
|  |  +--------------+  +-------------------+  | |
|  |  | System Pool  |  | GPU Pool (Spot)   |  | |
|  |  | D4s_v5 (x2)  |  | ND96amsr (8xA100) |  | |
|  |  |              |  +---------+---------+  | |
|  |  | +----------+ |           |             | |
|  |  | | Gateway  |<+-----------+             | |
|  |  | | (2 repl) | |           v             | |
|  |  | +----------+ |  +---------------+     | |
|  |  |              |  | vLLM Server   |     | |
|  |  |              |  | Qwen3.5-122B  |     | |
|  |  |              |  | 8x A100 80GB  |     | |
|  |  |              |  | tp=8          |     | |
|  |  +--------------+  +---------------+     | |
|  +------------------------------------------+ |
+----------------------------------------------+
```

**Gateway** roda nos system nodes (non-Spot). Se o GPU node for evicted, retorna `503` com "Perae que estamos trocando o pneu do aviao voando" enquanto o autoscaler provisiona um novo node.

## Pre-requisitos

- [Terraform](https://www.terraform.io/) >= 1.5
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) (`az login` feito)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Python 3.9+](https://www.python.org/) (para benchmark)
- Token do [HuggingFace](https://huggingface.co/settings/tokens) (`HF_TOKEN`)
- **Quota** para `Standard_ND96amsr_A100_v4` na sua subscription (solicitar via Azure Portal se necessario)

## Quick Start

### 1. Configurar

```bash
cd vllm-on-azure

# Copiar e editar variaveis
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Editar terraform/terraform.tfvars com seu subscription_id e apim_name (globalmente unico)
```

### 2. Deploy (um comando)

```bash
export HF_TOKEN="hf_your_token_here"
make deploy
```

Isso executa automaticamente:
1. `terraform init` + `terraform apply` (Resource Group, VNet, AKS, GPU Spot, APIM)
2. Instala NVIDIA device plugin no cluster
3. Cria namespace `vllm`, secrets, PVC, deployment e services
4. Deploya o **gateway** resiliente (proxy nos system nodes)
5. Aguarda rollout (10-20 min para download + load do modelo 122B)
6. Configura o APIM backend com o IP do LoadBalancer
7. Exibe a **URL publica** e a **API key**

### 3. Acessar a API

```bash
# -- Via APIM (publico, com API key) --
make apim-url
make apim-key
make apim-test

# Manualmente:
curl https://apim-vllm-myproject.azure-api.net/v1/models \
  -H "api-key: SUA_API_KEY"

curl https://apim-vllm-myproject.azure-api.net/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "api-key: SUA_API_KEY" \
  -d '{
    "model": "Qwen/Qwen3.5-122B-A10B",
    "messages": [{"role": "user", "content": "Explain quantum computing"}],
    "max_tokens": 256
  }'

# -- Via port-forward (local, sem API key) --
make port-forward
curl http://localhost:8080/v1/models

# -- Status do gateway (eviction count, backend health) --
curl http://localhost:8080/gateway/status
```

### 4. Benchmark

```bash
make bench-deps     # instalar dependencias
make bench-quick    # smoke test
make bench          # benchmark padrao
make bench-full     # benchmark completo
```

### 5. Destruir

```bash
make destroy
```

## Estrutura do Projeto

```
vllm-on-azure/
├── Makefile                          # Ponto de entrada: make deploy / make bench
├── terraform/
│   ├── providers.tf                  # Azure provider v4
│   ├── variables.tf                  # Tudo parametrizado (GPU, Spot, APIM, modelo)
│   ├── main.tf                       # Resource Group
│   ├── network.tf                    # VNet + Subnet
│   ├── aks.tf                        # AKS + GPU node pool (Spot)
│   ├── apim.tf                       # API Management (Consumption) + policies
│   ├── outputs.tf                    # kubeconfig, APIM URL, API key
│   └── terraform.tfvars.example      # Exemplo de configuracao
├── k8s/
│   ├── namespace.yaml                # Namespace "vllm"
│   ├── pvc.yaml                      # PVC para cache do modelo
│   ├── vllm-deployment.yaml          # Deployment: 8x A100, reasoning-parser qwen3
│   ├── vllm-service.yaml             # ClusterIP (interno, pro gateway)
│   ├── gateway-deployment.yaml       # Gateway resiliente (system nodes)
│   ├── gateway-service.yaml          # ClusterIP + public LoadBalancer
│   └── pdb.yaml                      # PodDisruptionBudget do gateway
├── docker/
│   ├── Dockerfile                    # vLLM customizado
│   └── gateway/
│       ├── Dockerfile                # Gateway image (python:slim)
│       └── gateway.py                # Reverse proxy com eviction handling
├── benchmark/
│   ├── bench.py                      # Benchmark tool (InferenceX-style)
│   └── requirements.txt              # aiohttp
├── scripts/
│   ├── deploy.sh                     # Deploy completo (infra + k8s + APIM)
│   └── destroy.sh                    # Teardown completo
└── tests/
    ├── test_terraform.sh             # Valida Terraform
    ├── test_k8s.sh                   # Valida manifests K8s
    ├── test_benchmark.sh             # Testes unitarios do benchmark
    ├── test_gateway.sh               # Testes unitarios do gateway
    └── test_vllm_api.sh              # Testa API live
```

## GPU VMs Disponiveis (A100)

Configuravel via `gpu_node_vm_size` no `terraform.tfvars`:

| VM Size | GPUs | VRAM | vCPUs | RAM | Spot $/h | On-Demand $/h | Economia |
|---------|------|------|-------|-----|----------|---------------|----------|
| `Standard_NC24ads_A100_v4` | 1x A100 | 80GB | 24 | 220GB | $0.678 | $3.673 | ~81% |
| `Standard_NC48ads_A100_v4` | 2x A100 | 160GB | 48 | 440GB | $1.358 | $7.346 | ~82% |
| `Standard_NC96ads_A100_v4` | 4x A100 | 320GB | 96 | 880GB | $2.715 | $14.692 | ~82% |
| `Standard_ND96asr_v4` | 8x A100 | 320GB (40GB each) | 96 | 900GB | $3.366 | $27.197 | ~88% |
| **`Standard_ND96amsr_A100_v4`** | **8x A100** | **640GB (80GB each)** | **96** | **1900GB** | **$4.234** | **$32.770** | **~87%** |

> Precos de referencia para East US. A VM **ND96amsr** e a recomendada para o Qwen3.5-122B-A10B.

### Qual VM escolher?

| Modelo | Parametros | GPUs | VM Recomendada |
|--------|-----------|------|----------------|
| Mistral-7B, Qwen2-7B | 7B | 1 | `Standard_NC24ads_A100_v4` |
| Llama-3.1-70B | 70B | 4 | `Standard_NC96ads_A100_v4` |
| **Qwen3.5-122B-A10B** | **122B MoE** | **8** | **`Standard_ND96amsr_A100_v4`** |

## Spot Instances

Por padrao o deploy usa **Azure Spot VMs** (~87% mais baratas para ND96amsr). Configuravel no `terraform.tfvars`:

```hcl
gpu_spot_enabled         = true     # false para on-demand
gpu_spot_max_price       = -1       # -1 = ate o preco on-demand
gpu_spot_eviction_policy = "Delete" # ou "Deallocate"
```

O autoscaler esta habilitado com `min_count = 0`, entao apos eviccao o pool escala de volta automaticamente.

## Gateway Resiliente (Eviction Handling)

Como usamos Spot VMs, a Azure pode evictar o node GPU a qualquer momento. Para garantir uma experiencia suave, um **gateway** roda nos system nodes (non-Spot, sempre disponiveis):

```
Client --> APIM --> Gateway (system nodes, 2 replicas) --> vLLM (Spot GPU node)
                       |                                       |
                       | se vLLM esta DOWN:                    | eviccao!
                       | retorna 503 + mensagem amigavel       |
                       |                                       |
                       | quando vLLM volta:                    v
                       | roteia normalmente              novo Spot node
```

### Como funciona

1. O gateway faz health checks a cada 3s no vLLM (`/health`)
2. Quando o vLLM esta **healthy**, faz proxy transparente (incluindo streaming SSE)
3. Quando o vLLM cai (eviccao), retorna **HTTP 503** com mensagem amigavel:

```json
{
  "error": {
    "message": "Perae que estamos trocando o pneu do aviao voando. O modelo esta sendo recarregado em uma nova instancia. Tente novamente em alguns instantes.",
    "type": "server_error",
    "code": "model_reloading"
  },
  "status": {
    "eviction_count": 2,
    "down_since": 1712345678.0
  }
}
```

4. Se a eviccao acontece **no meio de um streaming**, o gateway injeta um erro SSE antes de fechar
5. O autoscaler do AKS provisiona um novo Spot node, o vLLM sobe, o gateway detecta e volta a rotear

### Monitorar eviccoes

```bash
curl http://localhost:8080/gateway/status

# Resposta:
{
  "gateway": "ok",
  "backend_healthy": true,
  "eviction_count": 3,
  "evicted_at": 1712345678.0,
  "recovered_at": 1712345890.0,
  "upstream": "http://vllm:8000"
}
```

## Azure API Management (APIM)

O APIM fornece um **endpoint publico HTTPS** com autenticacao via API key e rate limiting. Usa o tier **Consumption** (sem custo fixo, paga por chamada).

### Configuracao

No `terraform.tfvars`:

```hcl
apim_enabled           = true
apim_name              = "apim-vllm-myproject"  # globalmente unico
apim_publisher_name    = "vLLM Admin"
apim_publisher_email   = "admin@example.com"
apim_rate_limit_calls  = 100   # max chamadas por periodo
apim_rate_limit_period = 60    # periodo em segundos
```

### Autenticacao

Todas as chamadas via APIM exigem o header `api-key`:

```bash
curl https://apim-vllm-myproject.azure-api.net/v1/models \
  -H "api-key: SUA_CHAVE_AQUI"
```

Para obter a chave:

```bash
make apim-key
# ou
terraform -chdir=terraform output -raw apim_subscription_key
```

### Rate Limiting

- **Default**: 100 chamadas por 60 segundos
- Configuravel via `apim_rate_limit_calls` e `apim_rate_limit_period`
- Exceder o limite retorna `HTTP 429 Too Many Requests`
- Header `X-RateLimit-Limit` incluido nas respostas

### Desabilitar APIM

```hcl
apim_enabled = false
```

## Benchmark Tool

O benchmark mede metricas no estilo [InferenceX by SemiAnalysis](https://inferencex.semianalysis.com/inference), usando streaming via API OpenAI-compatible do vLLM.

### Metricas

| Metrica | Descricao |
|---------|-----------|
| **TTFT** | Time To First Token - latencia ate o primeiro token (avg, p50, p90, p99) |
| **ITL** | Inter-Token Latency - tempo entre tokens consecutivos (avg, p50, p90, p99) |
| **Output tok/s** | Throughput de tokens gerados por segundo |
| **Input tok/s** | Throughput de tokens de entrada processados por segundo |
| **Total tok/s** | Throughput total (input + output) |
| **Req/s** | Requests completados por segundo |
| **$/1M tokens** | Custo por milhao de tokens (Spot e On-Demand) |

### Uso direto (CLI)

```bash
python3 benchmark/bench.py \
  --url http://localhost:8080 \
  --model Qwen/Qwen3.5-122B-A10B \
  --vm-size Standard_ND96amsr_A100_v4 \
  --num-gpus 8 \
  --concurrency 1 4 16 32 \
  --num-requests 32 \
  --isl 512 \
  --osl 128 \
  --output report.json
```

### Parametros

| Argumento | Default | Descricao |
|-----------|---------|-----------|
| `--url` | `http://localhost:8000` | URL do servidor vLLM |
| `--model` | `Qwen/Qwen3.5-122B-A10B` | Modelo servido |
| `--vm-size` | `Standard_ND96amsr_A100_v4` | VM para calculo de custo |
| `--num-gpus` | `8` | Quantidade de GPUs (para calculo de custo) |
| `--concurrency` | `1 4 16 32` | Niveis de concorrencia a testar |
| `--num-requests` | `32` | Requests por nivel de concorrencia |
| `--isl` | `512` | Input Sequence Length (tokens de entrada) |
| `--osl` | `128` | Output Sequence Length (max_tokens) |
| `--warmup` | `2` | Requests de warmup antes do benchmark |
| `--output` | - | Caminho para exportar JSON |

### Exemplo de Output

```
============================================================
 vLLM BENCHMARK (InferenceX-style)
============================================================
  URL:       http://localhost:8080
  Model:     Qwen/Qwen3.5-122B-A10B
  VM:        Standard_ND96amsr_A100_v4
  ISL:       512
  OSL:       128
  Requests:  32 per concurrency level
  Levels:    [1, 4, 16, 32]

Sending 2 warmup requests...
Warmup complete.

Running benchmark with concurrency=32...

============================================================
 vLLM BENCHMARK REPORT (InferenceX-style)
============================================================

Model:                         Qwen/Qwen3.5-122B-A10B
VM Size:                       Standard_ND96amsr_A100_v4
Concurrency:                   32
Requests:                      32/32
ISL (input seq len):           512
OSL (output seq len):          128
Total Duration:                3.85s

------------------------------------------------------------
 LATENCY
------------------------------------------------------------
  Metric                        Avg      P50      P90      P99
  TTFT (ms)                   210.5    195.3    380.2    520.1
  ITL (ms)                     15.2     14.1     18.5     28.3

------------------------------------------------------------
 THROUGHPUT
------------------------------------------------------------
  Output Tokens/s:                1065.4
  Input Tokens/s:                 4261.6
  Total Tokens/s:                 5327.0
  Requests/s:                        8.31

------------------------------------------------------------
 COST (Azure Spot vs On-Demand)
------------------------------------------------------------
  Spot $/hour:                 $    4.234
  On-Demand $/hour:            $   32.770
  Spot savings:                     87.1%
  Spot $/1M tokens:            $   0.2209
  On-Demand $/1M tokens:       $   1.7098

============================================================

================================================================================
 SUMMARY ACROSS CONCURRENCY LEVELS
================================================================================
   Conc  Out tok/s   TTFT p50   TTFT p99    ITL p50    Req/s   Spot $/1Mt
  ----- ---------- ---------- ---------- ---------- -------- ------------
      1       52.3       48.2       95.1       14.1     0.41  $     2.2497
      4      198.5       55.8      120.4       14.5     1.55  $     0.5924
     16      620.1      110.3      290.7       15.8     4.84  $     0.1896
     32     1065.4      195.3      520.1       14.1     8.31  $     0.1104

Report exported to benchmark_report.json
```

### Output JSON

O `--output report.json` gera:

```json
{
  "config": {
    "model": "Qwen/Qwen3.5-122B-A10B",
    "vm_size": "Standard_ND96amsr_A100_v4",
    "concurrency": 32,
    "num_requests": 32,
    "input_seq_len": 512,
    "output_seq_len": 128
  },
  "latency": {
    "ttft_ms": { "avg": 210.5, "p50": 195.3, "p90": 380.2, "p99": 520.1 },
    "itl_ms":  { "avg": 15.2,  "p50": 14.1,  "p90": 18.5,  "p99": 28.3 }
  },
  "throughput": {
    "output_tokens_per_sec": 1065.4,
    "input_tokens_per_sec": 4261.6,
    "total_tokens_per_sec": 5327.0,
    "requests_per_sec": 8.31
  },
  "cost": {
    "spot_cost_per_hour": 4.234,
    "ondemand_cost_per_hour": 32.770,
    "spot_cost_per_1m_tokens": 0.2209,
    "ondemand_cost_per_1m_tokens": 1.7098,
    "spot_savings_pct": 87.1
  },
  "totals": {
    "total_input_tokens": 16384,
    "total_output_tokens": 4096,
    "total_duration_sec": 3.85,
    "successful_requests": 32,
    "failed_requests": 0
  }
}
```

## Comandos do Makefile

```bash
make help           # Lista todos os comandos disponiveis
```

| Comando | Descricao |
|---------|-----------|
| **Deploy** | |
| `make deploy` | Deploy completo: infra + k8s + gateway + APIM (requer `HF_TOKEN`) |
| `make destroy` | Destroi tudo (infra + k8s + APIM) |
| `make plan` | Mostra o plano do Terraform |
| **APIM** | |
| `make apim-url` | Mostra a URL publica do APIM |
| `make apim-key` | Mostra a API key do APIM |
| `make apim-test` | Testa o endpoint APIM |
| **Testes** | |
| `make test` | Roda todos os testes (terraform + k8s + benchmark + gateway) |
| `make lint` | Valida formatacao e sintaxe do Terraform |
| `make test-api` | Testa API live (requer cluster rodando) |
| **Benchmark** | |
| `make bench-quick` | Benchmark rapido (concurrency 1,4 / 8 requests) |
| `make bench` | Benchmark padrao (concurrency 1,4,16,32 / 32 requests) |
| `make bench-full` | Benchmark completo (concurrency 1-64 / 64 requests) |
| `make bench-deps` | Instala dependencias Python do benchmark |
| **Utilitarios** | |
| `make port-forward` | Port-forward do gateway para localhost:8080 |
| `make port-forward-direct` | Port-forward direto do vLLM para localhost:8000 |
| `make logs` | Stream dos logs do pod vLLM |
| `make logs-gateway` | Stream dos logs do gateway |
| `make gateway-status` | Status do gateway (eviccoes, backend health) |
| `make status` | Status dos pods no namespace vllm |
| `make docker-build` | Build da imagem Docker do vLLM customizado |
| `make docker-build-gateway` | Build da imagem Docker do gateway |

## Testes

```bash
# Todos os testes (offline, nao requer cluster)
make test

# Testes individuais
make test-terraform   # Valida fmt, validate, arquivos, variaveis
make test-k8s         # Valida YAML, GPU resources, probes, tolerations, gateway
make test-bench       # Testa syntax, metricas, percentile, cost, JSON export
make test-gateway     # Testa syntax, eviction handling, streaming, state logic

# Teste da API (requer cluster rodando + port-forward)
make test-api
```

## Trocar o Modelo

O projeto foi configurado para o Qwen3.5-122B-A10B, mas qualquer modelo compativel com vLLM pode ser usado:

```bash
# Modelo menor (1 GPU)
export VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
export VLLM_GPU_COUNT=1
# Trocar VM no terraform.tfvars: gpu_node_vm_size = "Standard_NC24ads_A100_v4"
make deploy

# Modelo medio (4 GPUs)
export VLLM_MODEL="meta-llama/Llama-3.1-70B-Instruct"
export VLLM_GPU_COUNT=4
# Trocar VM: gpu_node_vm_size = "Standard_NC96ads_A100_v4"
make deploy

# Voltar para Qwen 122B (8 GPUs, default)
export VLLM_MODEL="Qwen/Qwen3.5-122B-A10B"
export VLLM_GPU_COUNT=8
# Trocar VM: gpu_node_vm_size = "Standard_ND96amsr_A100_v4"
make deploy
```

## Contexto Estendido (ate 1M tokens)

O Qwen3.5-122B-A10B suporta ate 1,010,000 tokens via YaRN. Para habilitar, adicione as flags extras no deployment:

```bash
# No vllm-deployment.yaml, adicionar aos args:
# - "--hf-overrides"
# - '{"text_config": {"rope_parameters": {"mrope_interleaved": true, "mrope_section": [11, 11, 10], "rope_type": "yarn", "rope_theta": 10000000, "partial_rotary_factor": 0.25, "factor": 4.0, "original_max_position_embeddings": 262144}}}'
# - "--max-model-len"
# - "1010000"
# Tambem setar env: VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
```

> Contextos muito longos consomem mais VRAM para KV cache. Comece com 32K e aumente gradualmente.

## Troubleshooting

```bash
# Ver status dos pods
make status

# Ver logs do vLLM
make logs

# Ver logs do gateway
make logs-gateway

# Verificar se GPU nodes estao prontos
kubectl get nodes -l hardware=gpu

# Verificar GPUs disponiveis no node
kubectl describe node -l hardware=gpu | grep nvidia.com/gpu

# Verificar se NVIDIA device plugin esta rodando
kubectl get pods -n kube-system -l app.kubernetes.io/component=nvidia-device-plugin

# Descrever pod com problema
kubectl describe pod -n vllm -l app.kubernetes.io/name=vllm

# Quota insuficiente (erro ao criar GPU node pool)
# Solicitar aumento de quota no Azure Portal:
# Subscriptions > your-sub > Usage + quotas > procurar "ND96amsr"

# APIM nao responde
make apim-test

# Backend do APIM desatualizado (IP mudou apos eviccao)
RESOURCE_GROUP=$(terraform -chdir=terraform output -raw resource_group_name)
APIM_NAME=$(terraform -chdir=terraform output -raw apim_name)
LB_IP=$(kubectl get svc vllm-gateway-lb -n vllm -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
az apim api update --resource-group $RESOURCE_GROUP --service-name $APIM_NAME \
  --api-id vllm-inference --service-url "http://$LB_IP:80"
```
