# K3s Multi-Environment Infrastructure Bootstrap (`infra-k3s-bootstrap`)

An enterprise GitOps and infrastructure automation framework that provisions and configures highly available K3s Kubernetes clusters across **STAGE** and **PROD** environments on Proxmox VE hosts using **Terraform**, **Ansible**, **HashiCorp Vault**, and **GitLab CI/CD**.

---

## 📐 Multi-Environment Architecture

The repository supports independent lifecycles for **STAGE** and **PROD** clusters using shared Terraform modules and reusable Ansible playbooks/roles.

### Environment Matrix

| Parameter | STAGE | PROD |
| :--- | :--- | :--- |
| **Proxmox VE Host** | `guardian.jnet.lan` | `colossus.jnet.lan` |
| **Control Plane VIP** | `192.168.0.43` | `192.168.0.44` |
| **DNS Endpoint** | `k3s-stage.jnet.lan` | `k3s-prod.jnet.lan` |
| **Node Naming Pattern**| `k3s-cp-s-<rand>` / `k3s-wk-s-<rand>` | `k3s-cp-p-<rand>` / `k3s-wk-p-<rand>` |
| **Internal Cluster VLAN**| VLAN `20` (`10.20.20.0/24`) | VLAN `30` (`10.30.30.0/24`) |
| **VM ID Range (CP)** | `3001 - 3003` (3 nodes) | `4001 - 4003` (3 nodes) |
| **VM ID Range (Worker)**| `3011 - 3013` (3 nodes) | `4011 - 4015` (5 nodes) |
| **Control Plane Sizing**| 2 vCPU / 4GB RAM / 32+20GB Disk | 2 vCPU / 4GB RAM / 32+20GB Disk |
| **Worker Node Sizing** | 4 vCPU / 4GB RAM / 32+50GB Disk | 4 vCPU / 4GB RAM / 32+50GB Disk |
| **Vault Secret Path** | `secret/data/k3s-stage/*` | `secret/data/k3s-prod/*` |
| **GitLab TF State** | `k3s-stage` | `k3s-prod` |

---

## 🛠️ Repository Layout

```
.
├── .gitlab-ci.yml                      # Dynamic multi-environment pipeline (Stage auto, Prod manual)
├── Makefile                            # Target-aware automation (e.g. make plan ENV=stage)
├── README.md
├── environments/
│   ├── stage/
│   │   ├── ansible/
│   │   │   ├── group_vars/             # Stage VIP, domain, Vault paths
│   │   │   │   ├── all.yaml
│   │   │   │   ├── k3s_control_plane.yaml
│   │   │   │   └── k3s_workers.yaml
│   │   │   └── hosts.yaml              # Stage inventory
│   │   └── terraform/
│   │       ├── backend.tf              # HTTP backend targeting k3s-stage
│   │       ├── main.tf                 # Calls terraform/modules/k3s_nodes
│   │       ├── outputs.tf
│   │       ├── variables.tf
│   │       └── terraform.tfvars        # Stage sizing, VM IDs, VIP
│   └── prod/
│       ├── ansible/
│       │   ├── group_vars/             # Prod VIP, domain, Vault paths
│       │   │   ├── all.yaml
│       │   │   ├── k3s_control_plane.yaml
│       │   │   └── k3s_workers.yaml
│       │   └── hosts.yaml              # Prod inventory
│       └── terraform/
│           ├── backend.tf              # HTTP backend targeting k3s-prod
│           ├── main.tf                 # Calls terraform/modules/k3s_nodes
│           ├── outputs.tf
│           ├── variables.tf
│           └── terraform.tfvars        # Prod sizing, VM IDs, VIP
├── ansible/
│   ├── ansible.cfg                     # Updated roles path
│   ├── playbooks/                      # 100% reusable across stage and prod
│   │   ├── provision_k3s.yaml
│   │   ├── provision_os.yaml
│   │   ├── redeploy_node.yaml
│   │   ├── reset_cluster.yaml
│   │   ├── rolling_update.yaml
│   │   ├── seed_vault.yaml
│   │   └── site.yaml
│   ├── requirements.yaml
│   └── roles/
│       ├── k3s_common/
│       ├── k3s_control_plane/
│       └── k3s_worker/
├── terraform/
│   └── modules/
│       └── k3s_nodes/                  # Shared VM provisioning module
│           ├── main.tf
│           ├── outputs.tf
│           ├── variables.tf
│           └── versions.tf
├── scripts/                            # Parameterized with $ENV or CLI argument
│   ├── discover_node_ips.py
│   ├── discover_node_ips.sh
│   ├── get_kubeconfig.sh
│   ├── k3s_env.sh
│   ├── redeploy_node.sh
│   ├── rolling_upgrade.sh
│   ├── vault_seed.sh
│   └── vault_sync.sh
└── docs/
    ├── architecture.md
    ├── gitlab-setup.md
    ├── node-repaving.md
    ├── operations.md
    ├── rolling-updates.md
    └── vault-integration.md
```

---

## 🚀 Quick Start & CLI Usage

All Makefile targets accept `ENV=stage` (default) or `ENV=prod`:

```bash
# 1. Seed Vault credentials (SSH keys, tokens, endpoints)
make seed ENV=stage

# 2. Plan infrastructure via Terraform
make plan ENV=stage

# 3. Provision VMs on Proxmox VE
make apply ENV=stage

# 4. Configure OS hardening & deploy K3s cluster via Ansible
make configure ENV=stage

# 5. Fetch kubeconfig & verify cluster readiness
make kubeconfig ENV=stage
make verify ENV=stage

# Day-2 Operations:
make rolling-upgrade ENV=stage   # Sequential zero-downtime rolling update
make repave ENV=stage            # Full VM rolling rebuild from base template
```

---

## 📚 Detailed Documentation

Detailed guides and runbooks are available in the [`docs/`](docs/) directory:

- [**GitOps Workflow & Promotion Guide**](docs/gitops-workflow.md): Comprehensive guide covering child pipelines, promoting code from STAGE to PROD, automated node recovery via pipeline, and release tag workflows.
- [**Architecture & Hardware Layout**](docs/architecture.md): Dual-network topology (DHCP management & VLAN cluster network), kube-vip HA, Flannel `host-gw`, IPVS proxy, dedicated etcd and Longhorn storage disks.
- [**GitLab CI/CD Setup**](docs/gitlab-setup.md): Complete guide for GitLab runner setup, HTTP state backend, CI/CD variables, and multi-environment pipeline flow.
- [**HashiCorp Vault Secrets Management**](docs/vault-integration.md): Structure of `secret/data/k3s-stage/*` and `secret/data/k3s-prod/*`, automated seeding, ACL policies, and kubeconfig synchronization.
- [**Operations & Day-2 Runbook**](docs/operations.md): Verification commands, SSH access via DHCP discovery, troubleshooting logs, cluster reset, and teardown.
- [**Rolling Upgrades & Maintenance**](docs/rolling-updates.md): Sequential 3-phase rolling upgrade runbook (Workers $\rightarrow$ Secondary Control Planes $\rightarrow$ Primary Control Plane).
- [**Single-Node Repaving & DR**](docs/node-repaving.md): Single-node destruction, recreation via Terraform, re-hardening via Ansible, and zero-downtime rejoin.
