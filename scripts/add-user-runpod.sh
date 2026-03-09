#!/bin/bash
###############################################################################
# Register a RunPod-based Descriptron user in Guacamole
#
# Unlike the local add-user.sh, this does NOT create a Docker container.
# Instead it registers a Guacamole connection pointing to localhost:<tunnel_port>
# where the reverse SSH tunnel from RunPod terminates.
#
# Usage:
#   ./scripts/add-user-runpod.sh <username> "<full_name>" <email> <tunnel_port>
#
# Example:
#   ./scripts/add-user-runpod.sh francisco "Francisco Hita Garcia" fhg@mfn.berlin 15901
#
# Prerequisites:
#   - Guacamole stack running (docker compose up -d)
#   - Tunnel keys set up (./scripts/setup-tunnel-keys.sh)
#   - RunPod pod started with matching TUNNEL_PORT
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

source .env 2>/dev/null || true
DOMAIN="${DOMAIN:-localhost}"

USERNAME="${1:-}"
FULL_NAME="${2:-}"
EMAIL="${3:-}"
TUNNEL_PORT="${4:-}"

if [ -z "$USERNAME" ] || [ -z "$FULL_NAME" ] || [ -z "$EMAIL" ] || [ -z "$TUNNEL_PORT" ]; then
    echo "Usage: $0 <username> \"<full_name>\" <email> <tunnel_port>"
    echo ""
    echo "Example:"
    echo "  $0 francisco \"Francisco Hita Garcia\" fhg@mfn.berlin 15901"
    echo ""
    echo "Port convention: 15901 for user 1, 15902 for user 2, etc."
    exit 1
fi

# Generate temporary password
TEMP_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)

echo "═══════════════════════════════════════════════════"
echo "  Adding RunPod user: ${USERNAME}"
echo "  Tunnel port: localhost:${TUNNEL_PORT}"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── 1. Check tunnel is active ──────────────────────────────────────────
echo "[1/3] Checking tunnel status..."

if ss -tlnp 2>/dev/null | grep -q ":${TUNNEL_PORT} " || \
   netstat -tlnp 2>/dev/null | grep -q ":${TUNNEL_PORT} "; then
    echo "  ✓ Port ${TUNNEL_PORT} is listening (tunnel active)"
else
    echo "  ⚠ Port ${TUNNEL_PORT} is NOT listening yet."
    echo "    Make sure the RunPod pod is running with TUNNEL_PORT=${TUNNEL_PORT}"
    echo "    Continuing with registration anyway (tunnel can connect later)..."
fi

# ─── 2. Register in Guacamole database ──────────────────────────────────
echo "[2/3] Creating Guacamole account..."

# Hash password for Guacamole (SHA-256 with salt)
SALT=$(openssl rand -hex 32)
PASSWORD_HASH=$(printf '%s%s' "$TEMP_PASSWORD" "$(echo -n "$SALT" | xxd -r -p)" \
    | openssl dgst -sha256 -binary | xxd -p -c 256)

docker exec -i guac-db psql -U guacamole_user -d guacamole_db <<SQL

-- Remove existing connection for this user (if re-registering)
DELETE FROM guacamole_connection_parameter
WHERE connection_id IN (
    SELECT connection_id FROM guacamole_connection
    WHERE connection_name = '${FULL_NAME} - Descriptron Desktop'
);
DELETE FROM guacamole_connection
WHERE connection_name = '${FULL_NAME} - Descriptron Desktop';

-- Create VNC connection pointing to LOCALHOST tunnel port
INSERT INTO guacamole_connection (connection_name, protocol)
VALUES ('${FULL_NAME} - Descriptron Desktop', 'vnc');

-- Configure VNC parameters
-- KEY: hostname is 'host.docker.internal' because guacd runs inside Docker
-- and needs to reach the HOST's localhost where the SSH tunnel terminates.
-- This requires extra_hosts in docker-compose.yml (see patch-docker-compose.sh)
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, param.name, param.value
FROM guacamole_connection,
     (VALUES
         ('hostname', 'host.docker.internal'),
         ('port', '${TUNNEL_PORT}'),
         ('password', ''),
         ('color-depth', '24'),
         ('cursor', 'local'),
         ('clipboard-encoding', 'UTF-8'),
         ('resize-method', 'display-update'),
         ('enable-audio', 'false'),
         ('enable-printing', 'false'),
         ('enable-drive', 'true'),
         ('drive-path', '/workspace/results'),
         ('drive-name', 'My Files'),
         ('create-drive-path', 'true')
     ) AS param(name, value)
WHERE connection_name = '${FULL_NAME} - Descriptron Desktop';

-- Create user account (skip if exists)
INSERT INTO guacamole_entity (name, type)
VALUES ('${USERNAME}', 'USER')
ON CONFLICT DO NOTHING;

-- Update or insert user record
DELETE FROM guacamole_user
WHERE entity_id = (SELECT entity_id FROM guacamole_entity WHERE name = '${USERNAME}' AND type = 'USER');

INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date,
                            full_name, email_address, disabled, expired)
SELECT entity_id,
       decode('${PASSWORD_HASH}', 'hex'),
       decode('${SALT}', 'hex'),
       now(),
       '${FULL_NAME}',
       '${EMAIL}',
       false,
       true
FROM guacamole_entity WHERE name = '${USERNAME}' AND type = 'USER';

-- Grant connection permission
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, 'READ'
FROM guacamole_entity e, guacamole_connection c
WHERE e.name = '${USERNAME}' AND e.type = 'USER'
  AND c.connection_name = '${FULL_NAME} - Descriptron Desktop'
ON CONFLICT DO NOTHING;

-- Grant self-read permission
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
SELECT e.entity_id, u.user_id, 'READ'
FROM guacamole_entity e
JOIN guacamole_user u ON u.entity_id = e.entity_id
WHERE e.name = '${USERNAME}' AND e.type = 'USER'
ON CONFLICT DO NOTHING;

-- Grant self-update (password change)
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
SELECT e.entity_id, u.user_id, 'UPDATE'
FROM guacamole_entity e
JOIN guacamole_user u ON u.entity_id = e.entity_id
WHERE e.name = '${USERNAME}' AND e.type = 'USER'
ON CONFLICT DO NOTHING;

SQL

echo "  ✓ Guacamole account created"

# ─── 3. Summary ─────────────────────────────────────────────────────────
echo "[3/3] Done!"
echo ""
echo "═══════════════════════════════════════════════════"
echo "  User registered successfully"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Username:        ${USERNAME}"
echo "  Temp password:   ${TEMP_PASSWORD}"
echo "  Tunnel port:     localhost:${TUNNEL_PORT}"
echo ""
echo "  Login URL:       https://${DOMAIN}/"
echo ""
echo "  The user will be asked to change their password"
echo "  on first login."
echo ""
echo "  IMPORTANT: Make sure the RunPod pod is running with:"
echo "    TUNNEL_PORT=${TUNNEL_PORT}"
echo "    HETZNER_HOST=$(curl -s ifconfig.me 2>/dev/null || echo '<your-hetzner-ip>')"
echo "    TUNNEL_KEY_B64=<from setup-tunnel-keys.sh output>"
echo ""
echo "  To verify the tunnel: ss -tlnp | grep ${TUNNEL_PORT}"
