terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.66.3"
      # guardian and colossus are standalone Proxmox hosts, each with its own
      # API endpoint, so placing workers on a different host than the control
      # planes needs its own provider configuration.
      configuration_aliases = [proxmox.workers]
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
}
