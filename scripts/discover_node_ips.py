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
if ENV == "prod":
    PVE_ENDPOINT = os.environ.get("PVE_HOST_1_ENDPOINT", os.environ.get("PVE_ENDPOINT", "https://colossus.jnet.lan:8006/")).rstrip("/")
    PVE_API_TOKEN = os.environ.get("PVE_HOST_1_API_TOKEN", os.environ.get("PVE_API_TOKEN", ""))
    PVE_NODE = os.environ.get("PVE_HOST_1_NODE_NAME", os.environ.get("PVE_NODE_NAME", "colossus"))
else:
    PVE_ENDPOINT = os.environ.get("PVE_HOST_2_ENDPOINT", os.environ.get("PVE_ENDPOINT", "https://guardian.jnet.lan:8006/")).rstrip("/")
    PVE_API_TOKEN = os.environ.get("PVE_HOST_2_API_TOKEN", os.environ.get("PVE_API_TOKEN", ""))
    PVE_NODE = os.environ.get("PVE_HOST_2_NODE_NAME", os.environ.get("PVE_NODE_NAME", "guardian"))

# Load credentials from Vault if available
if VAULT_TOKEN and not PVE_API_TOKEN:
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
                if ENV == "prod":
                    PVE_API_TOKEN = PVE_API_TOKEN or data.get("pve_host_1_api_token") or data.get("pve_api_token", "")
                    PVE_ENDPOINT = data.get("pve_host_1_endpoint") or data.get("pve_endpoint") or PVE_ENDPOINT
                    PVE_NODE = data.get("pve_host_1_node_name") or data.get("pve_node_name") or "colossus"
                else:
                    PVE_API_TOKEN = PVE_API_TOKEN or data.get("pve_host_2_api_token") or data.get("pve_api_token", "")
                    PVE_ENDPOINT = data.get("pve_host_2_endpoint") or data.get("pve_endpoint") or PVE_ENDPOINT
                    PVE_NODE = data.get("pve_host_2_node_name") or data.get("pve_node_name") or "guardian"
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

def query_pve_agent_ips():
    if not PVE_API_TOKEN:
        return {}
    discovered = {}
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        req = urllib.request.Request(
            f"{PVE_ENDPOINT}/api2/json/nodes/{PVE_NODE}/qemu",
            headers={"Authorization": f"PVEAPIToken={PVE_API_TOKEN}"}
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
                    f"{PVE_ENDPOINT}/api2/json/nodes/{PVE_NODE}/qemu/{vmid}/agent/network-get-interfaces",
                    headers={"Authorization": f"PVEAPIToken={PVE_API_TOKEN}"}
                )
                with urllib.request.urlopen(agent_req, timeout=4, context=ctx) as agent_res:
                    ifaces = json.loads(agent_res.read().decode()).get("data", {}).get("result", [])
                    for iface in ifaces:
                        for ip_entry in iface.get("ip-addresses", []):
                            ip = ip_entry.get("ip-address", "")
                            if ip.startswith(f"{SUBNET_PREFIX}.") and not ip.endswith(".1"):
                                discovered[name] = ip
                                break
            except Exception:
                pass
    except Exception as e:
        print(f"[DEBUG] Proxmox API agent check encountered: {e}")
    return discovered

def check_port_22(ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.3)
    result = sock.connect_ex((ip, 22))
    sock.close()
    return ip if result == 0 else None

def scan_live_ips():
    ips = [f"{SUBNET_PREFIX}.{i}" for i in range(2, 255)]
    live = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=60) as executor:
        results = executor.map(check_port_22, ips)
        for r in results:
            if r:
                live.append(r)
    return live

def ssh_identify_node(ip):
    try:
        res = subprocess.run(
            ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=2",
             "-o", "BatchMode=yes", f"{SSH_USER}@{ip}", "hostname"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3
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
        print("[WARN] No nodes discovered.")
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

    # Optional /etc/hosts update
    try:
        hosts_entries = [f"{ip} {name}\n" for name, ip in discovered_nodes.items()]
        if os.path.exists("/etc/hosts") and os.access("/etc/hosts", os.W_OK):
            with open("/etc/hosts", "r") as f:
                content = f.read()
            for name, ip in discovered_nodes.items():
                if name not in content:
                    content += f"{ip} {name}\n"
            with open("/etc/hosts", "w") as f:
                f.write(content)
    except Exception:
        pass

def main():
    print(f"[INFO] Discovering node IPs for environment: {ENV}")
    expected = get_inventory_expected_nodes()
    if not expected:
        print("[INFO] No hosts listed in inventory.")
        return

    print(f"[INFO] Expected nodes ({len(expected)}): {list(expected.keys())}")
    discovered = query_pve_agent_ips()
    
    missing = [h for h in expected if h not in discovered]
    if missing:
        print(f"[INFO] Proxmox agent returned {len(discovered)} nodes. Scanning subnet for remaining {len(missing)} nodes...")
        live_ips = scan_live_ips()
        with concurrent.futures.ThreadPoolExecutor(max_workers=30) as executor:
            results = executor.map(ssh_identify_node, live_ips)
            for name, ip in results:
                if name and name in expected:
                    discovered[name] = ip

    print(f"[INFO] Discovered {len(discovered)} of {len(expected)} expected nodes.")
    update_inventory_and_hosts(discovered)

if __name__ == "__main__":
    main()
