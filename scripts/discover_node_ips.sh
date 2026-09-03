#!/usr/bin/env bash
# ==============================================================================
# Dynamic DHCP IP Discovery & Inventory Resolution
# ==============================================================================
set -euo pipefail

ENV="${1:-${ENV:-stage}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${REPO_ROOT}/environments/${ENV}/ansible/hosts.yaml"

if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "[WARN] Inventory file not found at ${INVENTORY_FILE}. Skipping discovery."
    exit 0
fi

python3 "${SCRIPT_DIR}/discover_node_ips.py" --env "${ENV}"
