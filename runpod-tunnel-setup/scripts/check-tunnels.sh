#!/bin/bash
###############################################################################
# Diagnostic: Check status of all SSH tunnels on Hetzner
#
# Usage:
#   ./scripts/check-tunnels.sh
###############################################################################

echo "═══════════════════════════════════════════════════"
echo "  Descriptron Portal: Tunnel Status"
echo "  $(date)"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── 1. Check listening tunnel ports ────────────────────────────────────
echo "Listening tunnel ports (159xx range):"
FOUND=0
for port in $(seq 15901 15920); do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
        echo "  ✓ :${port} — listening (PID: ${pid:-unknown})"
        FOUND=$((FOUND+1))
    fi
done
if [ "$FOUND" -eq 0 ]; then
    echo "  ✗ No tunnel ports listening in range 15901-15920"
    echo "    → RunPod pods may not have connected yet"
fi
echo ""

# ─── 2. Check SSH processes from tunnel user ────────────────────────────
echo "Active SSH tunnel processes:"
PROCS=$(ps aux 2>/dev/null | grep "descriptron-tunnel" | grep -v grep || true)
if [ -n "$PROCS" ]; then
    echo "$PROCS" | while read line; do
        echo "  $line"
    done
else
    echo "  (none found)"
fi
echo ""

# ─── 3. Check Guacamole connections ─────────────────────────────────────
echo "Guacamole VNC connections:"
if docker exec guac-db psql -U guacamole_user -d guacamole_db -t -A 2>/dev/null <<SQL
SELECT c.connection_name || ' → ' || 
       (SELECT parameter_value FROM guacamole_connection_parameter WHERE connection_id = c.connection_id AND parameter_name = 'hostname') || ':' ||
       (SELECT parameter_value FROM guacamole_connection_parameter WHERE connection_id = c.connection_id AND parameter_name = 'port')
FROM guacamole_connection c
WHERE c.protocol = 'vnc'
ORDER BY c.connection_name;
SQL
then
    true
else
    echo "  (could not query Guacamole database)"
fi
echo ""

# ─── 4. Quick connectivity test ─────────────────────────────────────────
echo "VNC connectivity test:"
for port in $(seq 15901 15920); do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        if nc -z -w2 localhost "$port" 2>/dev/null; then
            echo "  ✓ localhost:${port} — VNC reachable"
        else
            echo "  ✗ localhost:${port} — port open but VNC not responding"
        fi
    fi
done
echo ""

# ─── 5. Guacamole stack health ──────────────────────────────────────────
echo "Guacamole stack:"
for svc in guac-db guac-daemon guac-web guac-proxy; do
    status=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [ "$status" = "running" ]; then
        echo "  ✓ ${svc}: running"
    else
        echo "  ✗ ${svc}: ${status}"
    fi
done
echo ""
echo "═══════════════════════════════════════════════════"
