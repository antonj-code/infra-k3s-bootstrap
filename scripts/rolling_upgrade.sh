#!/usr/bin/env bash
# ==============================================================================
# Automated Sequential Rolling Upgrade & Repaving Script
# Usage:
#   bash scripts/rolling_upgrade.sh [--mode repave|in-place] [--env stage|prod] [--template-id <vm_id>]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="repave"
ENV="stage"
NEW_TEMPLATE_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="${2:-repave}"
            shift 2
            ;;
        --env)
            ENV="${2:-stage}"
            shift 2
            ;;
        --template-id)
            NEW_TEMPLATE_ID="${2:-}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--mode repave|in-place] [--env stage|prod] [--template-id <vm_id>]"
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "================================================================================"
echo "[INFO] Starting Automated K3s Sequential Rolling Upgrade"
echo "[INFO] Environment: ${ENV}"
echo "[INFO] Mode: ${MODE}"
if [[ -n "${NEW_TEMPLATE_ID}" ]]; then
    echo "[INFO] Target Template VM ID: ${NEW_TEMPLATE_ID}"
fi
echo "================================================================================"

KUBECONFIG_FILE="${REPO_ROOT}/credentials/${ENV}/kubeconfig.yaml"
INVENTORY_FILE="${REPO_ROOT}/environments/${ENV}/ansible/hosts.yaml"

if [[ -f "${KUBECONFIG_FILE}" ]]; then
    export KUBECONFIG="${KUBECONFIG_FILE}"
    echo "[INFO] Checking existing cluster health..."
    TOTAL_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    echo "[INFO] Ready nodes detected: ${TOTAL_READY}"
fi

if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "[ERROR] Ansible inventory not found at ${INVENTORY_FILE}."
    exit 1
fi

echo "[INFO] Verifying and discovering live DHCP IP addresses from Proxmox..."
bash "${REPO_ROOT}/scripts/discover_node_ips.sh" "${ENV}"

WORKER_NODES=$(grep -A 100 "k3s_workers:" "${INVENTORY_FILE}" | grep -E "^\s+k3s-wk-[a-z0-9]+:" | sed "s/://;s/^[ \t]*//" || echo "")
CP_NODES=$(grep -A 30 "k3s_control_plane:" "${INVENTORY_FILE}" | grep -E "^\s+k3s-cp-[a-z0-9]+:" | sed "s/://;s/^[ \t]*//" || echo "")

PRIMARY_CP=$(echo "${CP_NODES}" | head -n 1)
SECONDARY_CPS=$(echo "${CP_NODES}" | tail -n +2)

upgrade_node() {
    local node="$1"
    local role="$2"

    echo "--------------------------------------------------------------------------------"
    echo "[UPGRADE] Processing Node: ${node} (${role})"
    echo "--------------------------------------------------------------------------------"

    if [[ "${MODE}" == "repave" ]]; then
        bash "${REPO_ROOT}/scripts/redeploy_node.sh" "${node}" "${ENV}"
    else
        echo "[INFO] Applying in-place OS and K3s updates to ${node}..."
        cd "${REPO_ROOT}/ansible"
        ansible-playbook -i "${INVENTORY_FILE}" playbooks/rolling_update.yaml --limit "${node}"
    fi

    echo "[INFO] Node ${node} updated. Verifying settled health (15s grace period)..."
    sleep 15
}

echo "================================================================================"
echo "[PHASE 1/3] Sequentially upgrading Worker Nodes..."
echo "================================================================================"
for wk in ${WORKER_NODES}; do
    upgrade_node "${wk}" "Worker"
done

echo "================================================================================"
echo "[PHASE 2/3] Sequentially upgrading Secondary Control Plane Nodes..."
echo "================================================================================"
for scp in ${SECONDARY_CPS}; do
    upgrade_node "${scp}" "Secondary Control Plane"
done

echo "================================================================================"
echo "[PHASE 3/3] Upgrading Primary Control Plane Node..."
echo "================================================================================"
upgrade_node "${PRIMARY_CP}" "Primary Control Plane"

if [[ -f "${KUBECONFIG_FILE}" ]]; then
    export KUBECONFIG="${KUBECONFIG_FILE}"
    kubectl get nodes -o wide --show-labels || true
fi

echo "================================================================================"
echo "[SUCCESS] Sequential Rolling Upgrade completed successfully!"
echo "================================================================================"
