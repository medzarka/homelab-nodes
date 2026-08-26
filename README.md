> ### 🌐 [Homelab Sovereign Cluster Architecture](https://github.com/medzarka/homelab-nodes)
> This repository is a modular component of the **Homelab Sovereign Multi-Node Cluster** — an enterprise-grade, privacy-first, self-hosted infrastructure spanning cloud VPS, on-premise compute servers, and edge ARM nodes.
> 
> * **Zero-Trust Network**: Multi-host WireGuard mesh interconnect via **Tailscale** with strict **Firewalld** zoning (`iptables: false`).
> * **Unified Identity & Ingress**: Centralized reverse proxy via **Traefik v3**, **Authelia SSO (2FA)**, and **LLDAP Directory**.
> * **Cluster Orchestration & GitOps**: High-availability **Docker Swarm** managed declaratively via **Arcane Cockpit**.
> * **End-to-End Observability**: Centralized portal (**Homepage**), metrics (**Beszel**), real-time logs (**Dozzle**), and uptime monitoring (**Uptime Kuma**).
> * **Sovereign Local AI & Compute**: Distributed inference (**LiteLLM**, **Ollama**, **Qdrant**, **Mem0**, **Hermes Agents**).
> * **Private Cloud & Storage**: Encrypted data synchronization, automated backups, and multi-cloud mirrors.

---

# 🌐 Homelab Nodes (`homelab-nodes`) — Multi-Node Cluster Automation & Security Framework

A unified, hardened, and automated node initialization suite designed to bootstrap machines and VPS instances into a secure **Docker Swarm + Tailscale Mesh** cluster managed via **Arcane Cockpit**.

---

## 🏛️ Cluster Topology & Network Security Model

```
                                [ Public Internet ]
                                         │
                     ┌───────────────────┴───────────────────┐
                     │ (Ports 22, 80, 443)                   │ (Port 22 only)
                     ▼                                       ▼
        ┌──────────────────────────┐            ┌──────────────────────────┐
        │  MASTER NODE (Cloud VPS) │            │  WORKER NODE (Compute/Edge)
        │  • Firewalld: 22, 80, 443│            │  • Firewalld: 22 only    │
        │  • tailscale0: TRUSTED   │            │  • tailscale0: TRUSTED   │
        │  • Journald: max 7 days  │            │  • Journald: max 7 days  │
        │  • Docker iptables: false│            │  • Docker iptables: false│
        │  • Weekly Reboot Timer   │            │  • Weekly Reboot Timer   │
        ├──────────────────────────┤            ├──────────────────────────┤
        │ DOCKER SERVICES:         │            │ DOCKER SERVICES:         │
        │ ├─ Tailscale (Host Net)  │◄──────────►│ ├─ Tailscale (Host Net)  │
        │ │  (Mesh IP: 100.x.y.1)  │  Encrypted │ │  (Mesh IP: 100.x.y.2)  │
        │ ├─ Arcane Manager (:3552)│ WireGuard  │ ├─ Arcane Agent          │
        │ └─ Swarm Leader (2377)   │  Over VPN  │ └─ Swarm Worker          │
        └──────────────────────────┘            └──────────────────────────┘
```

---

## 🎯 Key Design Principles

1. **Multi-OS & Multi-Arch Support**:
   - **Operating Systems**: Ubuntu (22.04 / 24.04), Debian (11 / 12 / 13), Oracle Linux 9 / 10, RHEL 9 / 10.
   - **Architectures**: x86_64 (`amd64`) and ARM64 (`aarch64` / Orange Pi / Raspberry Pi / Ampere).
2. **Strict Firewall Control (`firewalld`)**:
   - **Master Node**: Public zone permits strictly `ssh` (22), `http` (80), and `https` (443).
   - **Worker Nodes**: Public zone permits **only** `ssh` (22).
   - **Inter-Node Trust**: The `tailscale0` VPN interface is placed into the `trusted` zone. All cluster management, Swarm gossip, Serf, overlay traffic, and Arcane Agent telemetry flow unrestricted across the encrypted private mesh.
3. **Docker Firewall Bypass Prevention (`"iptables": false`)**:
   - Containers never open ports directly on the host's public firewall.
   - NAT masquerading is enabled in Firewalld for seamless outbound container routing.
4. **Host 7-Day Log Retention**:
   - Configures `systemd-journald` with `MaxRetentionSec=7day`, `SystemMaxUse=500M`, and `MaxFileSec=1day`.
   - Automatically vacuums older logs immediately.
5. **Scheduled Weekly Updates & Reboot**:
   - Automated systemd timer (`homelab-auto-update.timer`) runs non-interactive system package updates followed by a safe system reboot on user-specified day/time.
6. **Containerized Tailscale & Arcane**:
   - Tailscale runs inside a Docker container using host networking and `/dev/net/tun`.
   - Arcane Manager is deployed on the Master node; Arcane Agent is deployed on Worker nodes.

---

## 📁 Directory Structure

```
homelab-nodes/
├── README.md                           # Documentation & operations guide
├── .env.example                        # Template environment variables (NODE_ROLE=MASTER/WORKER)
├── setup.sh                            # 🌟 Unified bootstrap orchestrator (dispatches based on NODE_ROLE)
├── setup-master.sh                     # Master Node bootstrap & hardening script
├── setup-worker.sh                     # Worker Node bootstrap & hardening script
├── worker-deeper-optimized.sh          # Deeply optimized Worker Node setup (High-I/O / Proxmox / Compute)
├── setup-worker-deeper-optimized.sh    # Full optimized worker implementation
├── audit-node.sh                       # Comprehensive audit & verification tool
├── common/
│   ├── 01-detect-os.sh                 # OS & Architecture detection helper
│   ├── 02-configure-logs.sh            # 7-day journald & logrotate configuration
│   ├── 03-configure-updates.sh         # Weekly update & reboot systemd timer
│   ├── 04-install-docker.sh            # Docker CE installer & daemon.json hardener
│   ├── 05-configure-firewalld.sh       # Firewalld reset, public rules & trusted tailscale0
│   └── 06-storage-optimizations.sh     # Deep disk I/O, udev scheduler, sysctl anti-freeze & RAM-disk
├── master/
│   ├── .env.example                    # Master environment variables (NODE_ROLE=MASTER)
│   └── docker-compose.yaml             # Tailscale + Arcane Manager stack
└── worker/
    ├── .env.example                    # Worker environment variables (NODE_ROLE=WORKER)
    └── docker-compose.yaml             # Tailscale + Arcane Agent stack
```

---

## 🚀 Quick Start Guide

### 🌟 Unified Bootstrapper (`setup.sh`)

Simply configure `.env` (or let the interactive prompt guide you) and run:

```bash
cd homelab-nodes
cp .env.example .env
# Edit .env and set NODE_ROLE (MASTER, WORKER, or WORKER_DEEPER_OPTIMIZED)
sudo ./setup.sh
```

`setup.sh` will automatically evaluate `NODE_ROLE`, execute the respective provisioning and hardening script, and deploy the appropriate Docker Compose stack (`master` or `worker`).

---

### Direct Script Execution

#### 🅰️ Setting Up the Master Node (Primary Leader)
```bash
cd homelab-nodes
sudo ./setup-master.sh
```

#### 🅱️ Setting Up a Standard Worker Node (Compute / Edge / VPS)
```bash
cd homelab-nodes
sudo ./setup-worker.sh
```

#### 🅲 Setting Up a Deeper Optimized Worker Node
Run on dedicated hardware, Proxmox nodes, compute nodes (Ollama, AI models, heavy databases), or machines with DRAM-less SSDs:
```bash
cd homelab-nodes
sudo ./worker-deeper-optimized.sh
```

**Extra Optimizations Applied Automatically:**
1. **Udev Block Layer Queue Tuning**: Configures `/etc/udev/rules.d/60-homelab-ioscheduler.rules` (`none` scheduler, `read_ahead_kb=128`, `rq_affinity=2`, `nr_requests=64`).
2. **Kernel Storage Anti-Freeze Sysctl**: Configures `/etc/sysctl.d/99-storage-anti-freeze.conf` (`vm.dirty_bytes=64MB`, `vm.dirty_background_bytes=32MB`, `vm.vfs_cache_pressure=50`, `vm.swappiness=1`).
3. **Ephemeral High-Speed RAM-Disk**: Configures persistent `tmpfs` at `/mnt/ramdisk` in `/etc/fstab` (auto-sized to system RAM).
4. **ZFS Trickle-Write Rate Limiter**: If ZFS is present, configures `/etc/modprobe.d/zfs.conf` and dataset properties (`compression=lz4`, `atime=off`, `xattr=sa`).

---

### ⚡ Seamless Worker Fleet Onboarding (`worker-join.env`)

When `setup-master.sh` finishes initializing the Master node, it automatically generates a ready-to-use **`worker-join.env`** configuration containing the Master's Tailscale mesh IP, Arcane URL, Swarm join token, and overlay network definitions.

**To deploy any Worker node with zero manual configuration:**
1. Log into your Arcane Cockpit UI (`http://<master-ip>:3552`) $\rightarrow$ **Nodes** $\rightarrow$ **Add Node** and copy the Agent Token into `worker-join.env`.
2. Copy `worker-join.env` directly to the worker machine as `.env`:
   ```bash
   scp worker-join.env user@worker-machine:~/homelab-nodes/.env
   ```
3. SSH into the worker machine and run:
   ```bash
   cd homelab-nodes
   sudo ./setup.sh
   ```
   The worker will automatically detect the configuration, harden the system, connect to Tailscale, join Docker Swarm, and start the Arcane Agent!

---

**What the script does automatically:**
1. Configures 7-day log retention.
2. Sets up weekly auto-update + reboot timer.
3. Resets Firewalld and locks down `public` to **SSH (22) only**, placing `tailscale0` in `trusted`.
4. Installs Docker CE with `"iptables": false`.
5. Starts **Tailscale** and connects the **Arcane Agent** to your Master node.
6. Joins the **Docker Swarm** cluster across the Tailscale mesh.

---

## 🔍 Auditing & Verifying Node Compliance (`audit-node.sh`)

At any time, run the built-in audit script to verify all security, firewall, logging, Docker, and container configurations:

```bash
# Audit as Master Node
sudo ./audit-node.sh --role master

# Audit as Worker Node
sudo ./audit-node.sh --role worker
```

### Sample Audit Output:
```
====================================================================
         🔍 HOMELAB NODE SECURITY & COMPLIANCE AUDIT                
====================================================================
 Auditing Target Role: WORKER
 Timestamp:            2026-08-26T05:50:00+01:00
 Hostname:             worker-node-01

1. 🖥️ Operating System & Architecture
  [ PASS ] Operating System: Oracle Linux Server 9.4 (Kernel: 5.15.0-205.149.5.1.el9uek.aarch64)
  [ PASS ] CPU Architecture: aarch64

2. 🛡️ Firewalld Firewall Hardening
  [ PASS ] Firewalld service is active and running.
  [ PASS ] Public zone permits SSH service.
  [ PASS ] Public zone NAT masquerading is ENABLED (Outbound container routing active).
  [ PASS ] Worker public zone is strictly locked down (SSH only, no public HTTP/HTTPS).
  [ PASS ] Interface 'tailscale0' is assigned to the 'trusted' zone (Inter-node mesh open).
  [ PASS ] Docker bridges (docker0, docker_gwbridge) are isolated from trusted zone (No zone conflicts).

3. 🐳 Docker Engine & Daemon Hardening
  [ PASS ] Docker Engine is active: Docker version 27.1.1
  [ PASS ] Configuration file /etc/docker/daemon.json exists.
  [ PASS ] Docker 'iptables: false' is configured (Firewall bypass prevented).
  [ PASS ] Docker 'live-restore: true' is configured (Zero-downtime container uptime).
  [ PASS ] Docker container log rotation limits are configured.

4. 🐝 Docker Swarm Cluster & Overlay Mesh
  [ PASS ] Docker Swarm is ACTIVE (Role: Worker Node).
  [ PASS ] Overlay network 'homelab_swarm_net' is available.

5. 📜 Host Logging System (7-Day Retention)
  [ PASS ] Journald 7-day retention policy is active (/etc/systemd/journald.conf.d/00-homelab-retention.conf).
  [ INFO ] Current Journal Disk Footprint: 88.0M

6. ⏰ Automated Weekly Maintenance Timer
  [ PASS ] Systemd timer 'homelab-auto-update.timer' is ENABLED and ACTIVE.
  [ INFO ] Next scheduled update & reboot: Sun 2026-08-30 04:00:00 UTC

7. 📦 Containerized Services (Tailscale & Arcane)
  [ PASS ] Tailscale container is running (Mesh IP: 100.101.102.2).
  [ PASS ] Arcane Agent container is running.

====================================================================
                     AUDIT RESULTS SUMMARY                         
====================================================================
  Passed Checks:   16
  Warnings:        0
  Failed Checks:   0

🎉 COMPLIANCE AUDIT PASSED! This node satisfies all Homelab standards.
```

---

## ⚙️ Configuration Reference (`daemon.json` & Variables)

### Hardened Production `/etc/docker/daemon.json`
```json
{
  "iptables": false,
  "live-restore": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "max-concurrent-downloads": 3,
  "max-concurrent-uploads": 3
}
```

### Systemd Weekly Maintenance Schedule
- Check timer status: `systemctl status homelab-auto-update.timer`
- View upcoming run time: `systemctl list-timers homelab-auto-update.timer`
- View past upgrade logs: `journalctl -u homelab-auto-update.service`

### Tailscale Manual Authentication (If Auth Key is not used)
```bash
sudo docker exec -it tailscale tailscale up
```

### Firewalld Useful Inspection Commands
```bash
# View active zones and assigned interfaces
sudo firewall-cmd --get-active-zones

# View public zone rules
sudo firewall-cmd --zone=public --list-all

# View trusted zone rules
sudo firewall-cmd --zone=trusted --list-all
```
