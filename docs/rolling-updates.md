# Automated Sequential Rolling Upgrades & Template Repaving

This guide outlines how the **`infra-k3s-bootstrap`** framework performs automated, zero-downtime rolling upgrades across all 6 cluster nodes when the underlying VM template (AlmaLinux 9 CIS Level 2) is updated or when performing cluster maintenance in **STAGE** or **PROD**.

---

## 1. Upgrade Strategy & Order of Operations

To preserve Kubernetes workload availability and maintain embedded **etcd quorum**, upgrades are strictly executed in a 3-phase sequential order:

```
[Phase 1: Workers] ==> [Phase 2: Secondary Control Planes] ==> [Phase 3: Primary Control Plane]
 k3s-wk-s-AAAA (serial:1)   k3s-cp-s-YYYY (serial:1)                k3s-cp-s-XXXX (serial:1)
 k3s-wk-s-BBBB (serial:1)   k3s-cp-s-ZZZZ (serial:1)
 k3s-wk-s-CCCC (serial:1)
```

### Safety Guarantees at Each Step:
1. **Pre-flight Health Checks**: Verifies that the cluster is healthy, all other nodes are `Ready`, and etcd quorum is functional.
2. **Cordon & Workload Eviction**: Node is cordoned (`kubectl cordon`) and drained (`kubectl drain --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=180s`) so active pods migrate without downtime.
3. **VM Replacement / In-Place Upgrade**: Rebuilds the VM from the new template or applies OS/K3s updates.
4. **Automated Re-Hardening & Cluster Rejoin**: Ansible re-applies sysctl, kernel modules, firewall zones, mounts `/mnt/storage-data01` with XFS for Longhorn (or `/var/lib/rancher/k3s/server/db` for etcd), and connects the node back to the cluster.
5. **Health & Quorum Verification**: The pipeline waits until the node reaches `Ready` state and verifies etcd quorum health before proceeding to the next node in line.

---

## 2. Triggering a Rolling Upgrade

### Option A: Complete VM Repave from New Template (Recommended)
```bash
# Repave Stage cluster using Makefile:
make repave ENV=stage

# Or using the script directly:
bash scripts/rolling_upgrade.sh --mode repave --env stage --template-id 1001

# For Prod:
make repave ENV=prod
```

### Option B: In-Place Rolling OS & K3s Updates
```bash
# In-place rolling upgrade using Makefile:
make rolling-upgrade ENV=stage

# Or using the script directly:
bash scripts/rolling_upgrade.sh --mode in-place --env stage
```

### Option C: Direct Ansible Execution
```bash
cd ansible
ansible-playbook -i ../environments/stage/ansible/hosts.yaml playbooks/rolling_update.yaml
```

---

## 3. Monitoring & Validating Progress

You can observe the rolling upgrade in real-time from another terminal:

```bash
# Watch node status and labels
source scripts/k3s_env.sh stage
kubectl get nodes -o wide --watch

# Verify etcd quorum health on control plane
sudo /usr/local/bin/k3s etcdctl endpoint health
```

