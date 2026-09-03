terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.66.3"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.5.2"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.0.6"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }

  # Configured for GitLab Managed Terraform State (Prod)
  backend "http" {}
}
