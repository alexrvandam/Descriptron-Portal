#!/bin/bash
###############################################################################
# Descriptron Portal — One-Time Setup
# For the RunPod-based architecture (cheap VM + on-demand GPU pods)
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "=============================================="
echo "  Descriptron Portal — Setup"
echo "  (Guacamole + RunPod GPU pods)"
echo "=============================================="
echo ""

# ─── Prerequisites ───────────────────────────────────────────────────────
echo "[1/5] Checking prerequisites..."
for cmd in docker openssl; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done
docker compose version &>/dev/null || { echo "ERROR: docker compose v2 required"; exit 1; }
echo "  ✓ OK"
echo ""

# ─── Configuration ───────────────────────────────────────────────────────
echo "[2/5] Configuration..."

read -rp "  Domain name (e.g., descriptron.mfn-berlin.de): " DOMAIN
read -rp "  RunPod API key: " RUNPOD_API_KEY
read -rp "  Descriptron Docker image [yourdockerhubuser/descriptron-portal:latest]: " DESCRIPTRON_IMAGE
DESCRIPTRON_IMAGE="${DESCRIPTRON_IMAGE:-yourdockerhubuser/descriptron-portal:latest}"

echo ""
echo "  RunPod GPU options (common choices):"
echo "    NVIDIA RTX A4000          (~\$0.38/hr, 16GB VRAM)"
echo "    NVIDIA RTX A4500          (~\$0.47/hr, 20GB VRAM)"
echo "    NVIDIA RTX A5000          (~\$0.47/hr, 24GB VRAM)"
echo "    NVIDIA GeForce RTX 3090   (~\$0.44/hr, 24GB VRAM)"
echo "    NVIDIA RTX A6000          (~\$0.79/hr, 48GB VRAM)"
echo ""
read -rp "  GPU type [NVIDIA GeForce RTX 3090]: " RUNPOD_GPU_TYPE
RUNPOD_GPU_TYPE="${RUNPOD_GPU_TYPE:-NVIDIA GeForce RTX 3090}"

read -rp "  RunPod Network Volume ID (leave blank to skip): " RUNPOD_NETWORK_VOLUME_ID
read -rp "  RunPod Datacenter ID (leave blank for auto): " RUNPOD_DATACENTER_ID
read -rp "  Pod idle timeout in minutes [120]: " POD_IDLE_TIMEOUT
POD_IDLE_TIMEOUT="${POD_IDLE_TIMEOUT:-120}"

DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
SECRET_KEY=$(openssl rand -hex 32)

echo "  ✓ Configuration complete"
echo ""

# ─── Generate Guacamole DB schema ───────────────────────────────────────
echo "[3/5] Generating Guacamole database..."
mkdir -p guacamole
docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql \
    > guacamole/initdb.sql
echo "  ✓ Schema generated"
echo ""

# ─── Generate Nginx config ──────────────────────────────────────────────
echo "[4/5] Generating Nginx config..."
mkdir -p nginx/ssl

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/ssl/selfsigned.key -out nginx/ssl/selfsigned.crt \
    -subj "/CN=${DOMAIN}" 2>/dev/null

cat > nginx/nginx.conf <<NGINXEOF
worker_processes auto;
events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;

    # HTTP → HTTPS redirect
    server {
        listen 80;
        server_name ${DOMAIN};
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://\$host\$request_uri; }
    }

    # HTTPS
    server {
        listen 443 ssl;
        server_name ${DOMAIN};

        # Start with self-signed; switch to Let's Encrypt later
        ssl_certificate     /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;
        # ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        # ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        add_header X-Frame-Options SAMEORIGIN;
        add_header Strict-Transport-Security "max-age=63072000" always;

        # ── Guacamole (remote desktop portal) ───────────────────────
        location /guacamole/ {
            proxy_pass http://guac-web:8080/guacamole/;
            proxy_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        # ── Orchestrator dashboard + API ────────────────────────────
        location /dashboard {
            proxy_pass http://descriptron-orchestrator:5000/dashboard;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        location /api/ {
            proxy_pass http://descriptron-orchestrator:5000/api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }

        # ── Root redirect to dashboard ──────────────────────────────
        location = / {
            return 302 /dashboard?user=\$arg_user;
        }
    }
}
NGINXEOF

echo "  ✓ Nginx config generated"
echo ""

# ─── Save .env ───────────────────────────────────────────────────────────
echo "[5/5] Saving configuration..."

cat > .env <<ENVEOF
# Descriptron Portal Configuration
# Generated on $(date -Iseconds)

DOMAIN=${DOMAIN}
DB_PASSWORD=${DB_PASSWORD}
SECRET_KEY=${SECRET_KEY}

# RunPod
RUNPOD_API_KEY=${RUNPOD_API_KEY}
DESCRIPTRON_IMAGE=${DESCRIPTRON_IMAGE}
RUNPOD_GPU_TYPE=${RUNPOD_GPU_TYPE}
RUNPOD_NETWORK_VOLUME_ID=${RUNPOD_NETWORK_VOLUME_ID}
RUNPOD_DATACENTER_ID=${RUNPOD_DATACENTER_ID}

# Pod settings
POD_IDLE_TIMEOUT_MINUTES=${POD_IDLE_TIMEOUT}
POD_CONTAINER_DISK_GB=50
POD_VOLUME_GB=20

COMPOSE_PROJECT_NAME=descriptron-portal
ENVEOF

chmod 600 .env

echo "  ✓ Saved to .env"
echo ""

# ─── Done ────────────────────────────────────────────────────────────────
echo "=============================================="
echo "  ✅ Setup Complete!"
echo "=============================================="
echo ""
echo "  Next steps:"
echo ""
echo "  1. Start the portal:"
echo "     docker compose up -d --build"
echo ""
echo "  2. Log into Guacamole (change the default password!):"
echo "     https://${DOMAIN}/guacamole/"
echo "     Default: guacadmin / guacadmin"
echo ""
echo "  3. Add users:"
echo "     ./scripts/add-user.sh francisco 'Francisco Hita Garcia'"
echo ""
echo "  4. Users go to https://${DOMAIN}/dashboard?user=francisco"
echo "     to start their GPU session, then connect via Guacamole."
echo ""
echo "  Monthly cost estimate:"
echo "    Portal VM (Hetzner CX22):  ~€4/month"
echo "    RunPod GPU (per session):  ~\$0.44/hr (RTX 3090)"
echo "    RunPod storage (10GB):     ~\$0.70/month"
echo "    Total idle cost:           ~€5/month"
echo ""
