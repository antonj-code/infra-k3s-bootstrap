# K3s Multi-Environment High Availability Architecture on Proxmox VE

This document outlines the architecture, hardware layout, networking topology, OS hardening, storage design, and secrets management for the multi-environment K3s Kubernetes infrastructure deployed on Proxmox VE hosts (`guardian` and `colossus`) via `infra-k3s-bootstrap`.

---

## 1. Physical & Virtual Topology

The infrastructure spans two dedicated Proxmox VE hypervisor hosts with strict environment isolation:
- **STAGE Deployment Target (`guardian.jnet.lan`)**: Dedicated hypervisor hosting all 6 virtual machines for the STAGE environment.
- **PROD Deployment Target (`colossus.jnet.lan`)**: Dedicated hypervisor hosting all 6 virtual machines for the PROD environment.

All virtual machines are provisioned from the hardened **AlmaLinux 9 CIS Level 2 Template (VM ID: `1001`, version: `1.1.0`)** with a dual-NIC architecture:
1. **Management Network (`net0`)**: Connected to `vmbr0` (`192.168.0.0/24`), dynamically assigned via Cloud-Init DHCP. Used for external API access, SSH administration, CI/CD runner access, and kube-vip Virtual IPs.
2. **Internal Cluster Network (`net1`)**: Connected to `vmbr0` with VLAN tagging (VLAN `20` for Stage, VLAN `30` for Prod). Static IP assignments are used for high-performance intra-cluster traffic (etcd quorum, kubelet, and Flannel CNI).

### Topology Diagram (Stage on `guardian` / Prod on `colossus`)

```
+---------------------------------------------------------------------------------------------------+
|  STAGE CLUSTER (Proxmox VE Host: guardian.jnet.lan)                                              |
|                                                                                                   |
|  Control Plane Nodes (HA Embedded etcd, N=3)           Worker Nodes (Workloads & Longhorn CSI)    |
|  • k3s-cp-s-XXXX (VM 3001, net1: 10.20.20.11)          • k3s-wk-s-AAAA (VM 3011, net1: 10.20.20.21)|
|  • k3s-cp-s-YYYY (VM 3002, net1: 10.20.20.12)          • k3s-wk-s-BBBB (VM 3012, net1: 10.20.20.22)|
|  • k3s-cp-s-ZZZZ (VM 3003, net1: 10.20.20.13)          • k3s-wk-s-CCCC (VM 3013, net1: 10.20.20.23)|
|                                                                                                   |
|  VIP: 192.168.0.43 (k3s-stage.jnet.lan) | net0: DHCP (192.168.0.0/24) | net1: VLAN 20 (10.20.20.0/24) |
+---------------------------------------------------------------------------------------------------+
|  PROD CLUSTER (Proxmox VE Host: colossus.jnet.lan)                                               |
|                                                                                                   |
|  Control Plane Nodes (HA Embedded etcd, N=3)           Worker Nodes (Workloads & Longhorn CSI, N=5)|
|  • k3s-cp-p-XXXX (VM 4001, net1: 10.30.30.11)          • k3s-wk-p-AAAA (VM 4011, net1: 10.30.30.21)|
|  • k3s-cp-p-YYYY (VM 4002, net1: 10.30.30.12)          • k3s-wk-p-BBBB (VM 4012, net1: 10.30.30.22)|
|  • k3s-cp-p-ZZZZ (VM 4003, net1: 10.30.30.13)          • k3s-wk-p-CCCC (VM 4013, net1: 10.30.30.23)|
|                                                        • k3s-wk-p-DDDD (VM 4014, net1: 10.30.30.24)|
|                                                        • k3s-wk-p-EEEE (VM 4015, net1: 10.30.30.25)|
|                                                                                                   |
|  VIP: 192.168.0.44 (k3s-prod.jnet.lan)  | net0: DHCP (192.168.0.0/24) | net1: VLAN 30 (10.30.30.0/24) |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. Resource Allocation Matrix

### STAGE Environment (Proxmox Host: `guardian`)

| Node Prefix | Role | VM ID Range | Management IP (`net0`) | Internal VLAN 20 IP (`net1`) | vCPU | RAM | Root Disk | Data Disk (`scsi1`) | Mount Point & FS | Proxmox Host |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`k3s-cp-s-<rand>`** | Control Plane (x3) | `3001 - 3003` | DHCP (`192.168.0.x`) | `10.20.20.11 - 13` | 2 | 4096 MB | 32 GB | 20 GB | `/var/lib/rancher/k3s/server/db` (XFS, etcd) | `guardian` |
| **`k3s-wk-s-<rand>`** | Worker / Storage (x3)| `3011 - 3013` | DHCP (`192.168.0.x`) | `10.20.20.21 - 23` | 4 | 4096 MB | 32 GB | 50 GB | `/mnt/storage-data01` (XFS, Longhorn) | `guardian` |

### PROD Environment (Proxmox Host: `colossus`)

| Node Prefix | Role | VM ID Range | Management IP (`net0`) | Internal VLAN 30 IP (`net1`) | vCPU | RAM | Root Disk | Data Disk (`scsi1`) | Mount Point & FS | Proxmox Host |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`k3s-cp-p-<rand>`** | Control Plane (x3) | `4001 - 4003` | DHCP (`192.168.0.x`) | `10.30.30.11 - 13` | 2 | 4096 MB | 32 GB | 20 GB | `/var/lib/rancher/k3s/server/db` (XFS, etcd) | `colossus` |
| **`k3s-wk-p-<rand>`** | Worker / Storage (x5)| `4011 - 4015` | DHCP (`192.168.0.x`) | `10.30.30.21 - 25` | 4 | 4096 MB | 32 GB | 50 GB | `/mnt/storage-data01` (XFS, Longhorn) | `colossus` |

---

## 3. High Availability, kube-vip & Inter-Node Communication

### 3.1. Embedded etcd Quorum ($N=3$)
- **Consensus Engine**: Embedded etcd quorum running across the 3 control plane nodes.
- **Fault Tolerance**: Quorum requires $\lfloor 3/2 \rfloor + 1 = 2$ healthy nodes. The cluster survives the loss of **1 control plane node** without downtime or degraded write availability.

### 3.2. kube-vip Control Plane Load Balancing
- **Stage Virtual IP (VIP)**: `192.168.0.43` (FQDN: `k3s-stage.jnet.lan`).
- **Prod Virtual IP (VIP)**: `192.168.0.44` (FQDN: `k3s-prod.jnet.lan`).
- **Operation**: Managed by **kube-vip** running as a static pod / DaemonSet with leader election across the control plane nodes.
- **Failover**: If the current leader control plane node fails, kube-vip automatically re-assigns the VIP to a surviving control plane node via Gratuitous ARP within seconds.
- **TLS Subject Alternative Names (SANs)**:
  - `--tls-san <VIP_ADDRESS>` (`192.168.0.43` or `192.168.0.44`)
  - `--tls-san <DOMAIN_NAME>` (`k3s-stage.jnet.lan` or `k3s-prod.jnet.lan`)
  - Dynamic DHCP management IPs and internal VLAN IPs.

### 3.3. Inter-Node Communication & DHCP Discovery
- **Management & Bootstrap Access**: VMs receive IPv4 addresses dynamically on `net0` via DHCP (`192.168.0.0/24`).
- **Automated IP Discovery**: During pipeline runs or local CLI workflows, `scripts/discover_node_ips.py` discovers each node's live DHCP IP via parallel TCP probe, SSH validation, and Proxmox QEMU guest agent API, updating `ansible_host` in `environments/<env>/ansible/hosts.yaml`.
- **Internal Cluster Traffic**: Node-to-node communications (K3s agent join, etcd consensus, CNI traffic) bind to the internal VLAN-tagged `net1` interface (`10.20.20.x` for stage, `10.30.30.x` for prod).

---

## 4. High-Performance Network & Storage Optimizations

### 4.1. Flannel `host-gw` CNI Mode
Because all cluster nodes in an environment communicate across the internal Layer 2 VLAN, K3s is configured with `flannel-backend: "host-gw"`:
- Direct kernel route tables replace VXLAN UDP encapsulation.
- Zero CPU and packet header overhead; provides wire-speed throughput.
- Full MTU 1500 (no VXLAN encapsulation overhead or fragmentation).

### 4.2. `kube-proxy` IPVS Mode
- Linux kernel IPVS hash tables ($O(1)$ complexity) instead of iptables linear chains ($O(N)$).
- Configured with `ipvs-strict-arp: true` for clean compatibility with **MetalLB** Layer 2 load balancing.

### 4.3. Dedicated Datastore Disk for Embedded etcd
- Control Plane nodes attach a dedicated secondary virtual disk (`scsi1` / `/dev/sdb`): 20GB in Stage, 30GB in Prod.
- Formatted with **XFS** (`xfsprogs`) and mounted to **`/var/lib/rancher/k3s/server/db`** with persistent `/etc/fstab` configuration (`defaults,noatime`).
- Decouples etcd Write-Ahead Logs (WAL) and snapshots from OS root disk I/O.

### 4.4. Dedicated Storage Disk for Longhorn CSI
- Worker nodes attach a dedicated secondary virtual disk (`scsi1` / `/dev/sdb`): 50GB in Stage, 100GB in Prod.
- Formatted with **XFS** (`xfsprogs`), mounted to **`/mnt/storage-data01`**, and configured for Longhorn CSI storage (`/mnt/storage-data01/longhorn`).
- System services `iscsid.service` and `nfs-utils` are pre-installed and enabled.

---

## 5. OS-Level Settings & CIS Hardening

All nodes cloned from the AlmaLinux 9 CIS Level 2 template receive:

1. **Swap Memory Disablement**:
   - `swapoff -a` executed immediately.
   - Swap partitions and mount points purged from `/etc/fstab`.
   - `vm.swappiness = 0` configured in sysctl.

2. **Kernel Modules Loaded (`/etc/modules-load.d/k3s-ipvs.conf`)**:
   - `overlay`, `br_netfilter` (Container runtime & bridge filtering)
   - `ip_vs`, `ip_vs_rr`, `ip_vs_wrr`, `ip_vs_sh`, `nf_conntrack` (IPVS proxy)

3. **Sysctl Parameters (`/etc/sysctl.d/99-kubernetes.conf`)**:
   - `net.bridge.bridge-nf-call-iptables = 1`
   - `net.bridge.bridge-nf-call-ip6tables = 1`
   - `net.ipv4.ip_forward = 1`
   - `net.ipv4.conf.all.forwarding = 1`
   - `net.ipv4.conf.default.forwarding = 1`
   - `net.ipv4.conf.all.log_martians = 0`
   - `net.ipv4.conf.default.log_martians = 0`
   - `net.ipv4.conf.all.rp_filter = 2` (loose reverse path filtering for asymmetric CNI/VIP routing)
   - `net.ipv4.conf.default.rp_filter = 2`
   - `net.ipv4.conf.all.arp_ignore = 1`
   - `net.ipv4.conf.all.arp_announce = 2`
   - `net.core.somaxconn = 4096`
   - `vm.max_map_count = 262144`
   - `fs.inotify.max_user_watches = 524288`
   - `fs.inotify.max_user_instances = 8192`

4. **Firewalld Hardening**:
   - Required ports opened (`6443/tcp`, `2379-2380/tcp`, `10250/tcp`, `30000-32767/tcp`).
   - Management LAN (`192.168.0.0/24`), Internal VLANs (`10.20.20.0/24` or `10.30.30.0/24`), Pod CIDR (`10.42.0.0/16`), and Service CIDR (`10.43.0.0/16`) assigned to `trusted` zone.
   - CNI interfaces (`cni0`, `flannel.1`) assigned to `trusted` zone.

---

## 6. Monitoring Integration, Node Labels & Inventory Groups

All nodes are labeled at the Kubernetes engine level and organized into Ansible groups:

### 6.1. Kubernetes Node Labels

#### Control Plane Nodes (`k3s-cp-s-<rand>` in Stage / `k3s-cp-p-<rand>` in Prod):
- `node-role.kubernetes.io/control-plane: "true"`
- `k3s.io/node-type: management`
- `monitoring.jnet.lan/enabled: "true"`
- `monitoring.jnet.lan/group: control-plane`
- `monitoring.jnet.lan/tier: infrastructure`
- `topology.kubernetes.io/region: homelab`
- `topology.kubernetes.io/zone: guardian` (Stage) / `colossus` (Prod)

#### Worker Nodes (`k3s-wk-s-<rand>` in Stage / `k3s-wk-p-<rand>` in Prod):
- `node-role.kubernetes.io/worker: "true"`
- `k3s.io/node-type: compute`
- `storage.k3s.io/longhorn: "true"`
- `node.longhorn.io/create-default-disk: config`
- `monitoring.jnet.lan/enabled: "true"`
- `monitoring.jnet.lan/group: worker`
- `monitoring.jnet.lan/tier: workload`
- `topology.kubernetes.io/region: homelab`
- `topology.kubernetes.io/zone: guardian` (Stage) / `colossus` (Prod)

### 6.2. Ansible Inventory Groups
- `k3s_cluster`: All 6 nodes in the environment.
- `k3s_control_plane`: 3x Control plane / management nodes.
- `k3s_workers`: 3x Worker / compute and storage nodes.
- `monitoring_nodes`: Meta-group combining all nodes for cluster-wide Prometheus / VictoriaMetrics metric scrapers and agent deployments.

---

## 7. Sequential Rolling Upgrades

When the base VM template (`template_version` / `template_vm_id`) is updated:
1. **Automation**: Triggered via `make repave ENV=stage` or `bash scripts/rolling_upgrade.sh --mode repave --env stage`.
2. **Execution Order**:
   - Worker nodes (`k3s-wk-s-*` / `k3s-wk-p-*`) upgraded sequentially (`serial: 1`).
   - Secondary control planes (`k3s-cp-s-*` / `k3s-cp-p-*`) upgraded sequentially (`serial: 1`).
   - Primary control plane (`k3s-cp-s-*` / `k3s-cp-p-*`) upgraded last (`serial: 1`).
3. **Safety Checks**: Pre-flight cluster health checks, node cordon/drain, VM replacement, OS re-hardening, K3s rejoin, and etcd quorum health verification before advancing to subsequent nodes.

---

## 8. Secrets Management Architecture (HashiCorp Vault)

All sensitive cluster data, tokens, and credentials are maintained securely in HashiCorp Vault:

- **Vault Load Balancer Endpoint**: `https://192.168.0.40:8200`
- **TLS Configuration**: Self-signed SSL certificate (`VAULT_SKIP_VERIFY="true"`, `validate_certs: false`)
- **Key-Value Store**: KV v2 engine mounted at `secret/`
  - `secret/data/k3s-stage/bootstrap` & `secret/data/k3s-prod/bootstrap`: K3s cluster join tokens and network topology parameters.
  - `secret/data/k3s-stage/credentials` & `secret/data/k3s-prod/credentials`: Proxmox API tokens and environment-specific SSH deployment keypairs.
  - `secret/data/k3s-stage/cluster` & `secret/data/k3s-prod/cluster`: Sanitized `kubeconfig` automatically uploaded by Ansible upon primary node provisioning.


