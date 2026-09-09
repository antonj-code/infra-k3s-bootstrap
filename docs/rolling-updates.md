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
3. **VM Replacement / Re-Convergence**: In `repave` mode, rebuilds the VM from the template. In `in-place` mode, re-applies OS configuration and reinstalls K3s only if the pinned `k3s_version` has changed.
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

`--template-id` overrides which Proxmox template VM ID gets cloned for this repave, without editing `terraform.tfvars`. It bypasses `template_registry`/`template_version` entirely for the run - pass the raw Proxmox VM ID of the template you want (e.g. `--template-id 1000` or `--template-id 1002` to bounce between kept-around releases). It's only valid with `--mode repave`; `in-place` mode never touches the VM template, so combining the two errors out.

### Option B: In-Place Rolling K3s Upgrade & Config Re-Convergence

In-place mode does **not** install OS package updates. The `k3s_common` role
installs prerequisite packages with `state: present`, so it adds what is
missing and leaves installed packages at their current version; there is no
`dnf update` anywhere in the Ansible tree. K3s itself is only reinstalled when
the binary is absent or `k3s_version` (in `environments/<env>/ansible/group_vars/all.yaml`)
no longer matches what is installed.

So the two modes split by what you are actually changing:

| Goal | Mode | Change first |
| --- | --- | --- |
| New OS image / CIS baseline | `repave` | Build the template, pass `--template-id` |
| New K3s version | `in-place` | Bump `k3s_version` in `group_vars/all.yaml` |
| Re-converge config drift | `in-place` | Nothing |

Run against an unchanged `k3s_version`, in-place mode is a config
re-convergence and rolling service restart - it upgrades nothing.

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

