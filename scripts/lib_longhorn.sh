#!/usr/bin/env bash
# ==============================================================================
# Shared Longhorn readiness helper.
# Sourced by scripts/rolling_upgrade.sh and scripts/redeploy_node.sh so both
# node-replacement paths use one implementation instead of two that drift.
# Requires kubectl on PATH, with KUBECONFIG already pointing at the cluster.
# ==============================================================================

# Replica rebuilds are bounded by data size and network, not by how long a node
# takes to restart, so this gets its own much larger budget.
LONGHORN_REBUILD_RETRIES="${LONGHORN_REBUILD_RETRIES:-180}"
# Honour GATE_DELAY when the caller sets one, but do not depend on it -
# redeploy_node.sh has no such knob.
LONGHORN_POLL_DELAY="${LONGHORN_POLL_DELAY:-${GATE_DELAY:-10}}"

# Longhorn keeps rebuilding replicas long after a node reports Ready, and in
# repave mode the node's data disk is destroyed outright, so the rebuild starts
# from nothing. Releasing the next node before that finishes is how a 3-replica
# volume ends up with none. Verified against Longhorn on this cluster: group
# longhorn.io, storage version v1beta2, .status.state == "attached",
# .status.robustness == "healthy" (all lowercase).
wait_for_longhorn_health() {
    local attempt vol_rows degraded

    # No Longhorn on this cluster - nothing to wait for.
    if ! kubectl get crd volumes.longhorn.io >/dev/null 2>&1; then
        return 0
    fi

    echo "[GATE] Waiting for Longhorn volumes to be healthy (up to $((LONGHORN_REBUILD_RETRIES * LONGHORN_POLL_DELAY))s)..."
    for ((attempt = 1; attempt <= LONGHORN_REBUILD_RETRIES; attempt++)); do
        # Only attached volumes carry a meaningful robustness. A detached volume
        # reports "unknown", which is not degraded - treating it as unhealthy
        # would block forever on volumes nothing is using.
        if vol_rows=$(kubectl -n longhorn-system get volumes.longhorn.io \
                -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.state}{" "}{.status.robustness}{"\n"}{end}' 2>&1); then
            degraded=$(echo "${vol_rows}" | awk 'NF && $2 == "attached" && $3 != "healthy" {print "          " $1 "  state=" $2 "  robustness=" $3}')
        else
            # A failed query must not read as "nothing degraded" - that is the
            # silent-pass failure mode this whole gate exists to avoid.
            degraded="          volume query failed: ${vol_rows}"
        fi

        if [[ -z "${degraded}" ]]; then
            echo "[GATE] All attached Longhorn volumes are healthy."
            return 0
        fi

        if (( attempt == LONGHORN_REBUILD_RETRIES )); then
            echo "[ERROR] Longhorn volumes did not return to healthy in time:"
            echo "${degraded}"
            echo "        Halting rather than releasing the next node while replicas"
            echo "        are still rebuilding."
            exit 1
        fi

        # Show progress rather than sitting silent for half an hour.
        if (( attempt == 1 || attempt % 6 == 0 )); then
            echo "[GATE] Still waiting on Longhorn:"
            echo "${degraded}"
        fi
        sleep "${LONGHORN_POLL_DELAY}"
    done
}

