# Single-Node Repaving & Disaster Recovery Runbook

This runbook outlines how to safely destroy, recreate, and rejoin any single corrupted node (Control Plane or Worker) with **zero cluster downtime**.

---

## 1. High Availability Resilience Guarantees

* **Control Plane Quorum ($N=3$)**: The loss of 1 control plane node leaves 2 active peers alive. etcd maintains quorum, and Kubernetes continues serving API requests without downtime.
* **Worker Node Redundancy ($N=3$)**: Kubernetes automatically reschedules pods from a dead worker node to the remaining 2 healthy workers.

---

## 2. One-Click Automated Node Redeployment

We provide [`scripts/redeploy_node.sh`](../scripts/redeploy_node.sh) to execute the complete replacement lifecycle in a single command:

```bash
# Redeploy a worker node in STAGE (default):
bash scripts/redeploy_node.sh k3s-wk-g7h8 stage

# Redeploy a control plane node in PROD:
bash scripts/redeploy_node.sh k3s-cp-a1b2 prod
```

---

## 3. What Happens Under the Hood (Step-by-Step)

```
[ Step 1: Drain & Delete ] ──> [ Step 2: Proxmox Repave ] ──> [ Step 3: OS Hardening ] ──> [ Step 4: Cluster Rejoin ]
  • Evict active workloads       • Terraform deletes VM         • Ansible sysctl/swap       • K3s join token
  • Purge stale etcd member      • Re-clones from template      • XFS /mnt/storage-data01   • Verify node 'Ready'
```

### Step 1: Cordon & Clean Stale Cluster State
* Cordon and drain the target node using `kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force --grace-period=60`.
* Delete the stale node entry from Kubernetes: `kubectl delete node <node-name>`.
* If a Control Plane node failed, the surviving control plane removes the dead member from etcd (`k3s etcdctl member remove <id>`).

### Step 2: Proxmox VM Recreation (Terraform)
* Identifies the node index and replaces the specific VM resource on Proxmox without touching the other 5 nodes:
  ```bash
  cd environments/stage/terraform
  terraform apply -replace="module.k3s_nodes.proxmox_virtual_environment_vm.k3s_workers[0]"
  ```
* Discovers the new live DHCP IP via `scripts/discover_node_ips.sh <env>`.

### Step 3: Base OS Hardening & Storage Mount (Ansible)
* Disables swap (`swapoff -a` + `/etc/fstab`).
* Applies kernel modules (`overlay`, `br_netfilter`, `ip_vs`) and sysctl parameters.
* Configures firewalld and installs `k3s-selinux`.
* Formats the secondary storage disk (`/dev/sdb`) with **XFS** and mounts to `/mnt/storage-data01` (Worker) or `/var/lib/rancher/k3s/server/db` (Control Plane).

### Step 4: Cluster Join & Health Verification
* Worker node joins via K3s agent service.
* Control plane node joins etcd consensus via `--server https://<control_plane_ip>:6443`.
* Cluster health is verified via `kubectl get nodes -o wide`.

---

## 4. Manual Redeployment via Ansible Only

If you manually rebuilt the VM in Proxmox and only need to re-configure and re-join it:

```bash
cd ansible
ansible-playbook -i ../environments/stage/ansible/hosts.yaml playbooks/redeploy_node.yaml -e "target_node=k3s-wk-g7h8"
```

