#!/usr/bin/env bash
# ==============================================================================
# Per-App Vault Secrets Seeding Script
#
# Provisions everything a single in-cluster app needs to pull secrets from
# Vault via External Secrets Operator's Kubernetes-auth SecretStore:
#   - a read-only ACL policy scoped to secret/data/k3s-<env>/<app>
#   - a Kubernetes-auth role binding one ServiceAccount to that policy
#   - the KV v2 secret itself (merged in, not clobbered, unless --force)
#
# Requires the "kubernetes" auth method to already be enabled and configured
# against the target cluster (a one-time, per-cluster operation -- see
# docs/vault-integration.md). This script only manages the per-app layer on
# top of that.
#
# Usage:
#   bash scripts/vault_seed_apps.sh <env> <app> <namespace> <service_account> [options]
#
# Positional args:
#   env              stage|prod
#   app              Vault path/policy segment, e.g. "monitoring"
#                     -> secret/data/k3s-<env>/<app>
#   namespace        Kubernetes namespace the ServiceAccount lives in
#   service_account  Kubernetes ServiceAccount name to bind in the Vault role
#
# Options:
#   --secret KEY=VALUE   Add/update one field in the app's KV secret (repeatable)
#   --ttl DURATION       Vault k8s-auth role token TTL (default: 1h)
#   --force              Overwrite the whole KV secret instead of merging new
#                        --secret fields on top of what's already there
#   -h, --help           Show this help
#
# Example (equivalent of the manual monitoring/grafana setup):
#   bash scripts/vault_seed_apps.sh stage monitoring monitoring grafana-vault-auth \
#     --secret grafana_admin_user=admin \
#     --secret grafana_admin_password="$(openssl rand -base64 24)"
# ==============================================================================

set -euo pipefail

usage() {
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[[ $# -eq 0 ]] && usage 1

ENV=""
APP=""
NAMESPACE=""
SERVICE_ACCOUNT=""
TTL="1h"
FORCE=false
declare -a SECRET_KV=()

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage 0
            ;;
        --secret)
            SECRET_KV+=("$2")
            shift 2
            ;;
        --ttl)
            TTL="$2"
            shift 2
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

ENV="${POSITIONAL[0]:-}"
APP="${POSITIONAL[1]:-}"
NAMESPACE="${POSITIONAL[2]:-}"
SERVICE_ACCOUNT="${POSITIONAL[3]:-}"

if [[ "${ENV}" != "stage" && "${ENV}" != "prod" ]]; then
    echo "[ERROR] env must be 'stage' or 'prod' (got: '${ENV}')"
    usage 1
fi
if [[ -z "${APP}" || -z "${NAMESPACE}" || -z "${SERVICE_ACCOUNT}" ]]; then
    echo "[ERROR] app, namespace, and service_account are all required."
    usage 1
fi

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

if [[ -z "${VAULT_TOKEN:-}" ]]; then
    if vault token lookup >/dev/null 2>&1; then
        VAULT_TOKEN=$(vault print token 2>/dev/null || echo '')
    fi
fi
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    echo "[ERROR] VAULT_TOKEN is not set."
    exit 1
fi
export VAULT_TOKEN

POLICY_NAME="k3s-${ENV}-${APP}-read"
ROLE_NAME="k3s-${ENV}-${APP}"
SECRET_PATH="k3s-${ENV}/${APP}"

echo "================================================================================"
echo "[INFO] Vault App Secrets Seeding"
echo "       Vault Address:    ${VAULT_ADDR}"
echo "       Environment:      ${ENV}"
echo "       App:              ${APP}"
echo "       Namespace:        ${NAMESPACE}"
echo "       ServiceAccount:   ${SERVICE_ACCOUNT}"
echo "       Policy:           ${POLICY_NAME}"
echo "       Role:             auth/kubernetes/role/${ROLE_NAME}"
echo "       Secret Path:      secret/data/${SECRET_PATH}"
echo "================================================================================"

# ------------------------------------------------------------------------------
# Preconditions: kubernetes auth method must already be enabled & configured.
# This script only manages per-app policy/role/secret, not the auth backend
# itself -- that's a one-time, per-cluster operation.
# ------------------------------------------------------------------------------
AUTH_MOUNTS=$(curl -k -s --header "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth")
if ! echo "${AUTH_MOUNTS}" | jq -e '.["kubernetes/"]' >/dev/null 2>&1; then
    echo "[ERROR] The 'kubernetes' auth method is not enabled on this Vault."
    echo "        Run the one-time cluster registration step first (vault auth"
    echo "        enable kubernetes + vault write auth/kubernetes/config ...)."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Read-only ACL policy, scoped to exactly this app's secret path
# ------------------------------------------------------------------------------
echo "[STEP 1] Writing policy '${POLICY_NAME}'..."
POLICY_HCL=$(cat <<EOF
path "secret/data/${SECRET_PATH}" {
  capabilities = ["read"]
}
path "secret/metadata/${SECRET_PATH}" {
  capabilities = ["read"]
}
EOF
)
POLICY_PAYLOAD=$(jq -n --arg policy "${POLICY_HCL}" '{policy: $policy}')
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
    --request PUT \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${POLICY_PAYLOAD}" \
    "${VAULT_ADDR}/v1/sys/policies/acl/${POLICY_NAME}")
if [[ "${HTTP_CODE}" != "204" && "${HTTP_CODE}" != "200" ]]; then
    echo "[ERROR] Failed to write policy '${POLICY_NAME}' (HTTP ${HTTP_CODE})"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Kubernetes-auth role binding the app's ServiceAccount to that policy
# ------------------------------------------------------------------------------
echo "[STEP 2] Writing role 'auth/kubernetes/role/${ROLE_NAME}'..."
ROLE_PAYLOAD=$(jq -n \
    --arg sa "${SERVICE_ACCOUNT}" \
    --arg ns "${NAMESPACE}" \
    --arg policy "${POLICY_NAME}" \
    --arg ttl "${TTL}" \
    '{
        bound_service_account_names: [$sa],
        bound_service_account_namespaces: [$ns],
        policies: [$policy],
        ttl: $ttl
    }')
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
    --request POST \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${ROLE_PAYLOAD}" \
    "${VAULT_ADDR}/v1/auth/kubernetes/role/${ROLE_NAME}")
if [[ "${HTTP_CODE}" != "204" && "${HTTP_CODE}" != "200" ]]; then
    echo "[ERROR] Failed to write role '${ROLE_NAME}' (HTTP ${HTTP_CODE})"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. KV v2 secret -- merge new --secret fields on top of whatever's already
#    there, unless --force is given. Running this twice with the same
#    --secret args (or none at all) is a no-op against existing data.
# ------------------------------------------------------------------------------
if [[ "${#SECRET_KV[@]}" -eq 0 && "${FORCE}" != "true" ]]; then
    echo "[STEP 3] No --secret fields given; leaving existing KV data at '${SECRET_PATH}' untouched."
else
    echo "[STEP 3] Writing secret 'secret/data/${SECRET_PATH}'..."

    EXISTING_DATA="{}"
    if [[ "${FORCE}" != "true" ]]; then
        EXISTING_DATA=$(curl -k -s --header "X-Vault-Token: ${VAULT_TOKEN}" \
            "${VAULT_ADDR}/v1/secret/data/${SECRET_PATH}" \
            | jq -c '.data.data // {}' 2>/dev/null || echo "{}")
    fi

    MERGED_DATA="${EXISTING_DATA}"
    for kv in "${SECRET_KV[@]+"${SECRET_KV[@]}"}"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        if [[ "${key}" == "${kv}" ]]; then
            echo "[ERROR] --secret must be in KEY=VALUE form (got: '${kv}')"
            exit 1
        fi
        MERGED_DATA=$(echo "${MERGED_DATA}" | jq --arg k "${key}" --arg v "${value}" '.[$k] = $v')
    done

    if [[ "${MERGED_DATA}" == "{}" ]]; then
        echo "[WARN] Nothing to write: no existing data and no --secret fields given with --force."
    else
        SECRET_PAYLOAD=$(jq -n --argjson d "${MERGED_DATA}" '{data: $d}')
        HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
            --request POST \
            --header "X-Vault-Token: ${VAULT_TOKEN}" \
            --header "Content-Type: application/json" \
            --data "${SECRET_PAYLOAD}" \
            "${VAULT_ADDR}/v1/secret/data/${SECRET_PATH}")
        if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "204" ]]; then
            echo "[ERROR] Failed to write secret '${SECRET_PATH}' (HTTP ${HTTP_CODE})"
            exit 1
        fi
    fi
fi

echo "================================================================================"
echo "[OK] Vault app secrets seeded for '${APP}' (${ENV})."
echo
echo "Corresponding SecretStore in infra-k3s-gitops should reference:"
echo "  role: ${ROLE_NAME}"
echo "  serviceAccountRef.name: ${SERVICE_ACCOUNT}  (in namespace: ${NAMESPACE})"
echo "  remoteRef.key: ${SECRET_PATH}"
echo "================================================================================"
