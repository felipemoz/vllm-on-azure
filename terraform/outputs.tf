output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "cluster_fqdn" {
  value = azurerm_kubernetes_cluster.this.fqdn
}

output "kube_config_raw" {
  value     = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive = true
}

output "gpu_node_pool_vm_size" {
  value = azurerm_kubernetes_cluster_node_pool.gpu.vm_size
}

# --- APIM ---

output "apim_enabled" {
  value = var.apim_enabled
}

output "apim_gateway_url" {
  value = var.apim_enabled ? azurerm_api_management.this[0].gateway_url : ""
}

output "apim_name" {
  value = var.apim_enabled ? azurerm_api_management.this[0].name : ""
}

output "apim_subscription_key" {
  value     = var.apim_enabled ? azurerm_api_management_subscription.vllm[0].primary_key : ""
  sensitive = true
}
