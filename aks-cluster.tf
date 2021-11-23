resource "random_pet" "prefix" {}

provider "azurerm" {
  features {}
}

#####################################################################
# Resource Group
#####################################################################
resource "azurerm_resource_group" "default" {
  name     = "${random_pet.prefix.id}-rg"
  location = "West US 2"

  tags = {
    environment = "Demo"
  }
}

#####################################################################
# VNet and AKS Subnet
#####################################################################
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

resource "azurerm_subnet" "appgw" {
  name                 = "${random_pet.prefix.id}-agicsubnet"
  virtual_network_name = azurerm_virtual_network.default.name
  resource_group_name  = azurerm_resource_group.default.name
  address_prefixes     = ["10.2.4.0/24"]
}

resource "random_id" "log_analytics_workspace_name_suffix" {
    byte_length = 8
}

#####################################################################
# Log Analytics workspace solution for AKS (Container Insights, etc.)
#####################################################################
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

#####################################################################
# Azure Policy assignment
#####################################################################
resource "azurerm_resource_group_policy_assignment" "auditaks" {
    name                  = "audit-aks"
    resource_group_id     = azurerm_resource_group.default.id
    policy_definition_id  = var.azure_policy_k8s_initiative
}

#####################################################################
# Create AAD security group for aks admins, append IDs to k8s RBAC
#####################################################################
/*
resource "azuread_group" "aks_administrators" {
  display_name     = "${random_pet.prefix.id}-aks-admins"
  mail_enabled     = false
  security_enabled = false
  mail_nickname    = "${random_pet.prefix.id}-aks-admins"
  description      = "Kubernetes administrators for the ${random_pet.prefix.id} cluster."
}
*/

#####################################################################
# Let's create the AKS Cluster
#####################################################################
resource "azurerm_kubernetes_cluster" "default" {
  name                = "${random_pet.prefix.id}-aks"
  location            = azurerm_resource_group.default.location
  resource_group_name = azurerm_resource_group.default.name
  dns_prefix          = "${random_pet.prefix.id}-k8s"

  linux_profile {
      admin_username = "azureuser"

      ssh_key {
          key_data   = var.ssh_public_key
      }
  }

  windows_profile {
    admin_username = "azureuser"
    admin_password = var.windowspassword
  }

/*
  # Planned Maintenance window
  maintenance_window {
    allowed {
      day = "Saturday"
      hours = 21-23
    }
    allowed {
      day = "Sunday"
      hours = 21-23
    }
    not_allowed {
      start = "2022-05-26T03:00:00Z"
      end = "2022-05-30T12:00:00Z"
    }
  }
*/
  # Default node pool (aka, the minimum 1 System nodepool required by AKS)
  # CoreDNS and metrics-server will be scheduled to run on default node pool
  # Use resource "azurerm_kubernetes_cluster_node_pool" to managed nodepools
  default_node_pool {
    name                = "syspool" #[a-z0-9]
    node_count          = 3
    vm_size             = "Standard_D2_v2"
    os_disk_size_gb     = 30
    type                = "VirtualMachineScaleSets"
    availability_zones  = ["1", "2"]
    enable_auto_scaling = true
    min_count           = 2
    max_count           = 6

    # Required for advanced networking - CNI
    vnet_subnet_id = azurerm_subnet.default.id

    # node taints: prevent application pods from being scheduled on system node pool
    only_critical_addons_enabled = true

    # Upgrade settings
    upgrade_settings {
      max_surge = "30%"
    }

    # This needs to be the same as the k8s verion of control plane.
    # If orchestrator_version is missing, only the control plane k8s will be upgraded, not the nodepools
    orchestrator_version = "1.21.2"
  }

  network_profile {
    network_plugin     = "azure"
    load_balancer_sku  = "standard"
    network_policy     = "azure"
  }

/* Legacy, use managed identity instead.
  service_principal {
    client_id     = var.appId
    client_secret = var.password
  }
*/

  identity {
    type = "SystemAssigned"
  }

  # Kubernetes RBAC enabled with AKS-managed AAD integration
  role_based_access_control {
    enabled = true
    azure_active_directory {
      managed                = true
      azure_rbac_enabled     = true
      admin_group_object_ids = [var.admin_group_obj_id]
      # append comma separated group obj IDs
      #admin_group_object_ids = [azuread_group.aks_administrators.object_id]
    }
  }

  # Add On's
  addon_profile {
      oms_agent {
        enabled                    = true
        log_analytics_workspace_id = azurerm_log_analytics_workspace.default.id
      }
      azure_policy { enabled = true }

      # Greenfield AGIC - this will create a new App Gateway in MC_ resource group
      ingress_application_gateway {
        enabled   = true
        subnet_id = azurerm_subnet.appgw.id
      }

      #kube_dashboard {
      #  enabled = true
      #}
  }

  tags = {
    environment = "Production"
  }

  # Upgrade the control plane only, specify orchestrator_version for the default nodepool
  kubernetes_version= "1.21.2"

  # Set auto-upgrade channel: patch, stable, rapid, none(Default)
  automatic_channel_upgrade = "stable"
}

# User mode node pool - Linux
resource "azurerm_kubernetes_cluster_node_pool" "usrpl1" {
  name                  = "upool1"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.default.id
  vm_size               = "Standard_DS2_v2"
  node_count            = 3
  availability_zones    = ["1", "2"]
  enable_auto_scaling   = true  
  min_count             = 2
  max_count             = 6

  # Upgrade settings
  upgrade_settings {
    max_surge = "30%"
  }

  tags = {
    Environment = "Production"
  }
}

# User mode node pool - Windows
resource "azurerm_kubernetes_cluster_node_pool" "usrpl2" {
  name                  = "upool2"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.default.id
  vm_size               = "Standard_DS2_v2"
  node_count            = 3
  availability_zones    = ["1", "2"]
  enable_auto_scaling   = true  
  min_count             = 2
  max_count             = 6
  os_type               = "Windows"

  # Upgrade settings
  upgrade_settings {
    max_surge = "30%"
  }

  tags = {
    Environment = "Production"
  }
}
