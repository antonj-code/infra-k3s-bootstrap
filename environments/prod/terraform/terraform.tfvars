# Prod environment configuration (Targets colossus.jnet.lan)
pve_node_name               = "colossus"
pve_host_1_node_name        = "colossus"
pve_host_2_node_name        = "colossus"
control_plane_count         = 3
worker_count                = 5
control_plane_vmid_start    = 4001
worker_vmid_start           = 4011
template_version            = "1.1.0"

kube_vip_address            = "192.168.0.44"
kube_vip_hostname           = "k3s-prod.jnet.lan"

internal_vlan_id            = 30
internal_network_prefix     = "10.30.30"
control_plane_internal_ip_start = 11
worker_internal_ip_start    = 21

control_plane_config = {
  cores          = 2
  memory         = 4096
  disk_size      = 32
  etcd_disk_size = 20
}

worker_config = {
  cores          = 4
  memory         = 4096
  disk_size      = 32
  data_disk_size = 50
}
