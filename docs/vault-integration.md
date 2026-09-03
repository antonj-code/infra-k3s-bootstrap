# HashiCorp Vault Secrets Management Integration

This guide details how the **`infra-k3s-bootstrap`** framework integrates with the **HashiCorp Vault Load Balancer** (`https://192.168.0.40:8200`) to securely store and manage bootstrap tokens, Proxmox credentials, SSH deployment keys, and generated cluster `kubeconfig` files across **STAGE** and **PROD** environments.

> [!NOTE]
> **Load Balancer & Self-Signed Certificate**:
> - **Endpoint**: `https://192.168.0.40:8200` (Dedicated Load Balancer fronting the Vault cluster).
> - **TLS / SSL**: The Vault load balancer uses a **self-signed SSL certificate**. All tooling, scripts, Ansible playbooks, and pipelines are configured to bypass TLS validation checks (`VAULT_SKIP_VERIFY="true"` / `validate_certs: false` / `curl -k`).

---

## 1. Vault KV v2 Secrets Layout

All Kubernetes infrastructure secrets are organized under environment-isolated KV v2 paths (**`secret/k3s-stage/`** and **`secret/k3s-prod/`**):

```
secret/data/k3s-stage/ (and secret/data/k3s-prod/)
├── bootstrap                  # K3s cluster join token & network settings
│   ├── token                  # Shared K3s bootstrap secret token
│   ├── cluster_cidr           # 10.42.0.0/16
│   ├── service_cidr           # 10.43.0.0/16
│   ├── flannel_backend        # host-gw
│   ├── kube_proxy_mode        # ipvs
│   ├── kube_vip_address       # 192.168.0.41 (stage) / 192.168.0.42 (prod)
│   └── kube_vip_hostname      # k3s-stage.jnet.lan / k3s-prod.jnet.lan
├── credentials                # Infrastructure deployment credentials
│   ├── pve_host_1_endpoint    # https://colossus.jnet.lan:8006/
│   ├── pve_host_1_api_token   # Proxmox API token for colossus
│   ├── pve_host_1_node_name   # colossus
│   ├── pve_host_2_endpoint    # https://guardian.jnet.lan:8006/
│   ├── pve_host_2_api_token   # Proxmox API token for guardian
│   ├── pve_host_2_node_name   # guardian
│   ├── ssh_private_key        # Deploy private key used by CI/CD / Ansible
│   └── ssh_public_key         # Deploy public key injected into Cloud-Init VMs
└── cluster                    # Post-deployment cluster artifacts
    ├── kubeconfig             # Full sanitized admin kubeconfig (YAML)
    ├── api_endpoint           # https://<kube_vip_address>:6443
    ├── primary_node           # Hostname of the primary control plane
    └── updated_at             # ISO 8601 UTC timestamp
```

---

## 2. Automated Seeding (One-Click)

We provide [`scripts/vault_seed.sh`](../scripts/vault_seed.sh) and Makefile targets to automate secret generation and injection:

```bash
# Seed Stage secrets (idempotent):
make seed ENV=stage
# Or directly via script:
bash scripts/vault_seed.sh stage

# Seed Prod secrets:
make seed ENV=prod
# Or directly via script:
bash scripts/vault_seed.sh prod

# Force-regenerate / overwrite all secrets:
make seed-force ENV=stage
```

### What `vault_seed.sh` does automatically:
1. **Bypasses SSL Verification**: Automatically sets `export VAULT_ADDR="https://192.168.0.40:8200"` and `export VAULT_SKIP_VERIFY="true"`.
2. **Generates SSH Key Pair**: Checks if `~/.ssh/k3s_${ENV}_deploy_key` exists; if not, generates a 256-bit Ed25519 key pair with tag `gitlab-runner-k3s-${ENV}@gitbox.jnet.lan`.
3. **Generates Random K3s Token**: Creates a cryptographically strong 48-hex character bootstrap token (`openssl rand -hex 24`).
4. **Writes KV v2 Secrets**: Stores `secret/data/k3s-${ENV}/bootstrap` and `secret/data/k3s-${ENV}/credentials` (for both `colossus` and `guardian`).

---

## 3. Manual / CLI Seeding Reference

If you prefer executing the individual CLI commands manually:

```bash
# Set Vault environment variables (Load Balancer with Self-Signed SSL)
export VAULT_ADDR="https://192.168.0.40:8200"
export VAULT_SKIP_VERIFY="true"
vault login

# 1. Apply ACL Policy for Stage and Prod
cat <<EOF | vault policy write k3s-bootstrap -
# Allow mount discovery
path "sys/internal/ui/mounts/*" {
  capabilities = ["read"]
}
path "sys/internal/ui/mounts/secret" {
  capabilities = ["read"]
}
path "sys/mounts" {
  capabilities = ["read"]
}

# Read & Write K3s secrets across environments
path "secret/data/k3s-stage/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/k3s-stage/*" {
  capabilities = ["read", "list", "delete"]
}
path "secret/data/k3s-prod/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/k3s-prod/*" {
  capabilities = ["read", "list", "delete"]
}
EOF

# 2. Store K3s Stage Bootstrap Token & Network Config
vault kv put -mount=secret k3s-stage/bootstrap \
  token="k3s-cluster-token-secret-jnet-labs-guardian-stage" \
  cluster_cidr="10.42.0.0/16" \
  service_cidr="10.43.0.0/16" \
  flannel_backend="host-gw" \
  kube_proxy_mode="ipvs" \
  kube_vip_address="192.168.0.41" \
  kube_vip_hostname="k3s-stage.jnet.lan"

# 3. Store SSH Deployment Keys & Proxmox Tokens
vault kv put -mount=secret k3s-stage/credentials \
  pve_host_1_endpoint="https://colossus.jnet.lan:8006/" \
  pve_host_1_api_token="terraform-ci@pve!gitlab-runner=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
  pve_host_1_node_name="colossus" \
  pve_host_2_endpoint="https://guardian.jnet.lan:8006/" \
  pve_host_2_api_token="terraform-ci@pve!gitlab-runner=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" \
  pve_host_2_node_name="guardian" \
  pve_endpoint="https://guardian.jnet.lan:8006/" \
  pve_api_token="terraform-ci@pve!gitlab-runner=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" \
  ssh_public_key="$(cat ~/.ssh/k3s_stage_deploy_key.pub)" \
  ssh_private_key="$(cat ~/.ssh/k3s_stage_deploy_key)"
```

---

## 4. Automated Kubeconfig Synchronization to Vault

When the `ansible:configure` pipeline stage completes:
1. Ansible extracts `/etc/rancher/k3s/k3s.yaml` from the bootstrap primary control plane node.
2. It replaces `127.0.0.1` with the kube-vip Virtual IP (`192.168.0.41` for stage, `192.168.0.42` for prod).
3. If `VAULT_TOKEN` is set, Ansible writes the sanitized `kubeconfig` directly to:
   `secret/data/k3s-<env>/cluster` field `kubeconfig` with `validate_certs: false`.

### Fetching Kubeconfig from Vault Programmatically:

```bash
# Using Makefile:
make kubeconfig ENV=stage

# Using the helper script (pulls from Vault if token is set, else SSH fallback):
bash scripts/get_kubeconfig.sh stage

# Using the Vault sync utility:
bash scripts/vault_sync.sh pull stage

# Using raw Vault CLI:
export VAULT_ADDR="https://192.168.0.40:8200"
export VAULT_SKIP_VERIFY="true"
vault kv get -mount=secret -field=kubeconfig k3s-stage/cluster > credentials/stage/kubeconfig.yaml
chmod 600 credentials/stage/kubeconfig.yaml

kubectl --kubeconfig=credentials/stage/kubeconfig.yaml get nodes -o wide
```

