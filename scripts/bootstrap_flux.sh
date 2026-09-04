#!/usr/bin/env bash
# ==============================================================================
# Automated Flux CD Bootstrapper for K3s Clusters (Stage & Prod)
# Usage:
#   bash scripts/bootstrap_flux.sh [stage|prod]
# ==============================================================================

set -euo pipefail

ENV="${1:-stage}"
GITLAB_HOST="gitbox.jnet.lan"
GITLAB_OWNER="jnet-labs"
GITLAB_REPO="infra-k3s-gitops"
GITLAB_BRANCH="main"
CLUSTER_PATH="clusters/${ENV}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG_FILE="${REPO_ROOT}/credentials/${ENV}/kubeconfig.yaml"

VAULT_ADDR="${VAULT_ADDR:-https://192.168.0.40:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

echo "================================================================================"
echo "[INFO] Flux CD Bootstrap for Environment: ${ENV}"
echo "       GitLab Repository: ${GITLAB_HOST}/${GITLAB_OWNER}/${GITLAB_REPO}"
echo "       Cluster Path:      ${CLUSTER_PATH}"
echo "================================================================================"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
    echo "[ERROR] Kubeconfig not found at: ${KUBECONFIG_FILE}"
    exit 1
fi
export KUBECONFIG="${KUBECONFIG_FILE}"

# 1. Fetch GitLab Access Token from Vault
echo "[STEP 1/4] Retrieving GitLab Token from Vault..."
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
if [[ -z "${GITLAB_TOKEN}" && -n "${VAULT_TOKEN}" ]]; then
    GITLAB_SECRET_JSON=$(curl -k -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/secret/data/gitlab/credentials" | jq -r '.data.data // empty' 2>/dev/null || echo "")
    if [[ -n "${GITLAB_SECRET_JSON}" ]]; then
        GITLAB_TOKEN=$(echo "${GITLAB_SECRET_JSON}" | jq -r '.gitlab_token // .token // empty')
    fi
fi

if [[ -z "${GITLAB_TOKEN}" ]]; then
    echo "[ERROR] Failed to obtain GITLAB_TOKEN from Vault (secret/gitlab/credentials) or environment."
    exit 1
fi
export GITLAB_TOKEN

# 2. Extract GitLab Internal CA Certificate
echo "[STEP 2/4] Downloading GitLab CA certificate from ${GITLAB_HOST}:443..."
CA_FILE="/tmp/gitlab-ca.crt"
if openssl s_client -showcerts -connect "${GITLAB_HOST}:443" </dev/null 2>/dev/null | openssl x509 -outform PEM > "${CA_FILE}"; then
    echo "[OK] CA certificate saved to ${CA_FILE}"
else
    echo "[WARN] Could not retrieve CA from ${GITLAB_HOST}:443 via openssl; checking system certificates."
    CA_FILE=""
fi

# 3. Ensure Flux CLI is available
echo "[STEP 3/4] Verifying Flux CLI..."
if ! command -v flux &> /dev/null; then
    echo "[INFO] Installing Flux CLI..."
    curl -s https://fluxcd.io/install.sh | bash
fi
flux --version

# 4. Execute Flux Bootstrap
# Note: jnet-labs is a Group, so we do NOT pass --personal.
# Running WITHOUT --token-auth configures Flux to automatically generate and register an SSH Deploy Key in GitLab!
echo "[STEP 4/4] Running Flux bootstrap for GitLab..."

BOOTSTRAP_ARGS=(
    bootstrap gitlab
    --hostname="${GITLAB_HOST}"
    --owner="${GITLAB_OWNER}"
    --repository="${GITLAB_REPO}"
    --branch="${GITLAB_BRANCH}"
    --path="${CLUSTER_PATH}"
)

if [[ -n "${CA_FILE}" && -s "${CA_FILE}" ]]; then
    BOOTSTRAP_ARGS+=(--ca-file="${CA_FILE}")
fi

flux "${BOOTSTRAP_ARGS[@]}"

echo "================================================================================"
echo "[SUCCESS] Flux CD successfully bootstrapped for ${ENV} (${CLUSTER_PATH})!"
echo "================================================================================"
