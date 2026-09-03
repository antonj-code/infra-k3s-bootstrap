locals {
  parsed_ssh_keys       = can(tolist(var.ssh_public_keys)) ? tolist(var.ssh_public_keys) : [tostring(var.ssh_public_keys)]
  active_template_vm_id = lookup(var.template_registry, var.template_version, var.template_vm_id)
  env_char              = substr(var.environment, 0, 1) # 's' for stage, 'p' for prod
}

# ==============================================================================
# Random Suffix Generators for VM & Hostname Generation
# Format: k3s-cp-<env>-<random> (Control Plane) and k3s-wk-<env>-<random> (Worker)
# e.g., k3s-cp-s-zzzz (stage) or k3s-cp-p-yyyy (prod)
# ==============================================================================

resource "random_string" "cp_suffix" {
  count   = var.control_plane_count
  length  = 4
  special = false
  upper   = false
  numeric = true
}

resource "random_string" "worker_suffix" {
  count   = var.worker_count
  length  = 4
  special = false
  upper   = false
  numeric = true
}

# ==============================================================================
# PROXMOX HOST: K3s Control Plane / Management Nodes
# Cloned from AlmaLinux 9 CIS Level 2 Template
# Uses DHCP for dynamic IPv4 assignment
# ==============================================================================

resource "proxmox_virtual_environment_vm" "k3s_control_plane" {
  count     = var.control_plane_count
  name      = "k3s-cp-${local.env_char}-${random_string.cp_suffix[count.index].result}"
  node_name = var.pve_host_2_node_name
  vm_id     = var.control_plane_vmid_start + count.index
  pool_id   = var.resource_pool_id != "" ? var.resource_pool_id : null
  tags      = ["k3s", var.environment, "control-plane", "management", var.pve_host_2_node_name, "almalinux9", "cis2"]

  description = "K3s Control Plane Management Node ${count.index + 1} (${var.environment} - k3s-cp-${local.env_char}-${random_string.cp_suffix[count.index].result} - ${var.pve_host_2_node_name} - template v${var.template_version})"

  clone {
    vm_id = local.active_template_vm_id
  }

  cpu {
    cores = var.control_plane_config.cores
    type  = "host"
  }

  memory {
    dedicated = var.control_plane_config.memory
    floating  = var.control_plane_config.memory
  }

  started = true

  timeout_create   = 600
  timeout_clone    = 600
  timeout_start_vm = 600
  timeout_stop_vm  = 300

  agent {
    enabled = true
    timeout = "180s"
  }

  # Primary OS Root Disk
  disk {
    datastore_id = var.storage_datastore
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    backup       = false
    size         = var.control_plane_config.disk_size
    file_format  = "raw"
  }

  # Secondary Dedicated Storage Disk (20GB) for etcd Datastore
  disk {
    datastore_id = var.storage_datastore
    interface    = "scsi1"
    iothread     = true
    discard      = "on"
    backup       = false
    size         = var.control_plane_config.etcd_disk_size
    file_format  = "raw"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    ip_config {
      ipv4 {
        address = "${var.internal_network_prefix}.${var.control_plane_internal_ip_start + count.index}/${var.internal_network_prefix_length}"
      }
    }

    dns {
      domain  = var.search_domain
      servers = var.dns_servers
    }

    user_account {
      username = var.ci_user
      keys     = local.parsed_ssh_keys
    }
  }

  # net0: External / management network (SSH, kube-vip VIP, API access)
  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = format("%s:00:%02x:%02x", lower(var.mac_prefix), floor((var.control_plane_vmid_start + count.index) / 256), (var.control_plane_vmid_start + count.index) % 256)
  }

  # net1: Internal cluster network (etcd, kubelet, flannel), VLAN-tagged
  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    vlan_id     = var.internal_vlan_id
    mac_address = format("%s:01:%02x:%02x", lower(var.mac_prefix), floor((var.control_plane_vmid_start + count.index) / 256), (var.control_plane_vmid_start + count.index) % 256)
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    ignore_changes = [
      name,
      started,
      pool_id,
      clone,
      initialization,
      network_device,
      disk,
      tags,
      description,
      operating_system,
      cpu,
      memory,
      agent,
      serial_device,
      vga,
    ]
  }
}

# ==============================================================================
# PROXMOX HOST: K3s Worker Nodes
# Cloned from AlmaLinux 9 CIS Level 2 Template
# Uses DHCP for dynamic IPv4 assignment
# ==============================================================================

resource "proxmox_virtual_environment_vm" "k3s_workers" {
  count     = var.worker_count
  name      = "k3s-wk-${local.env_char}-${random_string.worker_suffix[count.index].result}"
  node_name = var.pve_host_2_node_name
  vm_id     = var.worker_vmid_start + count.index
  pool_id   = var.resource_pool_id != "" ? var.resource_pool_id : null
  tags      = ["k3s", var.environment, "worker", "compute", "storage", "longhorn", var.pve_host_2_node_name, "almalinux9", "cis2"]

  description = "K3s Worker / Compute Node ${count.index + 1} (${var.environment} - k3s-wk-${local.env_char}-${random_string.worker_suffix[count.index].result} - ${var.pve_host_2_node_name} - template v${var.template_version})"

  clone {
    vm_id = local.active_template_vm_id
  }

  cpu {
    cores = var.worker_config.cores
    type  = "host"
  }

  memory {
    dedicated = var.worker_config.memory
    floating  = var.worker_config.memory
  }

  started = true

  timeout_create   = 600
  timeout_clone    = 600
  timeout_start_vm = 600
  timeout_stop_vm  = 300

  agent {
    enabled = true
    timeout = "180s"
  }

  # Primary OS Root Disk
  disk {
    datastore_id = var.storage_datastore
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    backup       = false
    size         = var.worker_config.disk_size
    file_format  = "raw"
  }

  # Secondary Dedicated Storage Disk (50GB) for Longhorn CSI
  disk {
    datastore_id = var.storage_datastore
    interface    = "scsi1"
    iothread     = true
    discard      = "on"
    backup       = false
    size         = var.worker_config.data_disk_size
    file_format  = "raw"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    ip_config {
      ipv4 {
        address = "${var.internal_network_prefix}.${var.worker_internal_ip_start + count.index}/${var.internal_network_prefix_length}"
      }
    }

    dns {
      domain  = var.search_domain
      servers = var.dns_servers
    }

    user_account {
      username = var.ci_user
      keys     = local.parsed_ssh_keys
    }
  }

  # net0: External / management network (SSH, kube-vip VIP, API access)
  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = format("%s:00:%02x:%02x", lower(var.mac_prefix), floor((var.worker_vmid_start + count.index) / 256), (var.worker_vmid_start + count.index) % 256)
  }

  # net1: Internal cluster network (etcd, kubelet, flannel), VLAN-tagged
  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    vlan_id     = var.internal_vlan_id
    mac_address = format("%s:01:%02x:%02x", lower(var.mac_prefix), floor((var.worker_vmid_start + count.index) / 256), (var.worker_vmid_start + count.index) % 256)
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    ignore_changes = [
      name,
      started,
      pool_id,
      clone,
      initialization,
      network_device,
      disk,
      tags,
      description,
      operating_system,
      cpu,
      memory,
      agent,
      serial_device,
      vga,
    ]
  }
}
