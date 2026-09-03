output "control_plane_vms" {
  description = "Provisioned K3s Control Plane / Compute VMs"
  value       = module.k3s_nodes.control_plane_vms
}

output "worker_vms" {
  description = "Provisioned K3s Worker VMs"
  value       = module.k3s_nodes.worker_vms
}

output "kube_vip_address" {
  description = "Virtual IP assigned to kube-vip for K3s Control Plane High Availability"
  value       = module.k3s_nodes.kube_vip_address
}

output "kube_vip_endpoint" {
  description = "Kubernetes API endpoint via kube-vip"
  value       = module.k3s_nodes.kube_vip_endpoint
}

output "kube_vip_hostname" {
  description = "Domain name for K3s API TLS SAN"
  value       = module.k3s_nodes.kube_vip_hostname
}
