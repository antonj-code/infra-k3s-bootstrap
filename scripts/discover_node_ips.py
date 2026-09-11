#!/usr/bin/env python3
"""
Dynamic DHCP Node Discovery & Inventory Resolver for K3s Clusters.

Discovers live DHCP IP addresses assigned to K3s VMs across the local network:
1. Fast parallel port-22 TCP scan across the subnet (192.168.0.0/24).
2. Parallel SSH hostname challenge to identify node roles (k3s-cp-* and k3s-wk-*).
3. Proxmox VE API inspection via QEMU guest agent & MAC ARP table.
4. Auto-updates environments/<env>/ansible/hosts.yaml with live DHCP IPv4 addresses.
5. Populates /etc/hosts in CI/CD runner container for seamless connectivity.
"""

import argparse
import concurrent.futures
import fcntl
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
import ssl

# Ensure blocking IO on stdin, stdout, stderr for Ansible compatibility
for fd in (0, 1, 2):
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        if flags & os.O_NONBLOCK:
            fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except Exception:
        pass

try:
    import yaml
except ImportError:
    print("[ERROR] pyyaml is required. Please install py3-yaml or python3 -m pip install pyyaml")
    sys.exit(1)

parser = argparse.ArgumentParser(description="Discover node IPs for environment")
parser.add_argument("--env", default=os.environ.get("ENV", "stage"), help="Target environment (stage/prod)")
args, _ = parser.parse_known_args()
ENV = args.env

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INVENTORY_FILE = os.path.join(REPO_ROOT, "environments", ENV, "ansible", "hosts.yaml")
VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://192.168.0.40:8200").rstrip("/")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")
SUBNET_PREFIX = os.environ.get("SUBNET_PREFIX", "192.168.0")
SSH_USER = os.environ.get("ANSIBLE_USER", "almalinux")

# Cluster-managed virtual interfaces must be ignored when reading addresses
# from the QEMU guest agent. With kube-proxy in IPVS mode, kube-ipvs0 holds
# every service address - ClusterIPs and MetalLB LoadBalancer IPs alike - on
# *every* node, so an address found there identifies the service, not the host.
# Filtering by interface rather than by IP range matters here because the DHCP
# scope and the MetalLB pool overlap: real nodes hold leases like .90/.91/.99,
# which sit inside the LoadBalancer pool and cannot be excluded by address.
VIRTUAL_IFACE_PREFIXES = (
    "lo",
    "kube-ipvs",
    "kube-vip",
    "flannel",
    "cni",
    "docker",
    "veth",
    "cali",
    "tunl",
    "vxlan",
    "dummy",
)

# Escape hatch for deliberately degraded runs (e.g. recovering a single node
# while another is knowingly offline). Off by default: a partial discovery
# normally means something is wrong, not that it's safe to carry on.
ALLOW_PARTIAL_DISCOVERY = os.environ.get("ALLOW_PARTIAL_DISCOVERY", "").lower() in ("1", "true", "yes")

# How many discovery passes before giving up. Each pass costs roughly 25s when
# a node is still missing (subnet scan + SSH challenge + the 10s backoff), so
# the default is ~2.5 minutes - fine for a normal run where every VM is already
# up. Callers that have just booted a VM (scripts/redeploy_node.sh) raise this,
# since a fresh clone needs to finish cloud-init and start qemu-guest-agent
# before it can be found at all.
try:
    MAX_DISCOVERY_ATTEMPTS = max(1, int(os.environ.get("DISCOVERY_MAX_ATTEMPTS", "6")))
except ValueError:
    print("[WARN] DISCOVERY_MAX_ATTEMPTS is not an integer - falling back to 6.")
    MAX_DISCOVERY_ATTEMPTS = 6
# guardian (host 2) and colossus (host 1) are standalone Proxmox hosts, each
# with its own API endpoint and token, and both environments span them -
# control planes on guardian, workers on colossus. Every host with credentials is queried;
# results are matched against the expected node names, so VMs belonging to
# the other environment are ignored.
PVE_HOST_DEFAULTS = {
    "1": ("https://colossus.jnet.lan:8006/", "colossus"),
    "2": ("https://guardian.jnet.lan:8006/", "guardian"),
}
# The generic PVE_* variables (and pve_* Vault keys) describe only the
# environment's primary host.
PRIMARY_PVE_HOST = "1" if ENV == "prod" else "2"

def resolve_pve_host(n):
    primary = n == PRIMARY_PVE_HOST
    endpoint = (
        os.environ.get(f"TF_VAR_pve_host_{n}_endpoint") or
        os.environ.get(f"PVE_HOST_{n}_ENDPOINT") or
        (os.environ.get("PVE_ENDPOINT") if primary else None) or
        PVE_HOST_DEFAULTS[n][0]
    )
    token = (
        os.environ.get(f"TF_VAR_pve_host_{n}_api_token") or
        os.environ.get(f"PVE_HOST_{n}_API_TOKEN") or
        (os.environ.get("PVE_API_TOKEN") if primary else None) or
        ""
    )
    node = (
        os.environ.get(f"TF_VAR_pve_host_{n}_node_name") or
        os.environ.get(f"PVE_HOST_{n}_NODE_NAME") or
        (os.environ.get("PVE_NODE_NAME") if primary else None) or
        PVE_HOST_DEFAULTS[n][1]
    )
    return {"endpoint": endpoint.rstrip("/"), "token": token, "node": node}

PVE_HOSTS = {n: resolve_pve_host(n) for n in PVE_HOST_DEFAULTS}

# Load credentials from Vault for any host the environment didn't supply
if VAULT_TOKEN and any(not host["token"] for host in PVE_HOSTS.values()):
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = urllib.request.Request(
            f"{VAULT_ADDR}/v1/secret/data/k3s-{ENV}/credentials",
            headers={"X-Vault-Token": VAULT_TOKEN}
        )
        with urllib.request.urlopen(req, timeout=3, context=ctx) as response:
            res_data = json.loads(response.read().decode())
            data = res_data.get("data", {}).get("data", {})
            if data:
                for n, host in PVE_HOSTS.items():
                    if host["token"]:
                        continue
                    primary = n == PRIMARY_PVE_HOST
                    host["token"] = data.get(f"pve_host_{n}_api_token") or (data.get("pve_api_token", "") if primary else "")
                    host["endpoint"] = (data.get(f"pve_host_{n}_endpoint") or (data.get("pve_endpoint") if primary else None) or host["endpoint"]).rstrip("/")
                    host["node"] = data.get(f"pve_host_{n}_node_name") or (data.get("pve_node_name") if primary else None) or host["node"]
    except Exception as e:
        print(f"[DEBUG] Vault discovery credential check skipped: {e}")

def get_inventory_expected_nodes():
    if not os.path.exists(INVENTORY_FILE):
        return {}
    with open(INVENTORY_FILE, "r") as f:
        data = yaml.safe_load(f)
    cluster = data.get("all", {}).get("children", {}).get("k3s_cluster", {}).get("children", {})
    cp_hosts = cluster.get("k3s_control_plane", {}).get("hosts", {}) or {}
    wk_hosts = cluster.get("k3s_workers", {}).get("hosts", {}) or {}
    expected = {}
    for h, v in cp_hosts.items():
        expected[h] = {"role": "control-plane", "current_ip": v.get("ansible_host"), "vmid": v.get("k3s_node_id")}
    for h, v in wk_hosts.items():
        expected[h] = {"role": "worker", "current_ip": v.get("ansible_host"), "vmid": v.get("k3s_node_id")}
    return expected

def is_virtual_iface(name):
    """True for cluster-managed interfaces that carry service addresses, not host leases."""
    return name.startswith(VIRTUAL_IFACE_PREFIXES)

def is_node_address(ip):
    """True if `ip` can plausibly be a node's own address on the management subnet."""
    if not ip.startswith(f"{SUBNET_PREFIX}."):
        return False
    try:
        last_octet = int(ip.rsplit(".", 1)[1])
    except (ValueError, IndexError):
        return False
    return last_octet != 1

def query_pve_agent_ips():
    discovered = {}
    queried = set()
    for host in PVE_HOSTS.values():
        target = (host["endpoint"], host["node"])
        if not host["token"] or target in queried:
            continue
        queried.add(target)
        for name, ip in query_pve_host_agent_ips(host).items():
            discovered.setdefault(name, ip)
    return discovered

def query_pve_host_agent_ips(host):
    discovered = {}
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        token = host["token"]
        auth_header = f"PVEAPIToken={token}" if not token.startswith("PVEAPIToken=") else token
        qemu_url = f"{host['endpoint']}/api2/json/nodes/{host['node']}/qemu"
        req = urllib.request.Request(
            qemu_url,
            headers={"Authorization": auth_header}
        )
        with urllib.request.urlopen(req, timeout=5, context=ctx) as response:
            vms = json.loads(response.read().decode()).get("data", [])
            
        for vm in vms:
            vmid = vm.get("vmid")
            name = vm.get("name", "")
            if not (name.startswith("k3s-cp-") or name.startswith("k3s-wk-")):
                continue
            if vm.get("status") != "running":
                continue
            try:
                agent_req = urllib.request.Request(
                    f"{qemu_url}/{vmid}/agent/network-get-interfaces",
                    headers={"Authorization": auth_header}
                )
                with urllib.request.urlopen(agent_req, timeout=4, context=ctx) as agent_res:
                    ifaces = json.loads(agent_res.read().decode()).get("data", {}).get("result", [])
                    # First match wins, across all interfaces: a later interface
                    # must never overwrite an address already resolved for this VM.
                    node_ip = None
                    for iface in ifaces:
                        if is_virtual_iface(iface.get("name", "")):
                            continue
                        for ip_entry in iface.get("ip-addresses", []):
                            if is_node_address(ip_entry.get("ip-address", "")):
                                node_ip = ip_entry.get("ip-address", "")
                                break
                        if node_ip:
                            break
                    if node_ip:
                        discovered[name] = node_ip
            except Exception:
                pass
    except Exception as e:
        print(f"[DEBUG] Proxmox API agent check encountered: {e}")
    return discovered

def check_port_22(ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.8)
    try:
        result = sock.connect_ex((ip, 22))
        sock.close()
        return ip if result == 0 else None
    except Exception:
        return None

def scan_live_ips():
    # The whole subnet is in scope: the DHCP scope overlaps the MetalLB pool, so
    # real nodes do hold leases inside it and cannot be skipped by range.
    ips = [f"{SUBNET_PREFIX}.{i}" for i in range(2, 255) if is_node_address(f"{SUBNET_PREFIX}.{i}")]
    live = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:
        results = executor.map(check_port_22, ips)
        for r in results:
            if r:
                live.append(r)
    return live

def ssh_identify_node(ip):
    try:
        res = subprocess.run(
            ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=3",
             "-o", "BatchMode=yes", f"{SSH_USER}@{ip}", "hostname"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=4
        )
        if res.returncode == 0:
            hostname = res.stdout.strip()
            if hostname.startswith("k3s-cp-") or hostname.startswith("k3s-wk-"):
                return hostname, ip
    except Exception:
        pass
    return None, None

def update_inventory_and_hosts(discovered_nodes):
    if not discovered_nodes:
        print("[WARN] No nodes discovered to write.")
        return

    print(f"\n[INFO] Updating inventory: {INVENTORY_FILE}")
    with open(INVENTORY_FILE, "r") as f:
        doc = yaml.safe_load(f)

    cluster = doc.get("all", {}).get("children", {}).get("k3s_cluster", {}).get("children", {})
    cp_hosts = cluster.get("k3s_control_plane", {}).get("hosts", {}) or {}
    wk_hosts = cluster.get("k3s_workers", {}).get("hosts", {}) or {}

    for name, ip in discovered_nodes.items():
        if name in cp_hosts:
            cp_hosts[name]["ansible_host"] = ip
            print(f"  -> Control Plane: {name} => {ip}")
        elif name in wk_hosts:
            wk_hosts[name]["ansible_host"] = ip
            print(f"  -> Worker Node:    {name} => {ip}")

    with open(INVENTORY_FILE, "w") as f:
        yaml.dump(doc, f, default_flow_style=False, sort_keys=False)

    # Populate /etc/hosts in runner container for absolute hostname resolution
    try:
        if os.path.exists("/etc/hosts") and os.access("/etc/hosts", os.W_OK):
            with open("/etc/hosts", "r") as f:
                content = f.read()
            additions = []
            for name, ip in discovered_nodes.items():
                if f" {name}" not in content:
                    additions.append(f"{ip} {name}\n")
            if additions:
                with open("/etc/hosts", "a") as f:
                    f.writelines(additions)
                print(f"[INFO] Added {len(additions)} node entries to /etc/hosts.")
    except Exception as e:
        print(f"[DEBUG] /etc/hosts update notice: {e}")

def main():
    print(f"[INFO] Discovering node IPs for environment: {ENV}")
    expected = get_inventory_expected_nodes()
    if not expected:
        print("[INFO] No hosts listed in inventory.")
        return

    print(f"[INFO] Expected nodes ({len(expected)}): {list(expected.keys())}")
    discovered = {}
    
    # Retry polling loop (see MAX_DISCOVERY_ATTEMPTS)
    max_attempts = MAX_DISCOVERY_ATTEMPTS
    for attempt in range(1, max_attempts + 1):
        # 1. Proxmox Agent query
        pve_found = query_pve_agent_ips()
        for k, v in pve_found.items():
            if k in expected:
                discovered[k] = v

        # 2. Subnet SSH challenge for remaining
        missing = [h for h in expected if h not in discovered]
        if missing:
            print(f"[INFO] (Attempt {attempt}/{max_attempts}) Found {len(discovered)}/{len(expected)}. Scanning subnet for remaining {len(missing)} nodes...")
            live_ips = scan_live_ips()
            with concurrent.futures.ThreadPoolExecutor(max_workers=30) as executor:
                results = executor.map(ssh_identify_node, live_ips)
                for name, ip in results:
                    # Never overwrite a guest-agent result: a node also answers
                    # SSH on any service address IPVS has bound locally, so the
                    # scan can reach a real host at an address that isn't its own.
                    if name and name in expected and name not in discovered:
                        discovered[name] = ip

        if len(discovered) >= len(expected):
            print(f"[INFO] Successfully discovered all {len(discovered)} expected nodes!")
            break
        elif attempt < max_attempts:
            print(f"[INFO] Waiting 10s for remaining VM network interfaces to initialize...")
            time.sleep(10)

    print(f"\n[INFO] Final discovery count: {len(discovered)} of {len(expected)} expected nodes.")

    # A host that wasn't discovered keeps whatever ansible_host is committed in
    # hosts.yaml. Those committed values are stale placeholders - stage and prod
    # currently carry identical addresses - so proceeding would silently target
    # whichever machine happens to hold that IP today, potentially in the other
    # environment. Refuse to run rather than configure the wrong host.
    missing = sorted(h for h in expected if h not in discovered)
    if missing:
        print(f"\n[ERROR] Discovery failed for {len(missing)} of {len(expected)} expected nodes:")
        for host in missing:
            stale_ip = expected[host].get("current_ip") or "unset"
            print(f"  - {host} (role={expected[host].get('role')}, "
                  f"stale inventory value: {stale_ip})")
        if not ALLOW_PARTIAL_DISCOVERY:
            print(
                "\n        The inventory was NOT updated. Running Ansible now would use the\n"
                "        stale addresses above, which are not guaranteed to belong to this\n"
                f"        environment ({ENV}).\n\n"
                "        Check that the VMs are running and their guest agents are up, then\n"
                "        re-run. To proceed anyway with only the nodes that were found,\n"
                "        set ALLOW_PARTIAL_DISCOVERY=true."
            )
            sys.exit(1)
        print(
            "\n[WARN] ALLOW_PARTIAL_DISCOVERY=true - updating inventory with the nodes\n"
            "       that were found. The hosts listed above keep their stale committed\n"
            "       addresses and may not belong to this environment."
        )

    update_inventory_and_hosts(discovered)

if __name__ == "__main__":
    main()
