resource "random_pet" "prefix" {}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "default" {
  name     = "${random_pet.prefix.id}-rg"
  location = "West US 2"

  tags = {
    environment = "Demo"
  }
}

resource "azurerm_virtual_network" "default" {
  name                = "${random_pet.prefix.id}-network"
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  address_space       = ["10.2.0.0/16"]
}

resource "azurerm_subnet" "default" {
  name                 = "${random_pet.prefix.id}-akssubnet"
  virtual_network_name = azurerm_virtual_network.default.name
  resource_group_name  = azurerm_resource_group.default.name
  address_prefixes     = ["10.2.0.0/22"]
}

resource "random_id" "log_analytics_workspace_name_suffix" {
    byte_length = 8
}

resource "azurerm_log_analytics_workspace" "default" {
    # The WorkSpace name has to be unique across the whole of azure, not just the current subscription/tenant.
    name                = "${random_pet.prefix.id}-${random_id.log_analytics_workspace_name_suffix.dec}"
    location            = azurerm_resource_group.default.location
    resource_group_name = azurerm_resource_group.default.name
    sku                 = var.log_analytics_workspace_sku
}

resource "azurerm_log_analytics_solution" "default" {
    solution_name         = "ContainerInsights"
    location              = azurerm_log_analytics_workspace.default.location
    resource_group_name   = azurerm_resource_group.default.name
    workspace_resource_id = azurerm_log_analytics_workspace.default.id
    workspace_name        = azurerm_log_analytics_workspace.default.name

    plan {
        publisher = "Microsoft"
        product   = "OMSGallery/ContainerInsights"
    }
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = "${random_pet.prefix.id}-aks"
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  dns_prefix          = "${random_pet.prefix.id}-k8s"

  linux_profile {
      admin_username = "azureuser"

      ssh_key {
          key_data = var.ssh_public_key
      }
  }

  default_node_pool {
    name                = "default"
    node_count          = 2
    vm_size             = "Standard_D2_v2"
    os_disk_size_gb     = 30
    #type                = "VirtualMachineScaleSets"
    availability_zones  = ["1", "2"]
    enable_auto_scaling = true
    min_count           = 2
    max_count           = 4

    # Required for advanced networking
    vnet_subnet_id = azurerm_subnet.default.id
  }

  service_principal {
    client_id     = var.appId
    client_secret = var.password
  }

  network_profile {
    network_plugin     = "azure"
    load_balancer_sku  = "standard"
    network_policy     = "azure"
  }

  role_based_access_control {
    enabled = true
  }

  azure_policy {
    enabled = true
  }

  addon_profile {
      oms_agent {
        enabled                    = true
        log_analytics_workspace_id = azurerm_log_analytics_workspace.default.id
      }
  }

  tags = {
    environment = "Demo"
  }
}
