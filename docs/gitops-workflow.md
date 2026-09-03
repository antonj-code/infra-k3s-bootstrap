# GitOps Deployment, Promotion & Disaster Recovery Guide

This guide details the end-to-end GitOps workflow for **`infra-k3s-bootstrap`**, including multi-environment downstream child pipelines, promotion strategies from **STAGE** to **PROD**, automated disaster recovery, and zero-downtime rolling upgrades.

---

## 1. Multi-Environment Architecture Overview

The infrastructure enforces strict isolation between environments:

| Feature | STAGE Environment | PROD Environment |
| :--- | :--- | :--- |
| **Proxmox VE Hypervisor** | `guardian.jnet.lan` | `colossus.jnet.lan` |
| **Control Plane Nodes** | 3x (`k3s-cp-s-*`, VMs `2001-2003`) | 3x (`k3s-cp-p-*`, VMs `3001-3003`) |
| **Worker Nodes** | 3x (`k3s-wk-s-*`, VMs `2011-2013`) | 5x (`k3s-wk-p-*`, VMs `3011-3015`) |
| **Total Cluster Size** | **6 Nodes** | **8 Nodes** |
| **Control Plane VIP** | `192.168.0.43` (`k3s-stage.jnet.lan`) | `192.168.0.44` (`k3s-prod.jnet.lan`) |
| **Internal Cluster Network**| VLAN `20` (`10.20.20.0/24`) | VLAN `30` (`10.30.30.0/24`) |
| **Terraform State Backend** | GitLab HTTP (`k3s-stage`) | GitLab HTTP (`k3s-prod`) |
| **Vault Secrets Path** | `secret/data/k3s-stage/*` | `secret/data/k3s-prod/*` |
| **Default Template Version**| `1.1.0` (AlmaLinux 9 CIS2, VM `1001`) | `1.1.0` (AlmaLinux 9 CIS2, VM `1001`) |

---

## 2. Child Pipeline Architecture

The root orchestrator ([`.gitlab-ci.yml`](../.gitlab-ci.yml)) delegates environment deployments to isolated downstream child pipelines:

```
[ Root Coordinator (.gitlab-ci.yml) ]
  ├── validate stage
  │     ├── terraform:validate:stage
  │     ├── terraform:validate:prod
  │     └── ansible:validate
  │
  ├── deploy:stage ──► Trigger: .gitlab/ci/stage.gitlab-ci.yml (guardian)
  │     └── [ seed ] ──► [ plan ] ──► [ apply ] ──► [ configure ] ──► [ verify 6/6 ]
  │
  └── deploy:prod ───► Trigger: .gitlab/ci/prod.gitlab-ci.yml (colossus)
        └── [ seed ] ──► [ plan ] ──► [ apply ] ──► [ configure ] ──► [ verify 8/8 ]
```

---

## 3. How Promotion to PROD Works

Once changes are tested and verified in STAGE, you have **three flexible ways** to promote to PROD:

### Method A: Promotion via Git Release Tag (Recommended for GitOps)

Pushing a version tag (`v*` or `prod-*`) automatically skips STAGE and triggers the **PROD child pipeline**:

```bash
# Using Makefile helper:
make promote TAG=v1.1.0

# Or using Git directly:
git tag -a v1.1.0 -m "Release v1.1.0 promoted to PROD"
git push origin v1.1.0
```

1. GitLab detects the tag push.
2. Global validation runs.
3. The **PROD child pipeline** immediately executes against **`colossus`** (plans, provisions VMs 3001-3015, configures K3s, and verifies 8/8 nodes).

---

### Method B: One-Click Promotion Button in GitLab UI

When you push or merge code to `main`:

1. The **STAGE child pipeline** runs automatically and validates the 6 STAGE nodes on `guardian`.
2. Once STAGE reaches `Passed`, a manual **`prod:pipeline`** trigger button appears in the pipeline graph on `main`.
3. Click the **Play (▶)** button on `prod:pipeline` to deploy to PROD.

```
[ validate ] ──────► [ deploy:stage (Auto) ] ──────► [ deploy:prod (Play ▶ Button) ]
                           │                                     │
                 (STAGE Child Pipeline)                (PROD Child Pipeline)
```

---

### Method C: Parameterized Run via GitLab Web UI

1. In GitLab, navigate to **CI/CD $\rightarrow$ Pipelines $\rightarrow$ Run Pipeline**.
2. Set the variables:
   - **`TARGET_ENV`**: Select **`PROD`**
   - **`PIPELINE_ACTION`**: Select **`deploy`**
3. Click **Run Pipeline** to deploy directly to PROD.

---

## 4. Single-Node Disaster Recovery via Pipeline

If a VM becomes corrupted, fails a hardware health check, or experiences kernel issues, you can rebuild and rejoin that specific VM with **zero cluster downtime** directly from GitLab CI.

### Step-by-Step UI Recovery:

1. Navigate to **CI/CD $\rightarrow$ Pipelines $\rightarrow$ Run Pipeline**.
2. Select parameters:
   - **`TARGET_ENV`**: `PROD` (or `STAGE`)
   - **`PIPELINE_ACTION`**: `recover-node`
   - **`NODE_NAME`**: Enter target hostname (e.g., `k3s-wk-p-g7h8` or `k3s-cp-p-a1b2`)
3. Click **Run Pipeline**.

### Execution Lifecycle:
```
[ Step 1: Workload Eviction ] ──► [ Step 2: Targeted Re-Clone ] ──► [ Step 3: Hardening & Join ] ──► [ Step 4: Verification ]
  • Drains active pods / etcd       • Terraform -replace on VM        • Formats XFS secondary disk     • Asserts cluster health
  • Kubernetes shifts pods          • Clones fresh template v1.1.0    • Applies CIS sysctl settings    • Confirms Ready state
```

- **Targeted Scope**: Terraform uses `-replace="module.k3s_nodes.proxmox_virtual_environment_vm.k3s_workers[INDEX]"` so the other 7 nodes in PROD are left running uninterrupted.

---

## 5. Independent Template Upgrades (Blue/Green)

You can maintain different VM template versions between STAGE and PROD:

1. **Test in STAGE**:
   - Update `template_version = "1.2.0"` in [`environments/stage/terraform/terraform.tfvars`](../environments/stage/terraform/terraform.tfvars).
   - Run rolling repave: `make repave ENV=stage` (or `bash scripts/rolling_upgrade.sh --mode repave --env stage`).
   - PROD remains untouched on `1.1.0`.
2. **Promote to PROD**:
   - Update `template_version = "1.2.0"` in [`environments/prod/terraform/terraform.tfvars`](../environments/prod/terraform/terraform.tfvars).
   - Promote via tag: `make promote TAG=v1.2.0`.

---

## 6. Makefile Command Reference

| Command | Description |
| :--- | :--- |
| `make seed ENV=stage` | Idempotently seed HashiCorp Vault secrets for STAGE |
| `make seed ENV=prod` | Idempotently seed HashiCorp Vault secrets for PROD |
| `make kubeconfig ENV=stage` | Fetch and export cluster kubeconfig from Vault |
| `make plan ENV=stage` | Run local Terraform plan for STAGE |
| `make apply ENV=stage` | Apply Terraform provisioning for STAGE |
| `make configure ENV=stage` | Run Ansible OS hardening & K3s deployment |
| `make verify ENV=stage` | Verify cluster node readiness via kubectl |
| `make promote TAG=v1.1.0` | Promote validated code to PROD via Git release tag |
| `make rolling-upgrade ENV=stage` | Execute sequential in-place K3s/OS rolling upgrade |
| `make repave ENV=stage` | Execute sequential zero-downtime VM repave from template |
