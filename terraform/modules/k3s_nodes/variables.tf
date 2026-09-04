# --- Proxmox Host 1 (colossus) Connection ---
variable "pve_host_1_endpoint" {
  description = "The Proxmox VE API endpoint for Host 1 (colossus.jnet.lan)"
  type        = string
  default     = "https://colossus.jnet.lan:8006/"
}

variable "pve_host_1_api_token" {
  description = "Proxmox API token for Host 1 (USER@REALM!TOKENID=SECRET)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pve_host_1_node_name" {
  description = "Proxmox internal node name for Host 1 (colossus)"
  type        = string
  default     = "colossus"
}

# --- Proxmox Host 2 (guardian) Connection ---
variable "pve_host_2_endpoint" {
  description = "The Proxmox VE API endpoint for Host 2 (guardian.jnet.lan)"
  type        = string
  default     = "https://guardian.jnet.lan:8006/"
}

variable "pve_host_2_api_token" {
  description = "Proxmox API token for Host 2 (USER@REALM!TOKENID=SECRET)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pve_host_2_node_name" {
  description = "Proxmox internal node name for Host 2 (guardian)"
  type        = string
  default     = "guardian"
}

# --- Fallback / Single-host Compatibility ---
variable "pve_endpoint" {
  description = "Fallback default Proxmox API endpoint"
  type        = string
  default     = "https://guardian.jnet.lan:8006/"
}

variable "pve_api_token" {
  description = "Fallback default Proxmox API token"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pve_node_name" {
  description = "Fallback default Proxmox node name"
  type        = string
  default     = "guardian"
}

variable "proxmox_insecure" {
  description = "Set to true to ignore self-signed SSL certificate warnings from Proxmox"
  type        = bool
  default     = true
}

# --- Environment & Inventory Config ---
variable "environment" {
  description = "Target deployment environment (stage or prod)"
  type        = string
  default     = "stage"
}

variable "inventory_output_path" {
  description = "Path where the generated Ansible inventory should be saved"
  type        = string
  default     = ""
}

# --- Storage & Network Configuration ---
variable "storage_datastore" {
  description = "Storage datastore for VM root and data disks (e.g. local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm"
}

variable "resource_pool_id" {
  description = "Proxmox resource pool to assign all K3s VMs to (e.g. k3s_pool or empty string for none)"
  type        = string
  default     = ""
}

variable "network_bridge" {
  description = "Proxmox virtual network bridge"
  type        = string
  default     = "vmbr0"
}

variable "network_gateway" {
  description = "Default IPv4 Gateway for K3s VMs"
  type        = string
  default     = "192.168.0.1"
}

variable "management_network_prefix" {
  description = "First three octets of the external/management network (net0) reachable from the CI runner; used to pick each node's ansible_host"
  type        = string
  default     = "192.168.0"
}

variable "dns_servers" {
  description = "List of DNS servers"
  type        = list(string)
  default     = ["192.168.0.168", "192.168.0.127"]
}

variable "search_domain" {
  description = "DNS search domain"
  type        = string
  default     = "jnet.lan"
}

variable "ssh_public_keys" {
  description = "SSH public keys (accepts JSON list of strings or single raw string) injected into VMs"
  type        = any
  default     = []
}

variable "template_registry" {
  description = "Registry mapping template version tags to Proxmox VM template IDs (Blue/Green template management)"
  type        = map(number)
  default = {
    "1.0.0" = 1000
    "1.1.0" = 1001 # almalinux-9-cis2-09022026
    "1.2.0" = 1002
  }
}

variable "template_vm_id" {
  description = "Fallback default Proxmox VM ID for the CIS Level 2 AlmaLinux 9 template"
  type        = number
  default     = 1001
}

variable "ci_user" {
  description = "Cloud-Init default administrator username"
  type        = string
  default     = "almalinux"
}

# --- Sizing ---
variable "control_plane_count" {
  description = "Number of K3s Control Plane / Compute nodes to deploy"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of K3s Worker nodes to deploy"
  type        = number
  default     = 3
}

variable "control_plane_vmid_start" {
  description = "Starting Proxmox VM ID for K3s Control Plane nodes"
  type        = number
  default     = 3001
}

variable "worker_vmid_start" {
  description = "Starting Proxmox VM ID for K3s Worker nodes"
  type        = number
  default     = 3011
}

variable "template_version" {
  description = "Active template version tag to deploy across the cluster (resolved via template_registry)"
  type        = string
  default     = "1.1.0"
}

variable "control_plane_config" {
  description = "Hardware resource allocation for K3s Control Plane / Compute VMs (including secondary 20GB disk for etcd)"
  type = object({
    cores          = number
    memory         = number
    disk_size      = number
    etcd_disk_size = number
  })
  default = {
    cores          = 2
    memory         = 4096
    disk_size      = 32
    etcd_disk_size = 20
  }
}

variable "worker_config" {
  description = "Hardware resource allocation for K3s Worker VMs (including secondary 50GB data disk for Longhorn)"
  type = object({
    cores          = number
    memory         = number
    disk_size      = number
    data_disk_size = number
  })
  default = {
    cores          = 4
    memory         = 4096
    disk_size      = 32
    data_disk_size = 50
  }
}

variable "kube_vip_address" {
  description = "Virtual IP for kube-vip Control Plane HA"
  type        = string
  default     = "192.168.0.43"
}

variable "kube_vip_hostname" {
  description = "DNS hostname for K3s API TLS SAN"
  type        = string
  default     = "k3s-stage.jnet.lan"
}

variable "mac_prefix" {
  description = "Base MAC address prefix for deterministic network interface MACs (Proxmox OUI: bc:24:11)"
  type        = string
  default     = "bc:24:11"
}

# --- Internal Cluster Network (net1 on vmbr0, VLAN-tagged) ---
variable "internal_vlan_id" {
  description = "VLAN tag applied to the internal cluster network device (net1) on the shared vmbr0 bridge"
  type        = number
  default     = 20
}

variable "internal_network_prefix" {
  description = "First three octets of the internal cluster (VLAN-tagged) network used for static net1 addressing"
  type        = string
  default     = "10.20.20"
}

variable "internal_network_prefix_length" {
  description = "CIDR prefix length for the internal cluster network"
  type        = number
  default     = 24
}

variable "control_plane_internal_ip_start" {
  description = "Last octet to start from (incremented by count.index) for Control Plane node static IPs on the internal cluster network (net1)"
  type        = number
  default     = 11
}

variable "worker_internal_ip_start" {
  description = "Last octet to start from (incremented by count.index) for Worker node static IPs on the internal cluster network (net1)"
  type        = number
  default     = 21
}
