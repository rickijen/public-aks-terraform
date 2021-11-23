/*
variable "appId" {
  description = "Azure Kubernetes Service Cluster service principal"
}

variable "password" {
  description = "Azure Kubernetes Service Cluster password"
}
*/

variable "admin_group_obj_id" {
  description = "AKS Admin group object ID"
}

# refer https://azure.microsoft.com/pricing/details/monitor/ for log analytics pricing 
variable log_analytics_workspace_sku {
    default = "PerGB2018"
}

variable "ssh_public_key" {
  description = "ssh public key"
}

variable "azure_policy_k8s_initiative" {
  description = "Kubernetes cluster pod security baseline standards for Linux-based workloads"
}

variable "windowspassword" {
  description = "Windows admin password"
}
