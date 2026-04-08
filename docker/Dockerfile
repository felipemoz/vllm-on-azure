FROM vllm/vllm-openai:latest

LABEL maintainer="vllm-on-azure"
LABEL description="vLLM OpenAI-compatible server on Azure AKS with GPUs"

ENV VLLM_USAGE_SOURCE="production"

EXPOSE 8000

ENTRYPOINT ["python3", "-m", "vllm.entrypoints.openai.api_server"]
