# K3s Cluster Operations & Runbook

This runbook covers day-2 administrative tasks, status verification, troubleshooting, and cluster teardown across **STAGE** and **PROD** environments.

---

## 1. Quick Cluster Verification

From your administrative workstation:

```bash
# Source the cluster environment (defaults to stage, or pass prod)
source scripts/k3s_env.sh stage

# Check node status, roles, and internal IPs
kubectl get nodes -o wide

# Check core system pods (kube-vip, Flannel, CoreDNS, local-path-provisioner)
kubectl get pods -n kube-system -o wide

# Check etcd member health (run directly on any control plane node)
sudo /usr/local/bin/k3s etcd-snapshot list
sudo /usr/local/bin/k3s etcdctl endpoint health
```

Alternatively, use Makefile targets:

```bash
# Fetch kubeconfig from Vault or primary node
make kubeconfig ENV=stage

# Verify nodes reporting Ready (all 6 nodes)
make verify ENV=stage
```

---

## 2. Accessing Nodes via SSH

All VMs are dynamically assigned DHCP IPv4 addresses on `net0` (`192.168.0.0/24`) and accessible with the Cloud-Init administrator `almalinux`:

```bash
# Run discovery script to resolve current live IPs for your environment:
bash scripts/discover_node_ips.sh stage

# View current IPs in inventory:
cat environments/stage/ansible/hosts.yaml | grep -E "(k3s-cp|k3s-wk|ansible_host)"

# SSH into any node using its discovered IP:
ssh -i ~/.ssh/k3s_stage_deploy_key almalinux@<discovered_ip>
```

---

## 3. Node Troubleshooting & Service Logs

```bash
# Check K3s service status
sudo systemctl status k3s        # On Control Plane nodes
sudo systemctl status k3s-agent  # On Worker nodes

# Stream live system logs
sudo journalctl -u k3s -f        # On Control Plane nodes
sudo journalctl -u k3s-agent -f  # On Worker nodes

# Check kube-vip static pod / logs
sudo crictl ps | grep kube-vip
sudo crictl logs <kube_vip_container_id>
```

---

## 4. Resetting & Tearing Down Cluster

### Reset K3s Software Only (Preserve VMs)
To completely wipe K3s from all nodes while keeping the VMs alive for re-provisioning:

```bash
cd ansible
ansible-playbook -i ../environments/stage/ansible/hosts.yaml playbooks/reset_cluster.yaml
```

### Destroy Virtual Machines via Terraform
To destroy the VMs in Proxmox entirely for a specific environment:

```bash
cd environments/stage/terraform
terraform destroy
```

Or for production:

```bash
cd environments/prod/terraform
terraform destroy
```

