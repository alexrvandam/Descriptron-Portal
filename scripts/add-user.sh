#!/bin/bash
###############################################################################
# Add a Descriptron user
#
# Creates a Guacamole account. GPU pods are created on-demand when the
# user clicks "Start Session" in the dashboard.
#
# Usage:
#   ./scripts/add-user.sh <username> [full_name] [email]
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source .env

USERNAME="${1:-}"
FULL_NAME="${2:-${USERNAME}}"
EMAIL="${3:-}"

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username> [full_name] [email]"
    echo "Example: $0 francisco 'Francisco Hita Garcia' fhg@example.com"
    exit 1
fi

if ! [[ "$USERNAME" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "ERROR: Username must be lowercase letters, numbers, underscores."
    exit 1
fi

TEMP_PASSWORD=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 12)

echo "Creating Guacamole account for: ${USERNAME}..."

# Hash password (Guacamole SHA-256)
SALT=$(openssl rand -hex 32)
PASSWORD_HASH=$(printf '%s%s' "$TEMP_PASSWORD" "$(echo -n "$SALT" | xxd -r -p)" \
    | openssl dgst -sha256 -binary | xxd -p -c 256)

docker exec -i guac-db psql -U guacamole_user -d guacamole_db <<SQL

-- Create entity
INSERT INTO guacamole_entity (name, type) VALUES ('${USERNAME}', 'USER')
ON CONFLICT DO NOTHING;

-- Create user
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date,
                            full_name, email_address, disabled, expired)
SELECT entity_id,
       decode('${PASSWORD_HASH}', 'hex'),
       decode('${SALT}', 'hex'),
       now(),
       '${FULL_NAME}',
       '${EMAIL}',
       false,
       true  -- Force password change on first login
FROM guacamole_entity WHERE name = '${USERNAME}' AND type = 'USER'
ON CONFLICT DO NOTHING;

-- Self-read permission
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
SELECT e.entity_id, u.user_id, perm.p
FROM guacamole_entity e
JOIN guacamole_user u ON u.entity_id = e.entity_id,
     (VALUES ('READ'), ('UPDATE')) AS perm(p)
WHERE e.name = '${USERNAME}' AND e.type = 'USER'
ON CONFLICT DO NOTHING;

SQL

echo ""
echo "=============================================="
echo "  ✅ User created: ${USERNAME}"
echo "=============================================="
echo ""
echo "  Send this to the user:"
echo "  ──────────────────────────────────────────"
echo "  Welcome to the Descriptron Portal!"
echo ""
echo "  Dashboard: https://${DOMAIN}/dashboard?user=${USERNAME}"
echo "  Desktop:   https://${DOMAIN}/guacamole/"
echo ""
echo "  Guacamole login:"
echo "    Username: ${USERNAME}"
echo "    Password: ${TEMP_PASSWORD}"
echo "    (you'll be asked to change it on first login)"
echo ""
echo "  How to use:"
echo "    1. Go to the Dashboard link above"
echo "    2. Click 'Start GPU Session' (takes 2-5 min)"
echo "    3. Once ready, click 'Open Desktop' or log into"
echo "       Guacamole to access your Descriptron workspace"
echo "    4. Stop your session when done to save costs"
echo "  ──────────────────────────────────────────"
echo ""
