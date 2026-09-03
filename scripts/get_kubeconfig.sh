#!/usr/bin/env bash
# ==============================================================================
# Fetch Kubeconfig from Vault or Primary Node
# Usage: bash scripts/get_kubeconfig.sh [stage|prod] [vip_ip] [ssh_user]
# ==============================================================================

set -euo pipefail

ENV="${1:-${ENV:-stage}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_VIP="192.168.0.43"
if [[ "${ENV}" == "prod" ]]; then
    DEFAULT_VIP="192.168.0.44"
fi

KUBE_VIP_IP="${2:-${DEFAULT_VIP}}"
SSH_USER="${3:-almalinux}"
OUTPUT_FILE="${REPO_ROOT}/credentials/${ENV}/kubeconfig.yaml"

VAULT_ADDR="${VAULT_ADDR:-https://192.168.0.40:8200}"
export VAULT_ADDR
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

# 1. Try pulling from Vault first if authenticated or if token is present
TOKEN="${VAULT_TOKEN:-}"
if [[ -z "${TOKEN}" ]] && command -v vault >/dev/null 2>&1; then
    TOKEN="$(vault print token 2>/dev/null || echo '')"
fi

if [[ -n "${TOKEN}" ]]; then
    echo "[INFO] Vault token detected. Pulling kubeconfig from ${VAULT_ADDR} (secret/data/k3s-${ENV}/cluster)..."
    KUBECONFIG_DATA=$(curl -k -s --header "X-Vault-Token: ${TOKEN}" "${VAULT_ADDR}/v1/secret/data/k3s-${ENV}/cluster" | jq -r '.data.data.kubeconfig // empty')
    if [[ -n "${KUBECONFIG_DATA}" ]]; then
        echo "${KUBECONFIG_DATA}" > "${OUTPUT_FILE}"
        chmod 600 "${OUTPUT_FILE}"
        echo "[OK] Kubeconfig successfully retrieved from Vault and saved to: ${OUTPUT_FILE}"
        echo "Test connection:"
        kubectl --kubeconfig="${OUTPUT_FILE}" get nodes -o wide || true
        exit 0
    else
        echo "[WARN] Vault secret 'secret/data/k3s-${ENV}/cluster' not populated yet. Falling back to SSH extraction..."
    fi
fi

# 2. Fallback to SSH extraction from primary control plane node
INVENTORY_FILE="${REPO_ROOT}/environments/${ENV}/ansible/hosts.yaml"
PRIMARY_IP=$(grep -A 10 "k3s_control_plane:" "${INVENTORY_FILE}" 2>/dev/null | grep "ansible_host:" | head -n 1 | awk '{print $2}' || echo "${KUBE_VIP_IP}")

echo "[INFO] Fetching /etc/rancher/k3s/k3s.yaml from ${SSH_USER}@${PRIMARY_IP} (setting endpoint to VIP ${KUBE_VIP_IP})..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${PRIMARY_IP}" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s/127.0.0.1/${KUBE_VIP_IP}/g" \
    > "${OUTPUT_FILE}"

chmod 600 "${OUTPUT_FILE}"

echo "[OK] Kubeconfig successfully saved to: ${OUTPUT_FILE}"
echo "Test connection:"
kubectl --kubeconfig="${OUTPUT_FILE}" get nodes -o wide || true
