output "control_plane_vms" {
  description = "Provisioned K3s Control Plane / Compute VMs"
  value = {
    for vm in proxmox_virtual_environment_vm.k3s_control_plane : vm.name => {
      id             = vm.id
      vm_id          = vm.vm_id
      name           = vm.name
      node_name      = vm.node_name
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}

output "worker_vms" {
  description = "Provisioned K3s Worker VMs"
  value = {
    for vm in proxmox_virtual_environment_vm.k3s_workers : vm.name => {
      id             = vm.id
      vm_id          = vm.vm_id
      name           = vm.name
      node_name      = vm.node_name
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}

locals {
  management_ips = {
    for vm in concat(
      proxmox_virtual_environment_vm.k3s_control_plane,
      proxmox_virtual_environment_vm.k3s_workers
    ) : vm.name => [
      for ip in flatten(vm.ipv4_addresses) : ip
      if startswith(ip, "${var.management_network_prefix}.")
    ]
  }
  default_inventory_path = "${path.module}/../../../environments/${var.environment}/ansible/hosts.yaml"
  resolved_inventory_path = var.inventory_output_path != "" ? var.inventory_output_path : local.default_inventory_path
}

# Generate Ansible dynamic inventory file
resource "local_file" "ansible_inventory" {
  filename = local.resolved_inventory_path
  content  = <<-EOT
all:
  vars:
    ansible_user: ${var.ci_user}
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
  children:
    k3s_cluster:
      children:
        k3s_control_plane:
          hosts:
%{for vm in proxmox_virtual_environment_vm.k3s_control_plane~}
            ${vm.name}:
              ansible_host: ${try(element(local.management_ips[vm.name], 0), vm.name)}
              k3s_internal_ip: ${var.internal_network_prefix}.${var.control_plane_internal_ip_start + (vm.vm_id - var.control_plane_vmid_start)}
              k3s_node_id: ${vm.vm_id}
              pve_host: ${vm.node_name}
              node_role: control-plane
              k3s_node_type: management
              monitoring_group: control-plane
              template_version: "${var.template_version}"
              template_vmid: ${local.active_template_vm_id}
%{endfor~}
        k3s_workers:
          hosts:
%{for vm in proxmox_virtual_environment_vm.k3s_workers~}
            ${vm.name}:
              ansible_host: ${try(element(local.management_ips[vm.name], 0), vm.name)}
              k3s_internal_ip: ${var.internal_network_prefix}.${var.worker_internal_ip_start + (vm.vm_id - var.worker_vmid_start)}
              k3s_node_id: ${vm.vm_id}
              pve_host: ${vm.node_name}
              node_role: worker
              k3s_node_type: compute
              monitoring_group: worker
              has_longhorn_storage: true
              template_version: "${var.template_version}"
              template_vmid: ${local.active_template_vm_id}
%{endfor~}

    monitoring_nodes:
      children:
        k3s_control_plane:
        k3s_workers:
EOT
}

output "kube_vip_address" {
  description = "Virtual IP assigned to kube-vip for K3s Control Plane High Availability"
  value       = var.kube_vip_address
}

output "kube_vip_endpoint" {
  description = "Kubernetes API endpoint via kube-vip"
  value       = "https://${var.kube_vip_address}:6443"
}

output "kube_vip_hostname" {
  description = "Domain name for K3s API TLS SAN"
  value       = var.kube_vip_hostname
}
