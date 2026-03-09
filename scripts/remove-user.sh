#!/bin/bash
###############################################################################
# Remove a Descriptron user from Guacamole
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source .env

USERNAME="${1:-}"
if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

echo "Removing user: ${USERNAME}..."

# Stop any active pod via orchestrator
curl -s -X POST "http://localhost:5000/api/sessions/stop" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"${USERNAME}\", \"terminate\": true}" 2>/dev/null || true

# Remove from Guacamole database
docker exec -i guac-db psql -U guacamole_user -d guacamole_db <<SQL 2>/dev/null || true
DELETE FROM guacamole_connection_permission WHERE entity_id IN
    (SELECT entity_id FROM guacamole_entity WHERE name='${USERNAME}' AND type='USER');
DELETE FROM guacamole_user_permission WHERE entity_id IN
    (SELECT entity_id FROM guacamole_entity WHERE name='${USERNAME}' AND type='USER');
DELETE FROM guacamole_user WHERE entity_id IN
    (SELECT entity_id FROM guacamole_entity WHERE name='${USERNAME}' AND type='USER');
DELETE FROM guacamole_entity WHERE name='${USERNAME}' AND type='USER';
DELETE FROM guacamole_connection_parameter WHERE connection_id IN
    (SELECT connection_id FROM guacamole_connection WHERE connection_name LIKE '%${USERNAME}%');
DELETE FROM guacamole_connection WHERE connection_name LIKE '%${USERNAME}%';
SQL

echo "✅ User ${USERNAME} removed."
