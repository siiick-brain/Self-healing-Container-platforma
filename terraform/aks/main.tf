terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.51.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant ID for cluster authentication."
}

resource "azurerm_resource_group" "platform" {
  name     = "rg-self-healing"
  location = var.location
}

resource "azurerm_kubernetes_cluster" "platform" {
  name                              = "aks-self-healing"
  location                          = azurerm_resource_group.platform.location
  resource_group_name               = azurerm_resource_group.platform.name
  dns_prefix                        = "self-healing"
  sku_tier                          = "Free"
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  default_node_pool {
    name       = "system"
    node_count = 2
    vm_size    = "Standard_D4s_v5"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.96.0.0/16"
    dns_service_ip      = "10.96.0.10"
  }
}
