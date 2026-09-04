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

# 1. Resolve the GitLab Access Token
# Sources, in order of precedence:
#   1. the GITLAB_TOKEN environment variable (e.g. a masked CI/CD variable)
#   2. secret/data/k3s-<env>/credentials - env-scoped, written by vault_seed.sh
#      alongside the rest of this environment's credentials
#   3. secret/data/gitlab/credentials - shared path, the natural home for a
#      credential that isn't environment-specific: one place to rotate it
# Reading (3) requires the Vault policy to grant read on secret/data/gitlab/*
# (see docs/vault-integration.md) - the k3s-bootstrap policy historically only
# covered the k3s-<env> prefixes, so a token stored there returned 403 and the
# lookup silently came back empty.
VAULT_TOKEN_PATHS=(
    "secret/data/k3s-${ENV}/credentials"
    "secret/data/gitlab/credentials"
)

GITLAB_TOKEN="${GITLAB_TOKEN:-}"
if [[ -n "${GITLAB_TOKEN}" ]]; then
    echo "[STEP 1/4] Using GitLab token from the environment."
elif [[ -z "${VAULT_TOKEN}" ]]; then
    echo "[STEP 1/4] No GITLAB_TOKEN in the environment, and no VAULT_TOKEN to look one up with."
else
    for token_path in "${VAULT_TOKEN_PATHS[@]}"; do
        echo "[STEP 1/4] Looking for a GitLab token at ${token_path}..."
        GITLAB_SECRET_JSON=$(curl -k -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${token_path}" | jq -r '.data.data // empty' 2>/dev/null || echo "")
        if [[ -n "${GITLAB_SECRET_JSON}" ]]; then
            GITLAB_TOKEN=$(echo "${GITLAB_SECRET_JSON}" | jq -r '.gitlab_token // empty')
        fi
        if [[ -n "${GITLAB_TOKEN}" ]]; then
            echo "[OK] GitLab token resolved from ${token_path}"
            break
        fi
    done
fi

if [[ -z "${GITLAB_TOKEN}" ]]; then
    echo "[ERROR] Failed to obtain a GitLab token. Checked, in order:"
    echo "          - GITLAB_TOKEN environment variable"
    for token_path in "${VAULT_TOKEN_PATHS[@]}"; do
        echo "          - field 'gitlab_token' at ${token_path}"
    done
    echo "        Fix by either:"
    echo "          GITLAB_TOKEN=<pat> bash scripts/vault_seed.sh ${ENV}"
    echo "          or setting GITLAB_TOKEN as a masked CI/CD variable."
    echo "        Note: reading secret/data/gitlab/* requires that prefix in the Vault policy."
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
