# Automated Sequential Rolling Upgrades & Template Repaving

This guide outlines how the **`infra-k3s-bootstrap`** framework performs automated, zero-downtime rolling upgrades across all 6 cluster nodes when the underlying VM template (AlmaLinux 9 CIS Level 2) is updated or when performing cluster maintenance in **STAGE** or **PROD**.

---

## 1. Upgrade Strategy & Order of Operations

To preserve Kubernetes workload availability and maintain embedded **etcd quorum**, upgrades are executed one node at a time in three phases. **The phase order depends on the mode.**

`--mode repave` - least critical nodes first, so nothing touches etcd until the
workers are proven on the new template:

```
[Phase 1: Workers] ==> [Phase 2: Secondary Control Planes] ==> [Phase 3: Primary Control Plane]
 k3s-wk-s-AAAA (serial:1)   k3s-cp-s-YYYY (serial:1)                k3s-cp-s-XXXX (serial:1)
 k3s-wk-s-BBBB (serial:1)   k3s-cp-s-ZZZZ (serial:1)
 k3s-wk-s-CCCC (serial:1)
```

`--mode in-place` - **inverted**, servers before agents:

```
[Phase 1: Primary Control Plane] ==> [Phase 2: Secondary Control Planes] ==> [Phase 3: Workers]
 k3s-cp-s-XXXX (serial:1)             k3s-cp-s-YYYY (serial:1)                k3s-wk-s-AAAA (serial:1)
                                      k3s-cp-s-ZZZZ (serial:1)                k3s-wk-s-BBBB (serial:1)
                                                                              k3s-wk-s-CCCC (serial:1)
```

In-place is the mode that lands a new `k3s_version`, and Kubernetes' version
skew policy permits a kubelet to run *older* than the apiserver but never
newer. Upgrading workers first would put every kubelet ahead of all three
apiservers for the duration of the run. A repave installs the same pinned
`k3s_version` on every node, so no skew is possible and the safer
workers-first order applies there.

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

## 3. Pushing Config Changes Safely

A push to `main` that touches `.gitlab-ci.yml`, `.gitlab/`, `ansible/`,
`environments/`, `terraform/`, `scripts/` or `Makefile` creates a pipeline
(the `changes:` list in the root `workflow:` rules). `PIPELINE_ACTION` defaults
to `deploy`, so that pipeline runs `terraform apply` and then
`playbooks/site.yaml`.

**`site.yaml` is the initial-rollout playbook, not a rolling one.** It applies
`k3s_common` two nodes at a time, control planes before workers, and workers at
`serial: 2` - with no `cordon`, no `drain`, and no etcd quorum gate between
nodes. That is correct for building a cluster from nothing and wrong for
changing one that is running.

Most pushes are harmless because the change is a no-op against live
infrastructure - a doc edit, a CI tweak, a script the pipeline does not call.
The exception is any change the Ansible roles actually act on:

| Change | Safe to push normally? |
| --- | --- |
| `docs/` only | Yes - excluded from the `changes:` list, no pipeline at all |
| CI config, scripts not run by `site.yaml` | Yes - pipeline runs, applies nothing new |
| `terraform.tfvars`, node counts, VM sizing | No - `terraform apply` acts on it immediately |
| **`k3s_version` in `group_vars/all.yaml`** | **No - `site.yaml` upgrades K3s 2 workers at a time, undrained** |
| sysctl, firewall, kernel module defaults | No - re-applied fleet-wide at `serial: 2` |

For anything in the "No" rows, suppress the pipeline on push and trigger the
rolling path deliberately afterwards:

```bash
git commit -am "Bump stage k3s version to v1.36.4+k3s1"
git push -o ci.skip origin main
```

`-o ci.skip` stops GitLab creating a pipeline for that push without putting
`[skip ci]` in the commit message. Then start the upgrade from the GitLab UI -
**Build > Pipelines > New pipeline** - with:

| Variable | Value |
| --- | --- |
| `TARGET_ENV` | `STAGE` (or `PROD`) |
| `PIPELINE_ACTION` | `rolling-upgrade` |
| `UPGRADE_MODE` | `in-place` (K3s version bump) or `repave` (new template) |
| `TEMPLATE_ID` | Proxmox template VM ID, `repave` only - blank to use the registry |

That pipeline skips every deploy job and runs only the rolling upgrade, which
cordons, drains and gates on health between each node.

---

## 4. Monitoring & Validating Progress

You can observe the rolling upgrade in real-time from another terminal:

```bash
# Watch node status and labels
source scripts/k3s_env.sh stage
kubectl get nodes -o wide --watch

# Verify etcd health and membership (k3s has no etcdctl subcommand)
kubectl get --raw='/readyz/etcd'; echo
kubectl get nodes -l node-role.kubernetes.io/etcd=true
```

