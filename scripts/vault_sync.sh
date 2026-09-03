#!/usr/bin/env bash
# ==============================================================================
# HashiCorp Vault Secrets Sync Helper for K3s Cluster
# Usage:
#   bash scripts/vault_sync.sh [push|pull] [stage|prod]
# ==============================================================================

set -euo pipefail

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "[ERROR] VAULT_TOKEN is not set. Export it before running this script."
  exit 1
fi

ACTION="${1:-pull}"
ENV="${2:-${ENV:-stage}}"

DEFAULT_VIP="192.168.0.41"
if [[ "${ENV}" == "prod" ]]; then
    DEFAULT_VIP="192.168.0.42"
fi

VAULT_ADDR="${VAULT_ADDR:-https://192.168.0.40:8200}"
export VAULT_ADDR
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREDS_DIR="${REPO_ROOT}/credentials/${ENV}"
KUBECONFIG_FILE="${CREDS_DIR}/kubeconfig.yaml"

mkdir -p "${CREDS_DIR}"

if [[ "${ACTION}" == "push" ]]; then
    echo "[INFO] Pushing K3s credentials and kubeconfig for ${ENV} to Vault (${VAULT_ADDR})..."
    
    if [[ -f "${KUBECONFIG_FILE}" ]]; then
        KUBECONFIG_CONTENT=$(cat "${KUBECONFIG_FILE}")
        PAYLOAD=$(jq -n \
            --arg kc "${KUBECONFIG_CONTENT}" \
            --arg api "https://${DEFAULT_VIP}:6443" \
            --arg updated "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{"data": {kubeconfig: $kc, api_endpoint: $api, updated_at: $updated}}')
        
        HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
            --request POST \
            --header "X-Vault-Token: ${VAULT_TOKEN:-}" \
            --header "Content-Type: application/json" \
            --data "${PAYLOAD}" \
            "${VAULT_ADDR}/v1/secret/data/k3s-${ENV}/cluster")

        if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "204" ]]; then
            echo "[OK] Kubeconfig successfully uploaded to Vault path: secret/data/k3s-${ENV}/cluster"
        else
            echo "[ERROR] Failed to upload kubeconfig to Vault (HTTP ${HTTP_CODE})"
            exit 1
        fi
    else
        echo "[WARN] No local kubeconfig found at ${KUBECONFIG_FILE} to upload."
    fi

elif [[ "${ACTION}" == "pull" ]]; then
    echo "[INFO] Pulling K3s cluster kubeconfig for ${ENV} from Vault (${VAULT_ADDR})..."
    
    KUBECONFIG_DATA=$(curl -k -s \
        --header "X-Vault-Token: ${VAULT_TOKEN:-}" \
        "${VAULT_ADDR}/v1/secret/data/k3s-${ENV}/cluster" | jq -r '.data.data.kubeconfig // empty')

    if [[ -n "${KUBECONFIG_DATA}" ]]; then
        echo "${KUBECONFIG_DATA}" > "${KUBECONFIG_FILE}"
        chmod 600 "${KUBECONFIG_FILE}"
        echo "[OK] Kubeconfig successfully retrieved and saved to: ${KUBECONFIG_FILE}"
        echo "Testing connection:"
        kubectl --kubeconfig="${KUBECONFIG_FILE}" get nodes -o wide || true
    else
        echo "[WARN] Could not retrieve kubeconfig from secret/data/k3s-${ENV}/cluster."
        echo "       Ensure the cluster has been deployed and Vault credentials are valid."
    fi

else
    echo "Usage: $0 {push|pull} [stage|prod]"
    exit 1
fi
