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
1. Navigate to: `https://gitbox.jnet.lan/jnet-labs/infra-k3s-bootstrap`
2. In the left sidebar, go to **Settings** $\rightarrow$ **CI/CD**
3. Expand the **Variables** section $\rightarrow$ Click **Add variable**

### 3.1 Recommended GitOps Model (Minimal Variables in GitLab)

In a pure GitOps pipeline, **GitLab only needs the bootstrap root of trust credentials**. The pipeline automatically retrieves SSH deploy keys, K3s bootstrap tokens, and network parameters directly from Vault (`https://192.168.0.40:8200`):

| Variable Key | Type | Protected | Masked | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`VAULT_ADDR`** | Variable | Yes | No | `https://192.168.0.40:8200` (Vault Load Balancer) |
| **`VAULT_SKIP_VERIFY`** | Variable | Yes | No | `true` (Self-signed certificate) |
| **`VAULT_TOKEN`** | Variable | **Yes** | **Yes** | Scoped Vault token with `k3s-stage-bootstrap` / `k3s-prod-bootstrap` policy |
| **`TF_VAR_pve_host_1_endpoint`** | Variable | Yes | No | `https://colossus.jnet.lan:8006/` |
| **`TF_VAR_pve_host_1_api_token`** | Variable | **Yes** | **Yes** | `terraform-ci@pve!gitlab-runner=xxxxxxxx...` (Host 1: Colossus) |
| **`TF_VAR_pve_host_2_endpoint`** | Variable | Yes | No | `https://guardian.jnet.lan:8006/` |
| **`TF_VAR_pve_host_2_api_token`** | Variable | **Yes** | **Yes** | `terraform-ci@pve!gitlab-runner=xxxxxxxx...` (Host 2: Guardian) |
| **`TF_VAR_pve_endpoint`** *(Fallback)* | Variable | Yes | No | `https://guardian.jnet.lan:8006/` |
| **`TF_VAR_pve_api_token`** *(Fallback)* | Variable | **Yes** | **Yes** | `terraform-ci@pve!gitlab-runner=xxxxxxxx...` |

### 3.2 Optional Manual Overrides

If you prefer providing static SSH keys directly in GitLab instead of pulling from Vault:

| Variable Key | Type | Protected | Masked | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`TF_VAR_ssh_public_keys`** | Variable | Optional | No | Single public key string or JSON array: `ssh-ed25519 AAAAC3Nza...` |
| **`SSH_PRIVATE_KEY`** | Variable | Optional | **No** *(Unchecked)* | Entire content of private deploy key |

> [!TIP]
> **Pure GitOps Flow**:
> 1. When a commit is pushed to `main`, GitLab CI triggers `stage:vault:seed`.
> 2. `stage:vault:seed` checks Vault; if SSH keys or K3s join tokens don't exist yet, it generates and stores them in Vault.
> 3. `terraform:apply` and `ansible:configure` query Vault at runtime to inject keys into VMs and memory.
> 4. Upon completion, Ansible pushes the cluster `kubeconfig` to Vault (`secret/data/k3s-stage/cluster` or `secret/data/k3s-prod/cluster`).
> 5. **Result**: Zero static secrets checked into Git, and end-to-end automation!

---

## 4. GitLab Managed Terraform State Backends (Automatic)

The pipeline is pre-configured to use GitLab's built-in HTTP state management for each environment:

- **Stage State Address**: `${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/k3s-stage`
- **Prod State Address**: `${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/k3s-prod`
- **Authentication**: Automatically handled using GitLab's built-in `${CI_JOB_TOKEN}` and `gitlab-ci-token`.
- **Locking**: GitLab automatically acquires a POST lock during `terraform plan`/`apply` and releases it with DELETE upon job completion.

---

## 5. GitLab Runner Requirements

The pipeline uses standard Docker images:
- `hashicorp/terraform:1.8.5` (Stages: `validate`, `plan:*`, `apply:*`)
- `alpine/ansible:2.21.0` (Stages: `validate`, `configure:*`)
- `bitnami/kubectl:latest` (Stages: `verify:*`)

**Network Connectivity Requirement**:
The GitLab Runner executing the jobs must have Layer 3 network access to:
- Proxmox API: `https://guardian.jnet.lan:8006/` and `https://colossus.jnet.lan:8006/` (TCP `8006`)
- Vault Load Balancer: `https://192.168.0.40:8200` (TCP `8200`)
- Provisioned VM Management Network: `192.168.0.0/24` (SSH TCP `22`, K3s API TCP `6443`)

---

## 6. Multi-Environment Pipeline Execution Flow

When a merge request or push to `main` is triggered:

1. **Validation Stage (`validate`)**:
   - `terraform:validate:stage` & `terraform:validate:prod`
   - `ansible:validate` (checks syntax of all playbooks against stage inventory)
2. **Stage Pipeline (`*:stage`)**:
   - `stage:vault:seed` (idempotently seeds stage secrets in Vault)
   - `stage:terraform:plan` (generates execution plan against `k3s-stage` state)
   - `stage:terraform:apply` (provisions VMs 2001-2013 on `guardian`)
   - `stage:ansible:configure` (applies OS hardening & deploys K3s HA cluster with VIP `192.168.0.41`)
   - `stage:k3s:verify` (validates all 6 stage nodes report `Ready`)
3. **Prod Pipeline (`*:prod`)**:
   - `prod:terraform:plan` (manual trigger on `main`)
   - `prod:terraform:apply` (manual trigger: provisions VMs 3001-3015 on `colossus`)
   - `prod:ansible:configure` (manual trigger: deploys K3s HA cluster on `colossus` with VIP `192.168.0.42`)
   - `prod:k3s:verify` (manual trigger: validates all 8 prod nodes report `Ready`)

