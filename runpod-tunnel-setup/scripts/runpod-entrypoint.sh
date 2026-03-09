#!/bin/bash
###############################################################################
# RunPod Entrypoint for Descriptron Portal
#
# This script runs inside the RunPod pod on boot. It:
#   1. Decodes the SSH tunnel key from environment variable
#   2. Starts the VNC server (for Guacamole desktop access)
#   3. Establishes reverse SSH tunnel to Hetzner
#   4. Starts the original Descriptron environment
#
# Required environment variables:
#   TUNNEL_KEY_B64    - Base64-encoded SSH private key
#   HETZNER_HOST      - Hetzner server IP or domain
#   TUNNEL_PORT       - Remote port on Hetzner (e.g. 15901)
#
# Optional:
#   HETZNER_SSH_PORT  - SSH port on Hetzner (default: 22)
#   VNC_PORT          - Local VNC port (default: 5901)
#   VNC_RESOLUTION    - VNC resolution (default: 1920x1080)
#   TUNNEL_USER       - SSH user on Hetzner (default: descriptron-tunnel)
###############################################################################
set -euo pipefail

# Defaults
HETZNER_SSH_PORT="${HETZNER_SSH_PORT:-22}"
VNC_PORT="${VNC_PORT:-5901}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1920x1080}"
TUNNEL_USER="${TUNNEL_USER:-descriptron-tunnel}"

echo "═══════════════════════════════════════════════════"
echo "  Descriptron Portal - RunPod Boot"
echo "  $(date)"
echo "═══════════════════════════════════════════════════"

# ─── 1. Setup SSH key ───────────────────────────────────────────────────
echo "[1/4] Setting up SSH tunnel key..."

SSH_DIR="/root/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ -z "${TUNNEL_KEY_B64:-}" ]; then
    echo "  ✗ TUNNEL_KEY_B64 not set! Cannot establish tunnel."
    echo "    Set this in your RunPod pod template environment variables."
    echo "    Continuing without tunnel (VNC will only be accessible locally)..."
    TUNNEL_ENABLED=false
else
    echo "$TUNNEL_KEY_B64" | base64 -d > "$SSH_DIR/tunnel_key"
    chmod 600 "$SSH_DIR/tunnel_key"
    echo "  ✓ SSH key decoded"
    TUNNEL_ENABLED=true
fi

# Accept Hetzner's host key automatically (first connection)
# For production: bake the known host key into the Docker image
cat > "$SSH_DIR/config" << SSHCONF
Host hetzner-tunnel
    HostName ${HETZNER_HOST:-UNSET}
    Port ${HETZNER_SSH_PORT}
    User ${TUNNEL_USER}
    IdentityFile ${SSH_DIR}/tunnel_key
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    TCPKeepAlive yes
SSHCONF
chmod 600 "$SSH_DIR/config"

# ─── 2. Start VNC server ────────────────────────────────────────────────
echo "[2/4] Starting VNC server on ${VNC_DISPLAY} (port ${VNC_PORT})..."

# Kill any existing VNC session
vncserver -kill "${VNC_DISPLAY}" 2>/dev/null || true
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Start VNC with no password (Guacamole handles authentication)
# Adjust this to match your Descriptron Docker image's VNC setup
if command -v tigervncserver &>/dev/null; then
    tigervncserver "${VNC_DISPLAY}" \
        -geometry "${VNC_RESOLUTION}" \
        -depth 24 \
        -SecurityTypes None \
        -localhost no \
        --I-KNOW--THIS-IS-INSECURE 2>/dev/null || \
    tigervncserver "${VNC_DISPLAY}" \
        -geometry "${VNC_RESOLUTION}" \
        -depth 24 \
        -SecurityTypes None 2>/dev/null
elif command -v vncserver &>/dev/null; then
    # TightVNC or other
    export USER=root
    vncserver "${VNC_DISPLAY}" \
        -geometry "${VNC_RESOLUTION}" \
        -depth 24 2>/dev/null
else
    echo "  ✗ No VNC server found! Install tigervnc-standalone-server."
    echo "    apt-get install -y tigervnc-standalone-server"
fi

# Wait for VNC to be ready
for i in $(seq 1 15); do
    if nc -z localhost "${VNC_PORT}" 2>/dev/null; then
        echo "  ✓ VNC server ready on port ${VNC_PORT}"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "  ⚠ VNC server may not have started. Check manually."
    fi
    sleep 2
done

# ─── 3. Start reverse SSH tunnel ────────────────────────────────────────
if [ "$TUNNEL_ENABLED" = true ] && [ "${HETZNER_HOST:-UNSET}" != "UNSET" ]; then
    echo "[3/4] Starting reverse SSH tunnel..."
    echo "  Local VNC ${VNC_PORT} → Hetzner localhost:${TUNNEL_PORT}"
    
    # Install autossh if not present
    if ! command -v autossh &>/dev/null; then
        echo "  Installing autossh..."
        apt-get update -qq && apt-get install -y -qq autossh 2>/dev/null || {
            echo "  ⚠ Could not install autossh, falling back to ssh loop"
        }
    fi
    
    if command -v autossh &>/dev/null; then
        # autossh: automatic reconnection with monitoring
        # AUTOSSH_GATETIME=0: don't give up on first connection failure
        # AUTOSSH_POLL=30: check connection every 30 seconds
        export AUTOSSH_GATETIME=0
        export AUTOSSH_POLL=30
        export AUTOSSH_LOGFILE="/var/log/autossh-tunnel.log"
        
        autossh -M 0 -f -N \
            -o "ServerAliveInterval=30" \
            -o "ServerAliveCountMax=3" \
            -o "ExitOnForwardFailure=yes" \
            -o "StrictHostKeyChecking=accept-new" \
            -R "127.0.0.1:${TUNNEL_PORT}:127.0.0.1:${VNC_PORT}" \
            -i "$SSH_DIR/tunnel_key" \
            -p "${HETZNER_SSH_PORT}" \
            "${TUNNEL_USER}@${HETZNER_HOST}"
        
        # Verify tunnel is established
        sleep 3
        if pgrep -f "autossh.*${TUNNEL_PORT}" > /dev/null; then
            echo "  ✓ autossh tunnel active (PID: $(pgrep -f "autossh.*${TUNNEL_PORT}"))"
        else
            echo "  ⚠ autossh may have failed. Check /var/log/autossh-tunnel.log"
            echo "  Attempting manual SSH tunnel..."
            ssh -f -N \
                -o "ServerAliveInterval=30" \
                -o "ServerAliveCountMax=3" \
                -o "StrictHostKeyChecking=accept-new" \
                -R "127.0.0.1:${TUNNEL_PORT}:127.0.0.1:${VNC_PORT}" \
                -i "$SSH_DIR/tunnel_key" \
                -p "${HETZNER_SSH_PORT}" \
                "${TUNNEL_USER}@${HETZNER_HOST}" && \
                echo "  ✓ SSH tunnel started (fallback)" || \
                echo "  ✗ SSH tunnel FAILED. Check network/keys."
        fi
    else
        # Fallback: plain ssh in a reconnection loop (background)
        (while true; do
            ssh -N \
                -o "ServerAliveInterval=30" \
                -o "ServerAliveCountMax=3" \
                -o "StrictHostKeyChecking=accept-new" \
                -R "127.0.0.1:${TUNNEL_PORT}:127.0.0.1:${VNC_PORT}" \
                -i "$SSH_DIR/tunnel_key" \
                -p "${HETZNER_SSH_PORT}" \
                "${TUNNEL_USER}@${HETZNER_HOST}"
            echo "  [$(date)] Tunnel disconnected, reconnecting in 10s..."
            sleep 10
        done) &
        echo "  ✓ SSH tunnel loop started (PID: $!)"
    fi
else
    echo "[3/4] Skipping tunnel (TUNNEL_KEY_B64 or HETZNER_HOST not set)"
fi

# ─── 4. Start Descriptron / keep container alive ────────────────────────
echo "[4/4] Descriptron environment ready."
echo ""
echo "  VNC:    localhost:${VNC_PORT}"
echo "  Tunnel: → Hetzner:${TUNNEL_PORT:-none}"
echo "  Envs:   conda activate samm|gpt4|detectron2_env|measure_env|metric3d"
echo ""
echo "═══════════════════════════════════════════════════"

# If there's an existing entrypoint, call it
if [ -f "/opt/descriptron-start.sh" ]; then
    exec /opt/descriptron-start.sh
fi

# Otherwise keep the container alive
# (RunPod requires the main process to stay running)
exec sleep infinity
