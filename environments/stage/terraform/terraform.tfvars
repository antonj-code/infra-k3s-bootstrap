# Stage environment configuration
# Control planes on guardian.jnet.lan, workers on colossus.jnet.lan
pve_node_name               = "guardian"
pve_host_2_node_name        = "guardian"
worker_pve_node_name        = "colossus"
control_plane_count         = 3
worker_count                = 3
control_plane_vmid_start    = 3001
worker_vmid_start           = 3011
template_version            = "1.1.0"

kube_vip_address            = "192.168.0.43"
kube_vip_hostname           = "k3s-stage.jnet.lan"

internal_vlan_id            = 20
internal_network_prefix     = "10.20.20"
control_plane_internal_ip_start = 11
worker_internal_ip_start    = 21

control_plane_config = {
  cores          = 2
  memory         = 4096
  disk_size      = 32
  etcd_disk_size = 20
}

worker_config = {
  cores             = 4
  memory            = 4096
  disk_size         = 32
  data_disk_size    = 80
  runtime_disk_size = 60
}
