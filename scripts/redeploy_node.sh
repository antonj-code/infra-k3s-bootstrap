#!/usr/bin/env bash
# ==============================================================================
# Automated Single-Node Repaving & Disaster Recovery Script
# Usage:
#   bash scripts/redeploy_node.sh <node_name> [stage|prod]
# ==============================================================================

set -euo pipefail

NODE_NAME="${1:-}"
ENV="${2:-${ENV:-stage}}"

if [[ -z "${NODE_NAME}" ]]; then
    echo "[ERROR] Node name is required."
    echo "Usage: $0 <node_name> [stage|prod]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${REPO_ROOT}/environments/${ENV}/ansible/hosts.yaml"
TF_DIR="${REPO_ROOT}/environments/${ENV}/terraform"
KUBECONFIG_FILE="${REPO_ROOT}/credentials/${ENV}/kubeconfig.yaml"

echo "================================================================================"
echo "[INFO] Disaster Recovery & Redeployment for Node: ${NODE_NAME} (Env: ${ENV})"
echo "================================================================================"

# --- Step 1: Identify Resource Target ---
if [[ "${NODE_NAME}" =~ ^k3s-cp- ]]; then
    NODE_ROLE="control-plane"
    CP_LIST=$(grep -A 30 "k3s_control_plane:" "${INVENTORY_FILE}" 2>/dev/null | grep -E "^\s+k3s-cp-[a-z0-9]+:" | sed 's/://;s/^[ \t]*//' || echo "")
    INDEX=0
    i=0
    for cp in ${CP_LIST}; do
        if [[ "${cp}" == "${NODE_NAME}" ]]; then
            INDEX=$i
            break
        fi
        i=$((i + 1))
    done
    TF_RESOURCE="module.k3s_nodes.proxmox_virtual_environment_vm.k3s_control_plane[${INDEX}]"
elif [[ "${NODE_NAME}" =~ ^k3s-wk- || "${NODE_NAME}" =~ ^k3s-worker- ]]; then
    NODE_ROLE="worker"
    WK_LIST=$(grep -A 30 "k3s_workers:" "${INVENTORY_FILE}" 2>/dev/null | grep -E "^\s+k3s-wk-[a-z0-9]+:" | sed 's/://;s/^[ \t]*//' || echo "")
    INDEX=0
    i=0
    for wk in ${WK_LIST}; do
        if [[ "${wk}" == "${NODE_NAME}" ]]; then
            INDEX=$i
            break
        fi
        i=$((i + 1))
    done
    TF_RESOURCE="module.k3s_nodes.proxmox_virtual_environment_vm.k3s_workers[${INDEX}]"
else
    echo "[ERROR] Invalid node name format: ${NODE_NAME}"
    exit 1
fi

echo "[INFO] Node Role: ${NODE_ROLE}"
echo "[INFO] Resource Index: ${INDEX}"
echo "[INFO] Terraform Target: ${TF_RESOURCE}"

# --- Step 2: Cordon and Delete Node from Kubernetes (if possible) ---
if [[ -f "${KUBECONFIG_FILE}" ]]; then
    echo "[STEP 1/4] Cordoning and removing node from Kubernetes cluster state..."
    export KUBECONFIG="${KUBECONFIG_FILE}"
    if ! kubectl drain "${NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=180s; then
      echo "[ERROR] Failed to drain node ${NODE_NAME}. Aborting redeploy to prevent data loss."
      exit 1
    fi
    kubectl delete node "${NODE_NAME}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
fi

# --- Step 3: Destroy and Recreate VM via Terraform ---
echo "[STEP 2/4] Recreating VM in Proxmox via Terraform..."
cd "${TF_DIR}"

if [[ ! -f "terraform.auto.tfvars.json" && -f "${HOME}/.ssh/k3s_test_deploy_key.pub" ]]; then
    CLEAN_KEY=$(cat "${HOME}/.ssh/k3s_test_deploy_key.pub" | sed 's/^[["'\'' ]*//;s/[]"'\'' ]*$//')
    cat << EOF_JSON > terraform.auto.tfvars.json
{
  "ssh_public_keys": ["${CLEAN_KEY}"]
}
EOF_JSON
fi

terraform apply -replace="${TF_RESOURCE}" -auto-approve -input=false

# Discover and update new DHCP IP address
bash "${REPO_ROOT}/scripts/discover_node_ips.sh" "${ENV}"

# --- Step 4: Run Ansible Re-Hardening & Cluster Rejoin ---
echo "[STEP 3/4] Hardening OS and rejoining ${NODE_NAME} to K3s cluster..."
cd "${REPO_ROOT}/ansible"
ansible-playbook -i "${INVENTORY_FILE}" playbooks/redeploy_node.yaml -e "target_node=${NODE_NAME}"

# --- Step 5: Verification ---
echo "[STEP 4/4] Validating cluster readiness..."
if [[ -f "${KUBECONFIG_FILE}" ]]; then
    export KUBECONFIG="${KUBECONFIG_FILE}"
    kubectl get nodes -o wide
fi

echo "================================================================================"
echo "[SUCCESS] Node '${NODE_NAME}' successfully redeployed and verified Ready!"
echo "================================================================================"
