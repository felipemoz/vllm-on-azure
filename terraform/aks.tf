resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name                        = "system"
    node_count                  = var.system_node_count
    vm_size                     = var.system_node_vm_size
    vnet_subnet_id              = azurerm_subnet.aks.id
    os_disk_size_gb             = 50
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    service_cidr      = "10.1.0.0/16"
    dns_service_ip    = "10.1.0.10"
  }

  tags = var.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  name                  = "gpu"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.gpu_node_vm_size
  node_count            = var.gpu_node_count
  min_count             = var.gpu_node_min_count
  max_count             = var.gpu_node_max_count
  auto_scaling_enabled  = true
  os_disk_size_gb       = var.gpu_node_disk_size_gb
  vnet_subnet_id        = azurerm_subnet.aks.id

  # Spot instance configuration
  priority        = var.gpu_spot_enabled ? "Spot" : "Regular"
  eviction_policy = var.gpu_spot_enabled ? var.gpu_spot_eviction_policy : null
  spot_max_price  = var.gpu_spot_enabled ? var.gpu_spot_max_price : null

  node_labels = {
    "hardware" = "gpu"
    "gpu-type" = "a100"
  }

  node_taints = [
    "nvidia.com/gpu=present:NoSchedule"
  ]

  tags = var.tags
}
