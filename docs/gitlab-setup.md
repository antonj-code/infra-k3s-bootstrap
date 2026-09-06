# GitLab CI/CD Backend & Variable Setup Guide

This guide provides step-by-step instructions for configuring the GitLab repository backend, CI/CD variables, SSH deployment keys, and Proxmox API integration for **`gitbox.jnet.lan/jnet-labs/infra-k3s-bootstrap`**.

---

## 1. Proxmox VE API Token Creation (on `guardian` and `colossus`)

SSH into your Proxmox VE host **`guardian`** (and optionally **`colossus`**):

```bash
# 1. Create a dedicated role with required VM and storage privileges
pveum role add TerraformAdmin -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Config.Cloudinit VM.Audit VM.PowerMgmt VM.Console Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit SDN.Use Sys.Audit" 2>/dev/null || true

# 2. Create the automation service user
pveum user add terraform-ci@pve -comment "GitLab CI Terraform Automation" 2>/dev/null || true

# 3. Grant permissions to the role across the datacenter
pveum acl modify / -user terraform-ci@pve -role TerraformAdmin

# 4. Generate the non-expiring API token for the GitLab runner
pveum user token add terraform-ci@pve gitlab-runner -privsep 0
```

> [!IMPORTANT]
> **Copy the Token Value**: Proxmox will output `value: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.  
> Your full API token string will be: `terraform-ci@pve!gitlab-runner=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.

---

## 2. Dedicated SSH Deployment Key Pairs

Generate dedicated SSH key pairs for the GitLab runner to provision the VMs:

```bash
# Stage Deployment Key
ssh-keygen -t ed25519 -f ~/.ssh/k3s_stage_deploy_key -N "" -C "gitlab-runner-k3s-stage@gitbox.jnet.lan"

# Prod Deployment Key
ssh-keygen -t ed25519 -f ~/.ssh/k3s_prod_deploy_key -N "" -C "gitlab-runner-k3s-prod@gitbox.jnet.lan"
```

The public keys are injected into Cloud-Init VMs via Terraform, while the private keys are stored in HashiCorp Vault (`secret/data/k3s-stage/credentials` and `secret/data/k3s-prod/credentials`).

---

## 3. GitLab CI/CD Variables Setup

In your GitLab web interface:
1. Navigate to your repository: `https://gitbox.jnet.lan/jnet-labs/infra-k3s-bootstrap`
2. In the left sidebar, click **Settings** $\rightarrow$ **CI/CD**
3. Scroll down and expand the **Variables** section
4. Click **Add variable** for each of the following variables:

### 3.1 Required Root-of-Trust Variables (Add to GitLab CI/CD)

| Variable Key | Type | Environments | Protected | Masked | Value Example / Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`VAULT_ADDR`** | Variable | All | No | No | `https://192.168.0.40:8200` |
| **`VAULT_SKIP_VERIFY`** | Variable | All | No | No | `true` |
| **`VAULT_TOKEN`** | Variable | All | Yes | **Yes** | Your Vault administrative or scoped bootstrap token (`hvs.CAES...`) |
| **`TF_VAR_pve_host_1_endpoint`** | Variable | All | No | No | `https://colossus.jnet.lan:8006/` |
| **`TF_VAR_pve_host_1_api_token`**| Variable | All | Yes | **Yes** | `terraform-ci@pve!gitlab-runner=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| **`TF_VAR_pve_host_1_node_name`**| Variable | All | No | No | `colossus` |
| **`TF_VAR_pve_host_2_endpoint`** | Variable | All | No | No | `https://guardian.jnet.lan:8006/` |
| **`TF_VAR_pve_host_2_api_token`**| Variable | All | Yes | **Yes** | `terraform-ci@pve!gitlab-runner=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy` |
| **`TF_VAR_pve_host_2_node_name`**| Variable | All | No | No | `guardian` |

---

### 3.2 How Secrets Flow at Pipeline Runtime

```
[ GitLab CI Runner ]
        │
        ├── 1. Reads $VAULT_TOKEN and $VAULT_ADDR from GitLab CI Variables
        │
        ├── 2. Queries HashiCorp Vault (https://192.168.0.40:8200)
        │      ├── secret/data/k3s-stage/credentials  (SSH keys, guardian token)
        │      └── secret/data/k3s-prod/credentials   (SSH keys, colossus token)
        │
        ├── 3. Injects deploy public key into Cloud-Init VMs via Terraform
        │
        ├── 4. Authenticates via SSH private key loaded into ssh-agent memory
        │
        └── 5. Saves cluster admin kubeconfig back to Vault upon deployment
```

> [!TIP]
> **Zero Static Secrets in Git**: Notice that no passwords, tokens, or private SSH keys are stored in Git. Everything is either pulled dynamically from Vault or passed securely in runner memory.

---

## 4. GitLab Managed Terraform State Backends

You do **not** need to create or configure external S3 buckets or database backends. The repository automatically leverages GitLab's native HTTP Managed Terraform State:

- **STAGE State Location**: Under GitLab **Operate** $\rightarrow$ **Terraform states** $\rightarrow$ `k3s-stage`
- **PROD State Location**: Under GitLab **Operate** $\rightarrow$ **Terraform states** $\rightarrow$ `k3s-prod`
- **Lock Management**: Handled automatically via `${CI_JOB_TOKEN}`. When a job runs, GitLab acquires an exclusive lock preventing race conditions, and automatically unlocks upon job completion.

---

## 5. GitLab Runner Network Requirements

The Docker executor runner hosting the jobs needs Layer 3 network access to:
- **Proxmox VE Hosts**:
  - `guardian.jnet.lan:8006` (`https://guardian.jnet.lan:8006/`)
  - `colossus.jnet.lan:8006` (`https://colossus.jnet.lan:8006/`)
- **HashiCorp Vault**:
  - `192.168.0.40:8200` (`https://192.168.0.40:8200`)
- **VM Management Network**:
  - Subnet `192.168.0.0/24` (SSH TCP `22`, K3s API TCP `6443`)
- **DNS Resolution**:
  - Must be able to resolve `*.jnet.lan` or use configured DNS servers (`192.168.0.168`, `192.168.0.127`).

---

## 6. Multi-Environment Child Pipeline Architecture

The pipeline is split into modular downstream child pipelines for complete blast-radius isolation:

```
.
├── .gitlab-ci.yml                      # Parent coordinator
└── .gitlab/
    └── ci/
        ├── validate.gitlab-ci.yml      # Linting & syntax validation
        ├── stage.gitlab-ci.yml         # Independent STAGE deployment
        └── prod.gitlab-ci.yml          # Independent PROD deployment
```

### Execution Flow:

1. **Validation Stage (`validate`)**:
   - Runs `terraform:validate:stage`, `terraform:validate:prod`, and `ansible:validate` on all Merge Requests and branch pushes.
2. **Stage Child Pipeline (`stage:pipeline`)**:
   - Triggered automatically when files under `environments/stage/**`, `terraform/modules/**`, or `ansible/**` change.
   - Runs `seed` -> `plan` -> `apply` -> `configure` -> `verify` exclusively for STAGE on `guardian` (VMs `3001-3013`).
3. **Prod Child Pipeline (`prod:pipeline`)**:
   - **Promotion via Release Tag**: Pushing a version tag (e.g. `make promote TAG=v1.1.0` or `git tag v1.1.0 && git push origin v1.1.0`) automatically triggers the PROD child pipeline without manual clicking.
   - **Promotion via GitLab UI**: A one-click manual promotion button (`when: manual`) is always available in the pipeline graph on `main`.
   - **Promotion via Web Run**: Trigger directly by setting `TARGET_ENV=PROD` on the *Run Pipeline* page.
   - Runs `seed` -> `plan` -> `apply` -> `configure` -> `verify` exclusively for PROD on `colossus` (VMs `4001-4015`).

