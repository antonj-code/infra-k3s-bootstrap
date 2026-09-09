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
    if [[ "${MODE}" != "repave" ]]; then
        echo "[ERROR] --template-id only applies to --mode repave (in-place mode doesn't touch the VM template)."
        exit 1
    fi
    export TEMPLATE_VM_ID_OVERRIDE="${NEW_TEMPLATE_ID}"
fi
echo "================================================================================"

KUBECONFIG_FILE="${REPO_ROOT}/credentials/${ENV}/kubeconfig.yaml"
INVENTORY_FILE="${REPO_ROOT}/environments/${ENV}/ansible/hosts.yaml"

# Retry budget for the between-node health gate. Node readiness after a repave
# has to cover a full VM clone, cloud-init, hardening and cluster rejoin, so it
# is deliberately generous; etcd only has to re-add a member.
NODE_READY_RETRIES="${NODE_READY_RETRIES:-60}"
ETCD_HEALTH_RETRIES="${ETCD_HEALTH_RETRIES:-30}"
GATE_DELAY="${GATE_DELAY:-10}"

# The gate below is the only thing standing between a slow rejoin and a lost
# etcd quorum, so a missing kubeconfig is fatal rather than skippable. It used
# to be optional, which also silently disabled the cordon/drain in
# redeploy_node.sh - a repave would then destroy an undrained node.
if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
    echo "[ERROR] Kubeconfig not found at ${KUBECONFIG_FILE}."
    echo "        Without it this script cannot verify node readiness between nodes,"
    echo "        and redeploy_node.sh would skip cordon/drain entirely."
    echo "        Run: bash scripts/get_kubeconfig.sh ${ENV}"
    exit 1
fi

export KUBECONFIG="${KUBECONFIG_FILE}"

if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "[ERROR] Ansible inventory not found at ${INVENTORY_FILE}."
    exit 1
fi

echo "[INFO] Checking existing cluster health..."
if ! PREFLIGHT_NODES=$(kubectl get nodes --no-headers 2>&1); then
    echo "[ERROR] Cannot reach the cluster with ${KUBECONFIG_FILE}:"
    echo "        ${PREFLIGHT_NODES}"
    exit 1
fi

PREFLIGHT_NOT_READY=$(echo "${PREFLIGHT_NODES}" | awk '$2 !~ /^Ready/ {print $1}')
if [[ -n "${PREFLIGHT_NOT_READY}" ]]; then
    echo "[ERROR] Refusing to start: these nodes are not Ready:"
    echo "${PREFLIGHT_NOT_READY}" | sed 's/^/          /'
    exit 1
fi

echo "[INFO] Ready nodes detected: $(echo "${PREFLIGHT_NODES}" | wc -l)"

echo "[INFO] Verifying and discovering live DHCP IP addresses from Proxmox..."
bash "${REPO_ROOT}/scripts/discover_node_ips.sh" "${ENV}"

WORKER_NODES=$(grep -A 100 "k3s_workers:" "${INVENTORY_FILE}" | grep -E "^\s+k3s-wk-[a-z0-9-]+:" | sed "s/://;s/^[ \t]*//" || echo "")
CP_NODES=$(grep -A 30 "k3s_control_plane:" "${INVENTORY_FILE}" | grep -E "^\s+k3s-cp-[a-z0-9-]+:" | sed "s/://;s/^[ \t]*//" || echo "")

PRIMARY_CP=$(echo "${CP_NODES}" | head -n 1)
SECONDARY_CPS=$(echo "${CP_NODES}" | tail -n +2)

EXPECTED_CP_COUNT=$(echo "${CP_NODES}" | grep -c . || true)

# Block until the node that was just upgraded is back and the cluster is whole
# again. In --mode in-place this duplicates the checks already in
# rolling_update.yaml (harmless); in --mode repave it is the only such check,
# because redeploy_node.sh returns as soon as Ansible finishes and does not
# wait for the node to register. Without this, upgrading three control planes
# sequentially can tear down the next etcd member while the previous one is
# still rejoining, which loses quorum and the cluster with it.
wait_for_cluster_health() {
    local node="$1"
    local attempt node_ready not_ready surviving_cp etcd_out members_healthy

    echo "[GATE] Waiting for ${node} to report Ready (up to $((NODE_READY_RETRIES * GATE_DELAY))s)..."
    for ((attempt = 1; attempt <= NODE_READY_RETRIES; attempt++)); do
        node_ready=$(kubectl get node "${node}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "${node_ready}" == "True" ]]; then
            echo "[GATE] ${node} is Ready."
            break
        fi
        if (( attempt == NODE_READY_RETRIES )); then
            echo "[ERROR] ${node} did not become Ready in time."
            echo "        Halting before the next node - continuing would degrade the cluster further."
            exit 1
        fi
        sleep "${GATE_DELAY}"
    done

    # A node other than the one we touched going NotReady means this upgrade is
    # doing collateral damage; stop rather than repave into a shrinking cluster.
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print $1}' || true)
    if [[ -n "${not_ready}" ]]; then
        echo "[ERROR] Other nodes are NotReady after upgrading ${node}:"
        echo "${not_ready}" | sed 's/^/          /'
        exit 1
    fi

    if [[ "${node}" =~ ^k3s-cp- ]]; then
        surviving_cp=$(echo "${CP_NODES}" | grep -v "^${node}$" | head -n 1)
        echo "[GATE] Verifying etcd quorum from ${surviving_cp} (expecting ${EXPECTED_CP_COUNT} healthy members)..."
        for ((attempt = 1; attempt <= ETCD_HEALTH_RETRIES; attempt++)); do
            # --cluster reports every known member, so counting healthy lines
            # verifies the repaved node was actually re-added as a member. A
            # plain `endpoint health` only checks the local one and would pass
            # at 2-of-3 while the third never rejoined.
            etcd_out=$(cd "${REPO_ROOT}/ansible" && ansible -i "${INVENTORY_FILE}" "${surviving_cp}" \
                --become -m ansible.builtin.command \
                -a "/usr/local/bin/k3s etcdctl endpoint health --cluster" 2>&1 || true)
            members_healthy=$(echo "${etcd_out}" | grep -c "is healthy" || true)
            if (( members_healthy >= EXPECTED_CP_COUNT )); then
                echo "[GATE] etcd quorum healthy (${members_healthy}/${EXPECTED_CP_COUNT} members)."
                break
            fi
            if (( attempt == ETCD_HEALTH_RETRIES )); then
                echo "[ERROR] etcd did not return to ${EXPECTED_CP_COUNT} healthy members"
                echo "        (last seen: ${members_healthy}). Halting before the next control plane."
                echo "${etcd_out}" | sed 's/^/          /'
                exit 1
            fi
            sleep "${GATE_DELAY}"
        done
    fi

    echo "[GATE] ${node} settled. Pausing briefly before the next node..."
    sleep 15
}

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

    wait_for_cluster_health "${node}"
}

nodes_for_phase() {
    case "$1" in
        "Worker") echo "${WORKER_NODES}" ;;
        "Secondary Control Plane") echo "${SECONDARY_CPS}" ;;
        "Primary Control Plane") echo "${PRIMARY_CP}" ;;
    esac
}

# in-place is how a new k3s_version reaches the cluster, and Kubernetes' version
# skew policy lets a kubelet run older than the apiserver but never newer - so
# servers have to be upgraded before agents. Repave installs the same pinned
# k3s_version on every node, so no skew is possible there and the original order
# stands, which has the advantage of exercising the least critical nodes before
# anything touches etcd.
if [[ "${MODE}" == "in-place" ]]; then
    PHASE_ORDER=("Primary Control Plane" "Secondary Control Plane" "Worker")
else
    PHASE_ORDER=("Worker" "Secondary Control Plane" "Primary Control Plane")
fi

echo "[INFO] Phase order for ${MODE}: ${PHASE_ORDER[0]} -> ${PHASE_ORDER[1]} -> ${PHASE_ORDER[2]}"

PHASE_NUM=1
for phase in "${PHASE_ORDER[@]}"; do
    echo "================================================================================"
    echo "[PHASE ${PHASE_NUM}/${#PHASE_ORDER[@]}] Sequentially upgrading: ${phase}"
    echo "================================================================================"
    for node in $(nodes_for_phase "${phase}"); do
        upgrade_node "${node}" "${phase}"
    done
    PHASE_NUM=$((PHASE_NUM + 1))
done

kubectl get nodes -o wide --show-labels || true

echo "================================================================================"
echo "[SUCCESS] Sequential Rolling Upgrade completed successfully!"
echo "================================================================================"
