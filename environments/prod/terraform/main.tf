# Proxmox Host 1 Provider (colossus.jnet.lan) - Default for PROD
provider "proxmox" {
  endpoint  = var.pve_host_1_endpoint != "" ? var.pve_host_1_endpoint : (var.pve_endpoint != "" ? var.pve_endpoint : "https://colossus.jnet.lan:8006/")
  api_token = var.pve_host_1_api_token != "" ? var.pve_host_1_api_token : (var.pve_api_token != "" ? var.pve_api_token : "dummy")
  insecure  = var.proxmox_insecure

  ssh {
    agent = true
  }
}

# Proxmox Host 2 Provider (guardian.jnet.lan) - Secondary / Alias
provider "proxmox" {
  alias     = "pve2"
  endpoint  = var.pve_host_2_endpoint != "" ? var.pve_host_2_endpoint : "https://guardian.jnet.lan:8006/"
  api_token = var.pve_host_2_api_token != "" ? var.pve_host_2_api_token : (var.pve_api_token != "" ? var.pve_api_token : "dummy")
  insecure  = var.proxmox_insecure

  ssh {
    agent = true
  }
}

module "k3s_nodes" {
  source = "../../terraform/modules/k3s_nodes"

  environment                   = "prod"
  inventory_output_path         = "${path.module}/../ansible/hosts.yaml"

  pve_host_1_endpoint           = var.pve_host_1_endpoint
  pve_host_1_api_token          = var.pve_host_1_api_token
  pve_host_1_node_name          = var.pve_host_1_node_name
  pve_host_2_endpoint           = var.pve_host_2_endpoint
  pve_host_2_api_token          = var.pve_host_2_api_token
  pve_host_2_node_name          = var.pve_host_2_node_name
  pve_endpoint                  = var.pve_endpoint
  pve_api_token                 = var.pve_api_token
  pve_node_name                 = var.pve_node_name
  proxmox_insecure              = var.proxmox_insecure

  storage_datastore             = var.storage_datastore
  resource_pool_id              = var.resource_pool_id
  network_bridge                = var.network_bridge
  network_gateway               = var.network_gateway
  management_network_prefix     = var.management_network_prefix
  dns_servers                   = var.dns_servers
  search_domain                 = var.search_domain
  ssh_public_keys               = var.ssh_public_keys
  template_registry             = var.template_registry
  template_vm_id                = var.template_vm_id
  ci_user                       = var.ci_user

  control_plane_count           = var.control_plane_count
  worker_count                  = var.worker_count
  control_plane_vmid_start      = var.control_plane_vmid_start
  worker_vmid_start             = var.worker_vmid_start
  template_version              = var.template_version

  control_plane_config          = var.control_plane_config
  worker_config                 = var.worker_config
  kube_vip_address              = var.kube_vip_address
  kube_vip_hostname             = var.kube_vip_hostname
  mac_prefix                    = var.mac_prefix

  internal_vlan_id              = var.internal_vlan_id
  internal_network_prefix       = var.internal_network_prefix
  internal_network_prefix_length= var.internal_network_prefix_length
  control_plane_internal_ip_start = var.control_plane_internal_ip_start
  worker_internal_ip_start      = var.worker_internal_ip_start
}
