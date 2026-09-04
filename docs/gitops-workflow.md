# GitOps Deployment, Promotion & Disaster Recovery Guide

This guide details the end-to-end GitOps workflow for **`infra-k3s-bootstrap`**, including multi-environment downstream child pipelines, promotion strategies from **STAGE** to **PROD**, automated disaster recovery, and zero-downtime rolling upgrades.

---

## 1. Multi-Environment Architecture Overview

The infrastructure enforces strict isolation between environments:

| Feature | STAGE Environment | PROD Environment |
| :--- | :--- | :--- |
| **Proxmox VE Hypervisor** | `guardian.jnet.lan` | `colossus.jnet.lan` |
| **Control Plane Nodes** | 3x (`k3s-cp-s-*`, VMs `3001-3003`) | 3x (`k3s-cp-p-*`, VMs `4001-4003`) |
| **Worker Nodes** | 3x (`k3s-wk-s-*`, VMs `3011-3013`) | 5x (`k3s-wk-p-*`, VMs `4011-4015`) |
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

## 3. Triggering a Pipeline for PROD Environment Only

If you want to execute a deployment pipeline that runs **exclusively against PROD (`colossus.jnet.lan`)** while completely skipping STAGE, you can use any of the following methods:

---

### Option 1: Trigger via GitLab Web UI (Zero CLI needed)

1. In GitLab, navigate to: **CI/CD $\rightarrow$ Pipelines $\rightarrow$ Run Pipeline**.
2. Under **Variables**, configure:
   - **`TARGET_ENV`**: Select **`PROD`** from the dropdown.
   - **`PIPELINE_ACTION`**: Select **`deploy`** (Default).
3. Click the blue **Run Pipeline** button.

> [!NOTE]
> When `TARGET_ENV=PROD` is set, the root pipeline rules set `stage:pipeline` to `never` and immediately trigger `prod:pipeline`. STAGE on `guardian` is **not touched**.

---

### Option 2: Trigger via Git Release Tag (`make promote`)

In GitOps, production releases are typically triggered via version tags:

```bash
# Using Makefile shortcut:
make promote TAG=v1.1.0

# Or using Git directly:
git tag -a v1.1.0 -m "Release v1.1.0 promoted to PROD"
git push origin v1.1.0
```

- **Pipeline Behavior**:
  - GitLab detects the version tag (`v*` or `prod-*`).
  - STAGE is **completely bypassed** (`when: never`).
  - The **PROD child pipeline** immediately executes against **`colossus`** (provisions VMs `4001-4015`, hardens AlmaLinux 9, configures K3s with VIP `192.168.0.44`, and asserts 8/8 nodes Ready).

---

### Option 3: One-Click Manual Promotion on `main`

When changes are pushed to `main`, STAGE runs first. Once STAGE finishes:
1. Open the pipeline view in GitLab.
2. In the **`deploy:prod`** stage, click the manual **Play (▶)** button on **`prod:pipeline`**.
3. This spawns the isolated PROD child pipeline.

```
[ validate ] ──────► [ deploy:stage (Runs Auto) ] ──────► [ deploy:prod (Manual Play ▶) ]
                             │                                       │
                   (STAGE on guardian)                     (PROD on colossus)
```

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
