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
# Ask Terraform which address actually holds the VM named ${NODE_NAME} instead
# of inferring a count index from the node's position in the generated
# inventory. The positional approach read the inventory through a fixed
# `grep -A 30` window, which truncated at three workers (PROD has five) and
# then fell back to index 0 on a miss - i.e. it destroyed and rebuilt a healthy
# node while leaving the broken one untouched.
if [[ "${NODE_NAME}" =~ ^k3s-cp- ]]; then
    NODE_ROLE="control-plane"
elif [[ "${NODE_NAME}" =~ ^k3s-wk- || "${NODE_NAME}" =~ ^k3s-worker- ]]; then
    NODE_ROLE="worker"
else
    echo "[ERROR] Invalid node name format: ${NODE_NAME}"
    exit 1
fi

cd "${TF_DIR}"

if [[ ! -d .terraform ]]; then
    echo "[ERROR] ${TF_DIR} is not initialized."
    echo "        Run terraform init with the GitLab http backend config first"
    echo "        (the recover-node CI job does this in its before_script)."
    exit 1
fi

TF_RESOURCE=$(terraform show -json 2>/dev/null | jq -r --arg n "${NODE_NAME}" '
    [ .values.root_module | .. | objects | select(has("resources")) | .resources[]?
      | select(.type == "proxmox_virtual_environment_vm" and .values.name == $n)
      | .address ] | first // empty')

if [[ -z "${TF_RESOURCE}" ]]; then
    echo "[ERROR] No Terraform-managed VM named '${NODE_NAME}' found in the ${ENV} state."
    echo "        Refusing to guess a resource index. Check the name against:"
    echo "          terraform -chdir=${TF_DIR} state list"
    exit 1
fi

echo "[INFO] Node Role: ${NODE_ROLE}"
echo "[INFO] Terraform Target: ${TF_RESOURCE}"

# --- Step 2: Cordon and Delete Node from Kubernetes (if possible) ---
if [[ -f "${KUBECONFIG_FILE}" ]]; then
    echo "[STEP 1/4] Cordoning and removing node from Kubernetes cluster state..."
    export KUBECONFIG="${KUBECONFIG_FILE}"

    # A node broken badly enough to need repaving is often exactly the node
    # whose pods will not drain gracefully - an unreachable kubelet leaves pods
    # stuck Terminating until the timeout. Aborting there blocks the recovery
    # this script exists to perform, so a drain failure is only fatal while the
    # node is still Ready, which is the case where it genuinely means
    # "workloads could not be moved off a healthy node".
    NODE_READY=$(kubectl get node "${NODE_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

    if [[ -z "${NODE_READY}" ]]; then
        echo "[INFO] Node ${NODE_NAME} is not registered in the cluster; nothing to drain."
    elif kubectl drain "${NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=180s; then
        echo "[OK] Node ${NODE_NAME} drained."
    elif [[ "${NODE_READY}" == "True" ]]; then
        echo "[ERROR] Failed to drain healthy node ${NODE_NAME}. Aborting redeploy to prevent data loss."
        echo "        Drain it manually, or re-run once its workloads can be evicted."
        exit 1
    else
        echo "[WARN] Drain of ${NODE_NAME} did not complete, but the node is already NotReady"
        echo "       (Ready=${NODE_READY}). Continuing - the VM is about to be destroyed anyway."
    fi

    kubectl delete node "${NODE_NAME}" --ignore-not-found=true --timeout=30s 2>/dev/null || true
fi

# --- Step 3: Destroy and Recreate VM via Terraform ---
echo "[STEP 2/4] Recreating VM in Proxmox via Terraform..."
# Already in ${TF_DIR} from the resource lookup above.

if [[ ! -f "terraform.auto.tfvars.json" ]]; then
    PUB_KEY="${SSH_PUBLIC_KEY:-}"
    if [[ -z "${PUB_KEY}" && -f "${HOME}/.ssh/k3s_${ENV}_deploy_key.pub" ]]; then
        PUB_KEY=$(cat "${HOME}/.ssh/k3s_${ENV}_deploy_key.pub")
    fi
    # The recover-node CI job doesn't carry the plan/apply job's
    # terraform.auto.tfvars.json (those jobs never run in a recover pipeline)
    # and exports only the private key, so without this the replaced VM is
    # created with ssh_public_keys = [] and comes up with no authorized key -
    # unreachable, and unfixable in place because `initialization` is in the
    # resource's ignore_changes.
    if [[ -z "${PUB_KEY}" && -n "${VAULT_TOKEN:-}" ]]; then
        VAULT_ADDR="${VAULT_ADDR:-https://192.168.0.40:8200}"
        PUB_KEY=$(curl -k -s -H "X-Vault-Token: ${VAULT_TOKEN}" \
            "${VAULT_ADDR}/v1/secret/data/k3s-${ENV}/credentials" \
            | jq -r '.data.data.ssh_public_key // empty' 2>/dev/null || echo "")
    fi
    if [[ -z "${PUB_KEY}" ]]; then
        echo "[ERROR] No SSH public key available for the replacement VM."
        echo "        It would be created with no authorized key and be unreachable."
        echo "        Set SSH_PUBLIC_KEY, or provide VAULT_TOKEN so it can be read from"
        echo "        secret/data/k3s-${ENV}/credentials."
        exit 1
    fi
    CLEAN_KEY=$(echo "${PUB_KEY}" | sed 's/^[["'\'' ]*//;s/[]"'\'' ]*$//')
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
