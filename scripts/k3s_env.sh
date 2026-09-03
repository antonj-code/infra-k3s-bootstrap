#!/usr/bin/env bash
# ==============================================================================
# Environment helper for K3s cluster
# Source this file: source scripts/k3s_env.sh [stage|prod]
# ==============================================================================

ENV="${1:-${ENV:-stage}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export KUBECONFIG="${REPO_ROOT}/credentials/${ENV}/kubeconfig.yaml"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.0.40:8200}"
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"

if [ -f "${KUBECONFIG}" ]; then
    echo "[OK] Environment: ${ENV}"
    echo "[OK] KUBECONFIG set to: ${KUBECONFIG}"
    echo "Current cluster context:"
    kubectl cluster-info
else
    echo "[WARN] Kubeconfig not found at ${KUBECONFIG}."
    echo "       Run 'bash scripts/get_kubeconfig.sh ${ENV}' to fetch it."
fi
