#!/usr/bin/env bash
# ==============================================================================
# Automated HashiCorp Vault Seeding Script
# Usage:
#   bash scripts/vault_seed.sh [stage|prod] [--force]
# ==============================================================================

set -euo pipefail

ENV="stage"
FORCE=false

for arg in "$@"; do
    case "${arg}" in
        stage|prod)
            ENV="${arg}"
            ;;
        --force|-f)
            FORCE=true
            echo "[WARN] FORCE mode enabled: existing secrets will be overwritten."
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env.vault" ]]; then
    source "${REPO_ROOT}/.env.vault"
elif [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

VAULT_ADDR="${VAULT_ADDR:-https://192.168.0.40:8200}"
export VAULT_ADDR
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
export VAULT_TOKEN="${VAULT_TOKEN:-}"

DEFAULT_VIP="192.168.0.41"
DEFAULT_HOST="k3s-stage.jnet.lan"
if [[ "${ENV}" == "prod" ]]; then
    DEFAULT_VIP="192.168.0.42"
    DEFAULT_HOST="k3s-prod.jnet.lan"
fi

PVE_HOST_1_ENDPOINT="${PVE_HOST_1_ENDPOINT:-${PVE_HOST1_ENDPOINT:-https://colossus.jnet.lan:8006/}}"
PVE_HOST_1_API_TOKEN="${PVE_HOST_1_API_TOKEN:-${PVE_HOST1_API_TOKEN:-}}"
PVE_HOST_1_NODE_NAME="${PVE_HOST_1_NODE_NAME:-${PVE_HOST1_NODE_NAME:-colossus}}"

PVE_HOST_2_ENDPOINT="${PVE_HOST_2_ENDPOINT:-${PVE_HOST2_ENDPOINT:-${PVE_ENDPOINT:-https://guardian.jnet.lan:8006/}}}"
PVE_HOST_2_API_TOKEN="${PVE_HOST_2_API_TOKEN:-${PVE_HOST2_API_TOKEN:-${PVE_API_TOKEN:-}}}"
PVE_HOST_2_NODE_NAME="${PVE_HOST_2_NODE_NAME:-${PVE_HOST2_NODE_NAME:-guardian}}"

SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/k3s_${ENV}_deploy_key}"
POLICY_NAME="k3s-${ENV}-bootstrap"

echo "================================================================================"
echo "[INFO] HashiCorp Vault Seeding (Environment: ${ENV})"
echo "       Vault Address: ${VAULT_ADDR}"
echo "================================================================================"

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    echo "[STEP 1] Generating SSH key: ${SSH_KEY_PATH}..."
    mkdir -p "$(dirname "${SSH_KEY_PATH}")"
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -N "" -C "gitlab-runner-k3s-${ENV}@gitbox.jnet.lan"
else
    echo "[STEP 1] Found existing SSH deployment key: ${SSH_KEY_PATH}"
fi

SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
SSH_PRIV_KEY=$(cat "${SSH_KEY_PATH}")

if [[ -z "${VAULT_TOKEN}" ]]; then
    if vault token lookup >/dev/null 2>&1; then
        VAULT_TOKEN=$(vault print token 2>/dev/null || echo '')
    fi
fi

if [[ -z "${VAULT_TOKEN}" ]]; then
    echo "[ERROR] VAULT_TOKEN is not set."
    exit 1
fi
export VAULT_TOKEN

vault_write_secret() {
    local subpath="$1"
    local raw_json="$2"
    local payload_v2
    payload_v2=$(jq -n --argjson d "${raw_json}" '{"data": $d}')
    curl -k -s -o /dev/null \
        --request POST \
        --header "X-Vault-Token: ${VAULT_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "${payload_v2}" \
        "${VAULT_ADDR}/v1/secret/data/${subpath}"
}

echo "[INFO] Seeding secrets for k3s-${ENV}..."
K3S_TOKEN="k3s-$(openssl rand -hex 24)"
BOOTSTRAP_PAYLOAD=$(jq -n \
    --arg tok "${K3S_TOKEN}" \
    --arg ccidr "10.42.0.0/16" \
    --arg scidr "10.43.0.0/16" \
    --arg flan "host-gw" \
    --arg prox "ipvs" \
    --arg kvip "${DEFAULT_VIP}" \
    --arg khost "${DEFAULT_HOST}" \
    '{token: $tok, cluster_cidr: $ccidr, service_cidr: $scidr, flannel_backend: $flan, kube_proxy_mode: $prox, kube_vip_address: $kvip, kube_vip_hostname: $khost}')

vault_write_secret "k3s-${ENV}/bootstrap" "${BOOTSTRAP_PAYLOAD}"

CREDS_PAYLOAD=$(jq -n \
    --arg h1_ep "${PVE_HOST_1_ENDPOINT}" \
    --arg h1_tok "${PVE_HOST_1_API_TOKEN}" \
    --arg h1_node "${PVE_HOST_1_NODE_NAME}" \
    --arg h2_ep "${PVE_HOST_2_ENDPOINT}" \
    --arg h2_tok "${PVE_HOST_2_API_TOKEN}" \
    --arg h2_node "${PVE_HOST_2_NODE_NAME}" \
    --arg target_ep "$([ "${ENV}" == "prod" ] && echo "${PVE_HOST_1_ENDPOINT}" || echo "${PVE_HOST_2_ENDPOINT}")" \
    --arg target_tok "$([ "${ENV}" == "prod" ] && echo "${PVE_HOST_1_API_TOKEN}" || echo "${PVE_HOST_2_API_TOKEN}")" \
    --arg target_node "$([ "${ENV}" == "prod" ] && echo "${PVE_HOST_1_NODE_NAME}" || echo "${PVE_HOST_2_NODE_NAME}")" \
    --arg pub "${SSH_PUB_KEY}" \
    --arg priv "${SSH_PRIV_KEY}" \
    '{
        pve_host_1_endpoint: $h1_ep,
        pve_host_1_api_token: $h1_tok,
        pve_host_1_node_name: $h1_node,
        pve_host_2_endpoint: $h2_ep,
        pve_host_2_api_token: $h2_tok,
        pve_host_2_node_name: $h2_node,
        pve_endpoint: $target_ep,
        pve_api_token: $target_tok,
        pve_node_name: $target_node,
        ssh_public_key: $pub,
        ssh_private_key: $priv
    }')

vault_write_secret "k3s-${ENV}/credentials" "${CREDS_PAYLOAD}"
echo "[OK] Vault seeded successfully for k3s-${ENV}"
