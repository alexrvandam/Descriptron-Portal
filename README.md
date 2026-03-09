# Descriptron Portal

**Cloud-deployed multi-user gateway for GPU-accelerated morphological analysis**

Developed at the [Museum für Naturkunde Berlin](https://www.museumfuernaturkunde.berlin/), Center for Integrative Biodiversity Discovery.

## Overview

Descriptron Portal provides authenticated, browser-based access to GPU-powered Descriptron workspaces for taxonomic research. Users log in through a web dashboard, provision an on-demand GPU pod (via [RunPod](https://www.runpod.io/)), and interact with a full Linux desktop running SAM2 segmentation, Detectron2 keypoint detection, DINOSAR_v2 species delimitation, and the complete Descriptron annotation toolkit — all from a standard web browser with no local installation.

The portal is designed for small research groups (3–10 users) who need shared access to GPU compute for biodiversity informatics workflows without the cost or complexity of maintaining dedicated GPU hardware.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    User's Web Browser                       │
│              (no installation required)                      │
└──────────────────────┬──────────────────────────────────────┘
                       │ HTTPS
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  Hetzner VPS (CPU-only, ~€4–8/month)                        │
│                                                              │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │   Nginx     │  │  Guacamole   │  │   Orchestrator     │  │
│  │  (SSL/TLS,  │──│  (auth,      │  │  (Flask: pod       │  │
│  │   reverse   │  │   sessions,  │  │   lifecycle, user  │  │
│  │   proxy)    │  │   VNC proxy) │  │   management, API) │  │
│  └─────────────┘  └──────┬───────┘  └────────┬───────────┘  │
│                          │                    │              │
│  ┌───────────┐  ┌────────┴──┐                 │              │
│  │ PostgreSQL│  │  guacd    │                  │              │
│  │ (users,   │  │ (VNC      │                  │              │
│  │  sessions)│  │  daemon)  │                  │              │
│  └───────────┘  └─────┬────┘                  │              │
└───────────────────────┼───────────────────────┼──────────────┘
                        │ VNC over internet     │ RunPod API
                        ▼                       ▼
┌──────────────────────────────────────────────────────────────┐
│  RunPod Secure Cloud (GPU on demand)                         │
│                                                              │
│  ┌───────────────────────────────────────────┐               │
│  │  Descriptron Pod (RTX 4000/3090/4090/...) │               │
│  │  • SAM2 encoder + ONNX decoder            │               │
│  │  • Detectron2 + keypoint models           │               │
│  │  • DINOSAR v2 embeddings                  │               │
│  │  • VNC desktop (port 5901)                │               │
│  │  • File manager (port 8888)               │               │
│  │  • Persistent /workspace volume           │               │
│  └───────────────────────────────────────────┘               │
└──────────────────────────────────────────────────────────────┘
```

## Features

- **Zero-install access**: Users work entirely in the browser via Apache Guacamole remote desktop.
- **On-demand GPU**: Pods are provisioned on RunPod only when needed, with automatic GPU fallback across multiple types (A4000 → 3090 → A5000 → 4090 → A6000).
- **File transfer**: Built-in file manager for uploading specimen images and downloading results.
- **Session management**: Dashboard shows GPU type, cost, pod status; idle pods auto-stop after configurable timeout.
- **Cost control**: GPU pods run only during active sessions. A Hetzner CPU VPS hosts the always-on portal at minimal cost.
- **SSL/TLS**: Automated Let's Encrypt certificates with Certbot auto-renewal.
- **Multi-domain**: Nginx routes traffic for multiple domains (portal + companion tools) from a single server.

## Prerequisites

- A Hetzner Cloud VPS (CX22 or similar, ~€4–8/month) or any Linux server with Docker
- A domain name pointing to your server's IP
- A RunPod account with API key
- A Docker Hub account with your Descriptron image pushed
- Docker Engine and Docker Compose v2

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USER/descriptron-portal.git
cd descriptron-portal
cp .env.example .env
nano .env  # Fill in your RunPod API key, domain, passwords
```

### 2. Run setup

```bash
chmod +x setup.sh scripts/*.sh
./setup.sh
```

This generates the Guacamole database schema, self-signed SSL certificates for initial startup, Nginx configuration, and a FileBrowser configuration.

### 3. Start the portal

```bash
docker compose up -d
docker compose logs -f  # Watch startup (Ctrl+C to exit)
```

### 4. Set up Let's Encrypt SSL

```bash
# Get certificate (domain must point to your server)
docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot -d your-domain.com

# Update nginx config: switch from self-signed to Let's Encrypt
nano nginx/nginx.conf
docker exec guac-proxy nginx -t && docker exec guac-proxy nginx -s reload
```

### 5. Access the dashboard

Open `https://your-domain.com/dashboard` in your browser. Log in, start a GPU session, and click "Open Desktop" to launch the Descriptron workspace.

## Services

| Service | Container | Purpose |
|---------|-----------|---------|
| Nginx | `guac-proxy` | SSL termination, reverse proxy |
| Guacamole | `guac-web` | User authentication, VNC session management |
| guacd | `guac-daemon` | VNC connection proxy to RunPod pods |
| PostgreSQL | `guac-db` | User accounts, connection history |
| Orchestrator | `descriptron-orchestrator` | RunPod pod lifecycle, dashboard API |
| Certbot | `guac-certbot` | Automated SSL certificate renewal |

## Configuration

### GPU Fallback Chain

If the preferred GPU type is unavailable, the orchestrator tries alternatives in order. Configure in `.env`:

```
RUNPOD_GPU_TYPE=NVIDIA RTX A4000
RUNPOD_GPU_FALLBACKS=NVIDIA GeForce RTX 3090,NVIDIA RTX A5000,NVIDIA GeForce RTX 4090,NVIDIA RTX A6000
```

### Idle Timeout

Pods automatically stop after a period of inactivity to save costs:

```
POD_IDLE_TIMEOUT_MINUTES=120
```

### Pod Resources

```
POD_CONTAINER_DISK_GB=50
POD_VOLUME_GB=20
```

## User Workflow

1. Navigate to `https://your-domain.com/dashboard`
2. Click **Start GPU Session** — a RunPod pod is provisioned (2–5 minutes)
3. Once ready, click **Open Desktop** to launch the VNC workspace
4. Use **Upload Files** to transfer specimen images to the pod
5. Run Descriptron tools in the desktop environment
6. **Stop** the session when done (data persists on the RunPod network volume)
7. **Terminate** removes the pod completely when finished

## Backup

```bash
# Backup Guacamole database
docker exec guac-db pg_dump -U guacamole_user guacamole_db > backups/guacamole-$(date +%Y%m%d).sql

# Backup orchestrator session data
docker cp descriptron-orchestrator:/app/data ./backups/orchestrator-data-$(date +%Y%m%d)

# Backup configuration
tar czf backups/config-$(date +%Y%m%d).tar.gz docker-compose.yml nginx/ orchestrator/ scripts/ .env
```

## Cost Estimate

| Component | Provider | Monthly Cost |
|-----------|----------|-------------|
| Portal VPS (CX22, 2 vCPU, 4GB RAM) | Hetzner Cloud | ~€4–8 |
| GPU pods (RTX A4000, ~$0.25/hr) | RunPod | ~$20–80 (usage-dependent) |
| Domain name | Porkbun / Namecheap | ~€1 |
| SSL certificates | Let's Encrypt | Free |

For a small group running 2–4 hours of GPU sessions per day, expect roughly €30–60/month total — significantly less than dedicated GPU hardware.

## Related Projects

- **[Descriptron GBIF Annotator](https://descriptrongbifannotator.org)**: Browser-based morphological annotation platform for GBIF occurrence images (zero-install, single HTML file).
- **DINOSAR v2**: Vision embedding system for open-set species delimitation.

## Citation

If you use the Descriptron Portal in your research, please cite:

```
van Dam, A. (2026). Descriptron Portal: Cloud-deployed multi-user gateway for 
GPU-accelerated morphological analysis. Museum für Naturkunde Berlin, Center 
for Integrative Biodiversity Discovery. https://doi.org/10.5281/zenodo.XXXXXXX
```

## License

Apache 2.0

