#!/bin/bash
###############################################################################
# Setup SSH tunnel keys and restricted user on Hetzner
#
# Run this ONCE on your Hetzner server. It creates:
#   - An SSH key pair for tunnel authentication
#   - A restricted 'descriptron-tunnel' system user (no shell, tunnel only)
#
# Usage:
#   sudo ./scripts/setup-tunnel-keys.sh
###############################################################################
set -euo pipefail

TUNNEL_USER="descriptron-tunnel"
KEY_DIR="/root/.descriptron-tunnel"
SSH_PORT="${1:-22}"  # Pass custom SSH port as argument if needed

echo "═══════════════════════════════════════════════════"
echo "  Descriptron Portal: SSH Tunnel Key Setup"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── 1. Create tunnel key directory ─────────────────────────────────────
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# ─── 2. Generate SSH key pair ────────────────────────────────────────────
if [ -f "$KEY_DIR/tunnel_key" ]; then
    echo "⚠  Key pair already exists at $KEY_DIR/tunnel_key"
    echo "   Delete it first if you want to regenerate."
    echo ""
else
    echo "[1/4] Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$KEY_DIR/tunnel_key" -N "" -C "descriptron-tunnel-$(date +%Y%m%d)"
    chmod 600 "$KEY_DIR/tunnel_key"
    chmod 644 "$KEY_DIR/tunnel_key.pub"
    echo "  ✓ Private key: $KEY_DIR/tunnel_key"
    echo "  ✓ Public key:  $KEY_DIR/tunnel_key.pub"
    echo ""
fi

# ─── 3. Create restricted system user ───────────────────────────────────
echo "[2/4] Creating restricted tunnel user: $TUNNEL_USER"

if id "$TUNNEL_USER" &>/dev/null; then
    echo "  ⚠  User '$TUNNEL_USER' already exists, updating config..."
else
    # Create user with no shell, no home, no login
    useradd -r -s /usr/sbin/nologin -d /nonexistent -M "$TUNNEL_USER" 2>/dev/null || true
    echo "  ✓ System user created"
fi

# ─── 4. Configure authorized_keys with tunnel-only restriction ──────────
echo "[3/4] Configuring authorized_keys..."

TUNNEL_SSH_DIR="/etc/ssh/tunnel-keys"
mkdir -p "$TUNNEL_SSH_DIR"

# The key restriction prevents any commands — only port forwarding allowed
PUBKEY=$(cat "$KEY_DIR/tunnel_key.pub")
echo "restrict,port-forwarding,command=\"/bin/false\" $PUBKEY" > "$TUNNEL_SSH_DIR/authorized_keys"
chmod 644 "$TUNNEL_SSH_DIR/authorized_keys"
chown root:root "$TUNNEL_SSH_DIR/authorized_keys"

echo "  ✓ Authorized key installed with tunnel-only restriction"

# ─── 5. Configure sshd to allow this user ───────────────────────────────
echo "[4/4] Updating sshd configuration..."

SSHD_CONF="/etc/ssh/sshd_config"
MATCH_BLOCK="# Descriptron tunnel user - allow only port forwarding
Match User $TUNNEL_USER
    AuthorizedKeysFile $TUNNEL_SSH_DIR/authorized_keys
    AllowTcpForwarding remote
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /bin/false
    GatewayPorts no"

# Check if match block already exists
if grep -q "Match User $TUNNEL_USER" "$SSHD_CONF"; then
    echo "  ⚠  sshd Match block already exists, skipping"
else
    echo "" >> "$SSHD_CONF"
    echo "$MATCH_BLOCK" >> "$SSHD_CONF"
    echo "  ✓ sshd config updated"
    
    # Validate config before reloading
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
        echo "  ✓ sshd reloaded"
    else
        echo "  ✗ sshd config validation failed! Check $SSHD_CONF manually."
        exit 1
    fi
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Setup Complete"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Private key (put this in RunPod):"
echo "  $KEY_DIR/tunnel_key"
echo ""
echo "Base64-encoded key (for RunPod environment variable):"
base64 -w0 "$KEY_DIR/tunnel_key"
echo ""
echo ""
echo "Copy the base64 string above and set it as TUNNEL_KEY_B64"
echo "in your RunPod pod template environment variables."
echo ""
echo "Your Hetzner server's SSH port: $SSH_PORT"
echo "Your Hetzner server's IP: $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
echo "Next step: Add the tunnel entrypoint to your Descriptron Docker image"
echo "  See: scripts/runpod-entrypoint.sh"
