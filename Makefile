# ==============================================================================
# infra-k3s-bootstrap Multi-Environment Automation Makefile
# ==============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ENV ?= stage
TF_DIR := environments/$(ENV)/terraform
ANSIBLE_DIR := environments/$(ENV)/ansible

.PHONY: help seed seed-force kubeconfig plan apply configure verify rolling-upgrade repave

help: ## Show this help menu
	@echo "infra-k3s-bootstrap Multi-Environment Automation Commands (ENV=$(ENV)):"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

seed: ## Seed HashiCorp Vault secrets for target environment (e.g. make seed ENV=stage)
	@bash scripts/vault_seed.sh $(ENV)

seed-force: ## Force regenerate and overwrite HashiCorp Vault secrets (e.g. make seed-force ENV=stage)
	@bash scripts/vault_seed.sh $(ENV) --force

kubeconfig: ## Fetch cluster kubeconfig from Vault or primary node
	@bash scripts/get_kubeconfig.sh $(ENV)

plan: ## Run Terraform plan for target environment (e.g. make plan ENV=stage)
	@cd $(TF_DIR) && terraform init -backend=false && terraform plan

apply: ## Provision K3s VMs on Proxmox VE for target environment (e.g. make apply ENV=stage)
	@cd $(TF_DIR) && terraform apply -auto-approve

configure: ## Run Ansible OS hardening & K3s deployment for target environment (e.g. make configure ENV=stage)
	@cd ansible && ansible-playbook -i ../$(ANSIBLE_DIR)/hosts.yaml playbooks/site.yaml

verify: ## Check cluster node readiness for target environment (e.g. make verify ENV=stage)
	@export KUBECONFIG="$$(pwd)/credentials/$(ENV)/kubeconfig.yaml"; kubectl get nodes -o wide

rolling-upgrade: ## Trigger sequential rolling upgrade (e.g. make rolling-upgrade ENV=stage)
	@bash scripts/rolling_upgrade.sh --mode in-place --env $(ENV)

repave: ## Trigger rolling VM repave (e.g. make repave ENV=stage)
	@bash scripts/rolling_upgrade.sh --mode repave --env $(ENV)
