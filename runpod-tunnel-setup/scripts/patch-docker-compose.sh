#!/bin/bash
###############################################################################
# Patch docker-compose.yml for RunPod tunnel support
#
# The critical issue: guacd runs INSIDE a Docker container, so when the
# Guacamole connection says hostname=localhost, guacd looks at its OWN
# localhost — not the host machine where the SSH tunnel terminates.
#
# Fix: Add the host machine's IP as 'host-gateway' so guacd can reach
# the tunnel ports on the actual host.
#
# Usage:
#   ./scripts/patch-docker-compose.sh
#
# Then update Guacamole connections to use 'host.docker.internal'
# instead of 'localhost' as the VNC hostname.
###############################################################################
set -euo pipefail

COMPOSE_FILE="${1:-docker-compose.yml}"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: $COMPOSE_FILE not found"
    exit 1
fi

echo "Patching $COMPOSE_FILE for RunPod tunnel support..."
echo ""

# Check if already patched
if grep -q "host.docker.internal" "$COMPOSE_FILE"; then
    echo "Already patched! (host.docker.internal found)"
    exit 0
fi

# Backup
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"

# Add extra_hosts to guacd service so it can resolve host.docker.internal
# This maps to the Docker host's IP via the special 'host-gateway' value
python3 << 'PYEOF'
import re

with open("docker-compose.yml") as f:
    content = f.read()

# Find the guacd service block and add extra_hosts after the image line
# We need guacd to be able to reach the host's localhost where tunnels terminate
old_guacd = """  guacd:
    image: guacamole/guacd:1.5.5
    container_name: guac-daemon
    restart: unless-stopped
    networks:
      - guac-internal
      - descriptron-net"""

new_guacd = """  guacd:
    image: guacamole/guacd:1.5.5
    container_name: guac-daemon
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - guac-internal
      - descriptron-net"""

if old_guacd in content:
    content = content.replace(old_guacd, new_guacd)
    with open("docker-compose.yml", "w") as f:
        f.write(content)
    print("  ✓ Added extra_hosts to guacd service")
else:
    print("  ⚠ Could not find exact guacd block to patch.")
    print("    Manually add this under the guacd service:")
    print("    extra_hosts:")
    print('      - "host.docker.internal:host-gateway"')
PYEOF

echo ""
echo "IMPORTANT: When registering RunPod users, the Guacamole VNC connection"
echo "hostname must be 'host.docker.internal' (not 'localhost'), because"
echo "guacd runs inside a Docker container."
echo ""
echo "The add-user-runpod.sh script handles this automatically."
echo ""
echo "After patching, restart the stack:"
echo "  docker compose down && docker compose up -d"
