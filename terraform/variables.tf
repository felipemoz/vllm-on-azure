variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-vllm-aks"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
  default     = "aks-vllm"
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS"
  type        = string
  default     = "1.34"
}

# --- System Node Pool ---

variable "system_node_vm_size" {
  description = "VM size for the system node pool"
  type        = string
  default     = "Standard_D4s_v5"
}

variable "system_node_count" {
  description = "Number of nodes in the system pool"
  type        = number
  default     = 2
}

# --- GPU Node Pool ---

variable "gpu_node_vm_size" {
  description = "VM size for the GPU node pool (A100 series)"
  type        = string
  default     = "Standard_ND96amsr_A100_v4" # 8x A100 80GB (for Qwen3.5-122B-A10B)
  # Options:
  #   Standard_NC24ads_A100_v4   -> 1x A100 80GB,  24 vCPU,  220 GB RAM
  #   Standard_NC48ads_A100_v4   -> 2x A100 80GB,  48 vCPU,  440 GB RAM
  #   Standard_NC96ads_A100_v4   -> 4x A100 80GB,  96 vCPU,  880 GB RAM
  #   Standard_ND96asr_v4        -> 8x A100 40GB,  96 vCPU,  900 GB RAM
  #   Standard_ND96amsr_A100_v4  -> 8x A100 80GB,  96 vCPU,  1900 GB RAM (recommended for 122B MoE)
}

variable "gpu_node_count" {
  description = "Number of GPU nodes"
  type        = number
  default     = 1
}

variable "gpu_node_min_count" {
  description = "Minimum GPU nodes for autoscaling (0 to scale to zero)"
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  description = "Maximum GPU nodes for autoscaling"
  type        = number
  default     = 3
}

variable "gpu_node_disk_size_gb" {
  description = "OS disk size for GPU nodes in GB"
  type        = number
  default     = 128
}

variable "gpu_spot_enabled" {
  description = "Use Azure Spot instances for GPU nodes (significantly cheaper, but can be evicted)"
  type        = bool
  default     = true
}

variable "gpu_spot_max_price" {
  description = "Maximum price per hour for Spot GPU nodes (-1 = up to on-demand price)"
  type        = number
  default     = -1
}

variable "gpu_spot_eviction_policy" {
  description = "Eviction policy for Spot nodes: Delete or Deallocate"
  type        = string
  default     = "Delete"

  validation {
    condition     = contains(["Delete", "Deallocate"], var.gpu_spot_eviction_policy)
    error_message = "Must be Delete or Deallocate."
  }
}

# --- vLLM Settings ---

variable "vllm_model" {
  description = "HuggingFace model ID to serve"
  type        = string
  default     = "Qwen/Qwen3.5-122B-A10B"
}

variable "vllm_gpu_count" {
  description = "Number of GPUs per vLLM instance (tensor parallelism)"
  type        = number
  default     = 8
}

variable "vllm_max_model_len" {
  description = "Maximum model context length"
  type        = number
  default     = 32768
}

variable "vllm_replicas" {
  description = "Number of vLLM pod replicas"
  type        = number
  default     = 1
}

# --- Networking ---

variable "vnet_address_space" {
  description = "Address space for the VNet"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_address_prefixes" {
  description = "Address prefixes for the AKS subnet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

# --- API Management ---

variable "apim_enabled" {
  description = "Enable Azure API Management (Consumption tier) for public endpoint with API key"
  type        = bool
  default     = true
}

variable "apim_name" {
  description = "Name of the APIM instance (must be globally unique)"
  type        = string
  default     = "apim-vllm"
}

variable "apim_publisher_name" {
  description = "APIM publisher name"
  type        = string
  default     = "vLLM Admin"
}

variable "apim_publisher_email" {
  description = "APIM publisher email"
  type        = string
  default     = "admin@example.com"
}

variable "apim_rate_limit_calls" {
  description = "Max API calls per renewal period (rate limiting)"
  type        = number
  default     = 100
}

variable "apim_rate_limit_period" {
  description = "Rate limit renewal period in seconds"
  type        = number
  default     = 60
}

# --- Tags ---

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    project    = "vllm-on-azure"
    managed_by = "terraform"
  }
}
