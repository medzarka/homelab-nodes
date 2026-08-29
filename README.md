> ### 🌐 [Homelab Sovereign Cluster Architecture](https://github.com/medzarka/homelab-nodes)
> This repository is a modular component of the **Homelab Sovereign Multi-Node Cluster** — an enterprise-grade, privacy-first, self-hosted infrastructure spanning cloud VPS, on-premise compute servers, and edge ARM nodes.
> 
> * **Zero-Trust Network**: Multi-host WireGuard mesh interconnect via **Tailscale** with strict **Firewalld** zoning (`iptables: false`).
> * **Unified Identity & Ingress**: Centralized reverse proxy via **Traefik v3**, **Authelia SSO (2FA)**, and **LLDAP Directory**.
> * **Cluster Orchestration & GitOps**: High-availability **Docker Swarm** managed declaratively via **Arcane Cockpit**.
> * **Out-of-Band Bootstrap Ingress**: Lightweight Caddy reverse proxy with HTTP Basic Auth on Port `8005` for immediate, secure setup before Traefik is deployed.
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
                     │ (Ports 22, 80, 443, 8005)             │ (Port 22 only)
                     ▼                                       ▼
        ┌──────────────────────────┐            ┌──────────────────────────┐
        │  MASTER NODE (Cloud VPS) │            │  WORKER NODE (Compute/Edge)
        │  • Firewalld: 22,80,443, │            │  • Firewalld: 22 only    │
        │    8005 (Bootstrap Proxy)│            │  • tailscale0: TRUSTED   │
        │  • tailscale0: TRUSTED   │            │  • Journald: max 7 days  │
        │  • Journald: max 7 days  │            │  • Docker iptables: false│
        │  • Docker iptables: false│            │  • Weekly Reboot Timer   │
        │  • Weekly Reboot Timer   │            ├──────────────────────────┤
        ├──────────────────────────┤            │ DOCKER SERVICES:         │
        │ DOCKER SERVICES:         │◄──────────►│ ├─ Tailscale (Host Net)  │
        │ ├─ Tailscale (Host Net)  │  Encrypted │ │  (Mesh IP: 100.x.y.2)  │
        │ │  (Mesh IP: 100.x.y.1)  │ WireGuard  │ ├─ Arcane Agent          │
        │ ├─ Arcane Manager (:3552)│  Over VPN  │ └─ Swarm Worker          │
        │ ├─ Arcane Proxy (:8005)  │            └──────────────────────────┘
        │ │  (Caddy + Basic Auth)  │
        │ └─ Swarm Leader (2377)   │
        └──────────────────────────┘
```

---

## 🎯 Key Design Principles

1. **Multi-OS & Multi-Arch Support**:
   - **Operating Systems**: Ubuntu (22.04 / 24.04), Debian (11 / 12 / 13), Oracle Linux 9 / 10, RHEL 9 / 10.
   - **Architectures**: x86_64 (`amd64`) and ARM64 (`aarch64` / Orange Pi / Raspberry Pi / Ampere).
2. **Strict Firewall Control (`firewalld`)**:
   - **Master Node**: Public zone permits strictly `ssh` (22), `http` (80), `https` (443), and `8005` (Arcane Bootstrap Proxy).
   - **Worker Nodes**: Public zone permits **only** `ssh` (22).
   - **Inter-Node Trust**: The `tailscale0` VPN interface is placed into the `trusted` zone. All cluster management, Swarm gossip, Serf, overlay traffic, and Arcane Agent telemetry flow unrestricted across the encrypted private mesh.
3. **Out-of-Band Arcane Bootstrap Proxy (Port 8005)**:
   - **Solves the Bootstrap Paradox**: Allows immediate web browser access to Arcane before `homelab-gateway` (Traefik) is deployed.
   - **Two-Layer Defense**:
     - *Layer 1 (Network Proxy)*: HTTP Basic Auth prevents port scanners and bots from reaching Arcane.
     - *Layer 2 (Application Auth)*: Arcane JWT/password login.
   - **Native WebSocket Support**: Powered by lightweight Caddy Alpine to seamlessly stream container logs and interactive terminals.
4. **Docker Firewall Bypass Prevention (`"iptables": false`)**:
   - Containers never open ports directly on the host's public firewall.
   - NAT masquerading is enabled in Firewalld for seamless outbound container routing.
5. **Host 7-Day Log Retention**:
   - Configures `systemd-journald` with `MaxRetentionSec=7day`, `SystemMaxUse=500M`, and `MaxFileSec=1day`.
   - Automatically vacuums older logs immediately.
6. **Scheduled Weekly Updates & Reboot**:
   - Automated systemd timer (`homelab-auto-update.timer`) runs non-interactive system package updates followed by a safe system reboot on user-specified day/time.
7. **Containerized Tailscale & Arcane**:
   - Tailscale runs inside a Docker container using host networking and `/dev/net/tun`.
   - Arcane Manager is deployed on the Master node; Arcane Agent is deployed on Worker nodes.
8. **Tailscale Exit Node & Kernel IP Forwarding**:
   - Automatically configures Linux kernel packet forwarding (`net.ipv4.ip_forward = 1` and `net.ipv6.conf.all.forwarding = 1` in `/etc/sysctl.d/99-tailscale-forwarding.conf`).
   - Automatically advertises the node as a Tailscale Exit Node (`--advertise-exit-node`), allowing secure encrypted internet routing for your remote devices.

---

## 📁 Directory Structure

```
homelab-nodes/
├── README.md                           # Documentation & operations guide
├── .env.example                        # Template environment variables (NODE_ROLE=MASTER/WORKER)
├── .env                                # Active environment configuration
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
│   ├── Caddyfile                       # Out-of-band bootstrap proxy config (Basic Auth + WebSockets)
│   └── docker-compose.yaml             # Tailscale + Arcane Manager + Bootstrap Proxy stack
└── worker/
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

**Accessing Arcane on the Master Node:**
1. **Via Out-of-Band Bootstrap Proxy (Immediate, from anywhere):**
   - URL: `http://<SERVER_PUBLIC_IP>:8005`
   - Layer 1 (Proxy Basic Auth): `admin` / `<ARCANE_PROXY_PASSWORD>` (configured in `.env`)
   - Layer 2 (Arcane Application Login): `arcane` / `arcane-admin`
2. **Via Tailscale VPN Mesh:**
   - URL: `http://<MASTER_TAILSCALE_IP>:3552` (or `http://100.x.y.z:3552`)
3. **Via Traefik Edge Gateway (Once `homelab-gateway` is deployed):**
   - URL: `https://arcane.bluewave.work`

---

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

#### 🧙 Connecting a Worker Node to Arcane via Web UI:

1. **Access Arcane Cockpit on the Master Node**:
   Open your browser and navigate to:
   👉 **`http://<SERVER_PUBLIC_IP>:8005`** (or `http://100.x.y.z:3552`)

2. **Generate the Agent Token**:
   - In the left sidebar, click **Environments** (or **Nodes**).
   - Click the **`+ Add Environment`** button (top right).
   - Select **Edge Agent** (Polling transport mode).
   - Enter your Worker node's name (e.g., `zap-srv` or `oci01-flex`).
   - Click **Generate Configuration** to display your unique **`AGENT_TOKEN`**.

3. **Deploy the Worker Node**:
   - Copy `worker-join.env` from the Master to the Worker as `.env`:
     ```bash
     scp worker-join.env user@worker-machine:~/homelab-nodes/.env
     ```
   - On the Worker machine, edit `.env` and paste the token:
     ```ini
     ARCANE_AGENT_TOKEN=<PASTE_GENERATED_AGENT_TOKEN_HERE>
     ```
   - Run the bootstrapper:
     ```bash
     cd homelab-nodes
     sudo ./setup.sh
     ```

4. **Verify in Arcane UI**:
   - In Arcane Dashboard, your Worker node will transition to **🟢 Online**.

---

## 🔍 Auditing & Verifying Node Compliance (`audit-node.sh`)

At any time, run the built-in audit script to verify all security, firewall, logging, Docker, and container configurations:

```bash
# Audit as Master Node
sudo ./audit-node.sh --role master

# Audit as Worker Node
sudo ./audit-node.sh --role worker
```

---

## ⚙️ Environment Variables Reference (`.env`)

| Variable | Default | Description |
| :--- | :--- | :--- |
| `NODE_ROLE` | `MASTER` | Role: `MASTER`, `WORKER`, or `WORKER_DEEPER_OPTIMIZED` |
| `NODE_NAME` | `master-node` | Hostname and node identifier in Swarm & Arcane |
| `TS_HOSTNAME` | `master-node` | Tailscale machine hostname on your tailnet |
| `TS_AUTHKEY` | *(empty)* | Optional non-interactive Tailscale authentication key |
| `TS_EXTRA_ARGS` | `--reset --advertise-exit-node` | Arguments passed to `tailscale up` (Exit node enabled) |
| `SHARED_NETWORK` | `shared_net` | Local Docker bridge network name |
| `SWARM_NETWORK` | `homelab_swarm_net` | Multi-host Docker Swarm attachable overlay network name |
| `DATA_DIR` | `/srv/data` | Root directory for persistent data mounts |
| `ARCANE_PORT` | `3552` | Internal host port for Arcane core container |
| `ARCANE_ADMIN_USER` | `arcane` | Default admin username for Arcane web login |
| `ARCANE_ADMIN_PASSWORD` | `arcane-admin` | Default admin password for Arcane web login |
| `ARCANE_BOOTSTRAP_PORT` | `8005` | External public port for Caddy out-of-band bootstrap proxy |
| `ARCANE_PROXY_USER` | `admin` | HTTP Basic Auth username for bootstrap proxy |
| `ARCANE_PROXY_PASSWORD` | `arcane-bootstrap-admin` | HTTP Basic Auth password for bootstrap proxy |
| `ENCRYPTION_KEY` | *(auto-generated)* | 32-byte hex key for Arcane DB secret encryption |
| `JWT_SECRET` | *(auto-generated)* | 32-byte hex key for Arcane authentication tokens |
| `UPDATE_DAY` | `Sun` | Day of week for automated updates & reboot (`Sun`..`Sat`) |
| `UPDATE_TIME` | `04:00` | 24-hour time for automated maintenance (`HH:MM`) |
