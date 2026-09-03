variable "pve_host_1_endpoint" {
  type        = string
  default     = "https://colossus.jnet.lan:8006/"
}
variable "pve_host_1_api_token" {
  type        = string
  sensitive   = true
  default     = ""
}
variable "pve_host_1_node_name" {
  type        = string
  default     = "colossus"
}
variable "pve_host_2_endpoint" {
  type        = string
  default     = "https://guardian.jnet.lan:8006/"
}
variable "pve_host_2_api_token" {
  type        = string
  sensitive   = true
  default     = ""
}
variable "pve_host_2_node_name" {
  type        = string
  default     = "guardian"
}
variable "pve_endpoint" {
  type        = string
  default     = "https://colossus.jnet.lan:8006/"
}
variable "pve_api_token" {
  type        = string
  sensitive   = true
  default     = ""
}
variable "pve_node_name" {
  type        = string
  default     = "colossus"
}
variable "proxmox_insecure" {
  type        = bool
  default     = true
}
variable "storage_datastore" {
  type        = string
  default     = "local-lvm"
}
variable "resource_pool_id" {
  type        = string
  default     = ""
}
variable "network_bridge" {
  type        = string
  default     = "vmbr0"
}
variable "network_gateway" {
  type        = string
  default     = "192.168.0.1"
}
variable "management_network_prefix" {
  type        = string
  default     = "192.168.0"
}
variable "dns_servers" {
  type        = list(string)
  default     = ["192.168.0.168", "192.168.0.127"]
}
variable "search_domain" {
  type        = string
  default     = "jnet.lan"
}
variable "ssh_public_keys" {
  type        = any
  default     = []
}
variable "template_registry" {
  type        = map(number)
  default = {
    "1.0.0" = 1000
    "1.1.0" = 1001
    "1.2.0" = 1002
  }
}
variable "template_vm_id" {
  type        = number
  default     = 1000
}
variable "ci_user" {
  type        = string
  default     = "almalinux"
}
variable "control_plane_count" {
  type        = number
  default     = 3
}
variable "worker_count" {
  type        = number
  default     = 3
}
variable "control_plane_vmid_start" {
  type        = number
  default     = 3001
}
variable "worker_vmid_start" {
  type        = number
  default     = 3011
}
variable "template_version" {
  type        = string
  default     = "1.1.0"
}
variable "control_plane_config" {
  type = object({
    cores          = number
    memory         = number
    disk_size      = number
    etcd_disk_size = number
  })
  default = {
    cores          = 4
    memory         = 8192
    disk_size      = 50
    etcd_disk_size = 30
  }
}
variable "worker_config" {
  type = object({
    cores          = number
    memory         = number
    disk_size      = number
    data_disk_size = number
  })
  default = {
    cores          = 8
    memory         = 16384
    disk_size      = 50
    data_disk_size = 100
  }
}
variable "kube_vip_address" {
  type        = string
  default     = "192.168.0.42"
}
variable "kube_vip_hostname" {
  type        = string
  default     = "k3s-prod.jnet.lan"
}
variable "mac_prefix" {
  type        = string
  default     = "bc:24:12"
}
variable "internal_vlan_id" {
  type        = number
  default     = 30
}
variable "internal_network_prefix" {
  type        = string
  default     = "10.30.30"
}
variable "internal_network_prefix_length" {
  type        = number
  default     = 24
}
variable "control_plane_internal_ip_start" {
  type        = number
  default     = 11
}
variable "worker_internal_ip_start" {
  type        = number
  default     = 21
}
