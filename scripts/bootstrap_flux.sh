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
# Read from the same env-scoped path everything else in this repo uses
# (secret/data/k3s-<env>/credentials). The previous path, secret/gitlab/
# credentials, was never written by vault_seed.sh nor covered by the
# k3s-bootstrap Vault policy, so this lookup always came back empty.
VAULT_CREDENTIALS_PATH="secret/data/k3s-${ENV}/credentials"
echo "[STEP 1/4] Retrieving GitLab Token from Vault (${VAULT_CREDENTIALS_PATH})..."
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
if [[ -z "${GITLAB_TOKEN}" && -n "${VAULT_TOKEN}" ]]; then
    GITLAB_SECRET_JSON=$(curl -k -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${VAULT_CREDENTIALS_PATH}" | jq -r '.data.data // empty' 2>/dev/null || echo "")
    if [[ -n "${GITLAB_SECRET_JSON}" ]]; then
        GITLAB_TOKEN=$(echo "${GITLAB_SECRET_JSON}" | jq -r '.gitlab_token // empty')
    fi
fi

if [[ -z "${GITLAB_TOKEN}" ]]; then
    echo "[ERROR] Failed to obtain a GitLab token."
    echo "        Expected field 'gitlab_token' at ${VAULT_CREDENTIALS_PATH}, or a GITLAB_TOKEN environment variable."
    echo "        Seed it with: GITLAB_TOKEN=<pat> bash scripts/vault_seed.sh ${ENV}"
    exit 1
fi
export GITLAB_TOKEN

# 2. Extract the GitLab TLS chain to use as the trust bundle
# Piping -showcerts through `openssl x509` only ever emits the FIRST cert in
# the chain - the server's own leaf - which is not the issuing CA and only
# validates by accident when the cert is self-signed. Keep the whole chain
# instead: flux's --ca-file takes a PEM bundle, and a chain that terminates at
# an intermediate is still a usable trust anchor for the in-cluster
# source-controller.
echo "[STEP 2/4] Downloading GitLab TLS chain from ${GITLAB_HOST}:443..."
CA_FILE="/tmp/gitlab-ca.crt"
openssl s_client -showcerts -connect "${GITLAB_HOST}:443" </dev/null 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > "${CA_FILE}" || true

CERT_COUNT=$(grep -c 'BEGIN CERTIFICATE' "${CA_FILE}" 2>/dev/null || echo "0")
if [[ "${CERT_COUNT}" -gt 0 ]]; then
    echo "[OK] Saved ${CERT_COUNT} certificate(s) from the served chain to ${CA_FILE}"
else
    # Don't silently fall back to the system trust store: if gitbox uses a
    # private CA that isn't installed in this image, flux bootstrap fails on an
    # opaque TLS error instead of telling you the CA was never fetched.
    echo "[ERROR] Could not retrieve any certificate from ${GITLAB_HOST}:443."
    echo "        Flux would fall back to the system trust store and fail TLS verification"
    echo "        against the internal CA. Check connectivity to ${GITLAB_HOST}:443 from this runner."
    exit 1
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
# --token-auth uses the GitLab Access Token over HTTPS with the internal CA certificate.
echo "[STEP 4/4] Running Flux bootstrap for GitLab..."

BOOTSTRAP_ARGS=(
    bootstrap gitlab
    --hostname="${GITLAB_HOST}"
    --owner="${GITLAB_OWNER}"
    --repository="${GITLAB_REPO}"
    --branch="${GITLAB_BRANCH}"
    --path="${CLUSTER_PATH}"
    --token-auth
    --timeout=5m
)

if [[ -n "${CA_FILE}" && -s "${CA_FILE}" ]]; then
    BOOTSTRAP_ARGS+=(--ca-file="${CA_FILE}")
fi

flux "${BOOTSTRAP_ARGS[@]}"

echo "================================================================================"
echo "[SUCCESS] Flux CD successfully bootstrapped for ${ENV} (${CLUSTER_PATH})!"
echo "================================================================================"
