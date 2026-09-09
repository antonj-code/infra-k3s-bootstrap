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

# POSIX character classes only. This runs in alpine/ansible, whose BusyBox grep
# has no GNU \s - the pattern parsed as a literal "s", matched nothing, and the
# empty node lists turned every phase loop into a no-op that still exited 0.
# Node names are prefix-distinguished (k3s-wk- / k3s-cp-), so scanning the whole
# inventory is also simpler and safer than the fixed `grep -A <n>` windows used
# before, which silently truncated once a section outgrew the window.
WORKER_NODES=$(grep -E "^[[:space:]]+k3s-wk-[a-z0-9-]+:" "${INVENTORY_FILE}" | sed "s/[[:space:]]//g;s/://" || true)
CP_NODES=$(grep -E "^[[:space:]]+k3s-cp-[a-z0-9-]+:" "${INVENTORY_FILE}" | sed "s/[[:space:]]//g;s/://" || true)

WORKER_COUNT=$(echo "${WORKER_NODES}" | grep -c . || true)
CP_COUNT=$(echo "${CP_NODES}" | grep -c . || true)
PARSED_TOTAL=$((WORKER_COUNT + CP_COUNT))
READY_TOTAL=$(echo "${PREFLIGHT_NODES}" | grep -c . || true)

echo "[INFO] Parsed ${CP_COUNT} control plane and ${WORKER_COUNT} worker nodes from the inventory."

# A run that upgrades nothing must not report success. Both an unparseable
# inventory and one left over from a previous cluster land here.
if [[ "${WORKER_COUNT}" -eq 0 || "${CP_COUNT}" -eq 0 ]]; then
    echo "[ERROR] Parsed no usable node names from ${INVENTORY_FILE}"
    echo "        (control planes: ${CP_COUNT}, workers: ${WORKER_COUNT})."
    echo "        Refusing to continue: an empty node list would make this run a"
    echo "        silent no-op that still exits 0."
    exit 1
fi

# Compare the actual names, not just the counts: a stale inventory left over
# from a destroyed cluster has the right number of entries and none of the
# right names, and counting alone would wave it through.
INVENTORY_SORTED=$(printf '%s\n%s\n' "${CP_NODES}" "${WORKER_NODES}" | grep . | sort)
LIVE_SORTED=$(echo "${PREFLIGHT_NODES}" | awk '{print $1}' | sort)

if [[ "${INVENTORY_SORTED}" != "${LIVE_SORTED}" ]]; then
    echo "[ERROR] The inventory does not match the live cluster."
    echo "        Inventory: ${INVENTORY_FILE} (${PARSED_TOTAL} nodes)"
    echo "${INVENTORY_SORTED}" | sed 's/^/          inv:  /'
    echo "        Cluster (${READY_TOTAL} nodes):"
    echo "${LIVE_SORTED}" | sed 's/^/          live: /'
    echo "        Upgrading from this would target nodes that do not exist."
    echo "        Regenerate it with: terraform apply -target=module.k3s_nodes.local_file.ansible_inventory"
    exit 1
fi

PRIMARY_CP=$(echo "${CP_NODES}" | head -n 1)
SECONDARY_CPS=$(echo "${CP_NODES}" | tail -n +2)

EXPECTED_CP_COUNT=$(echo "${CP_NODES}" | grep -c . || true)

# The version this run is supposed to land, read from the same group_vars the
# Ansible roles use. Used to prove each node actually moved.
TARGET_K3S_VERSION=$(sed -n 's/^k3s_version:[[:space:]]*"\(.*\)".*/\1/p' \
    "${REPO_ROOT}/environments/${ENV}/ansible/group_vars/all.yaml" | head -n 1 || true)
if [[ -z "${TARGET_K3S_VERSION}" ]]; then
    echo "[ERROR] Could not read k3s_version from environments/${ENV}/ansible/group_vars/all.yaml."
    exit 1
fi
echo "[INFO] Target k3s version for this run: ${TARGET_K3S_VERSION}"

# Block until the node that was just upgraded is back and the cluster is whole
# again. In --mode in-place this duplicates the checks already in
# rolling_update.yaml (harmless); in --mode repave it is the only such check,
# because redeploy_node.sh returns as soon as Ansible finishes and does not
# wait for the node to register. Without this, upgrading three control planes
# sequentially can tear down the next etcd member while the previous one is
# still rejoining, which loses quorum and the cluster with it.
wait_for_cluster_health() {
    local node="$1"
    local attempt node_ready node_version not_ready etcd_health etcd_members

    # Ready and "running the version we asked for" are checked together, in one
    # retry loop. Checking the version once after the Ready loop raced the node's
    # re-registration: right after k3s restarts, the Node object can report Ready
    # before .status.nodeInfo is repopulated, so a single read came back empty and
    # failed a node that had in fact upgraded correctly. stderr is captured rather
    # than discarded so a genuine failure reports what kubectl actually said.
    echo "[GATE] Waiting for ${node} to be Ready on ${TARGET_K3S_VERSION} (up to $((NODE_READY_RETRIES * GATE_DELAY))s)..."
    for ((attempt = 1; attempt <= NODE_READY_RETRIES; attempt++)); do
        node_status=$(kubectl get node "${node}" -o jsonpath=\
'{.status.conditions[?(@.type=="Ready")].status} {.status.nodeInfo.kubeletVersion}' 2>&1 || true)
        node_ready="${node_status%% *}"
        node_version="${node_status##* }"
        if [[ "${node_ready}" == "True" && "${node_version}" == "${TARGET_K3S_VERSION}" ]]; then
            echo "[GATE] ${node} is Ready and running ${node_version}."
            break
        fi
        if (( attempt == NODE_READY_RETRIES )); then
            echo "[ERROR] ${node} did not reach Ready on ${TARGET_K3S_VERSION} in time."
            echo "        last read: ${node_status:-<no output>}"
            echo "        Halting rather than continuing and reporting a success that"
            echo "        may have upgraded nothing."
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
        echo "[GATE] Verifying etcd health and membership (expecting ${EXPECTED_CP_COUNT} members)..."
        for ((attempt = 1; attempt <= ETCD_HEALTH_RETRIES; attempt++)); do
            # k3s ships no etcdctl and has no `k3s etcdctl` subcommand, so use the
            # apiserver's own etcd probe. That only reports whether THIS apiserver
            # can reach a quorate etcd, so pair it with a count of the nodes k3s
            # labels as etcd members - that is what confirms the node just
            # upgraded actually rejoined, rather than the cluster limping on
            # without it.
            etcd_health=$(kubectl get --raw='/readyz/etcd' 2>/dev/null || true)
            etcd_members=$(kubectl get nodes -l node-role.kubernetes.io/etcd=true --no-headers 2>/dev/null | grep -c . || true)
            if [[ "${etcd_health}" == "ok" ]] && (( etcd_members >= EXPECTED_CP_COUNT )); then
                echo "[GATE] etcd healthy, ${etcd_members}/${EXPECTED_CP_COUNT} members present."
                break
            fi
            if (( attempt == ETCD_HEALTH_RETRIES )); then
                echo "[ERROR] etcd did not return to ${EXPECTED_CP_COUNT} healthy members."
                echo "        /readyz/etcd returned: ${etcd_health:-<unreachable>}"
                echo "        nodes labelled as etcd members: ${etcd_members}"
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
