# Descriptron Portal: RunPod ↔ Hetzner SSH Tunnel Setup

## Problem

The Descriptron Portal architecture expects Guacamole's `guacd` daemon to reach each user's VNC port (5901) via Docker networking. When user containers run on **RunPod** instead of locally on Hetzner, `guacd` cannot reach them — the connection hangs silently.

## Solution

Each RunPod pod establishes a **reverse SSH tunnel** back to the Hetzner server on boot. This maps the pod's local VNC port to a localhost port on Hetzner. Guacamole then connects to `localhost:<mapped_port>` as if the VNC server were running locally.

```
RunPod Pod (e.g. RTX A4000)              Hetzner Server (GEX44)
┌──────────────────────────┐              ┌──────────────────────────────┐
│                          │   reverse    │                              │
│  VNC server on :5901     │══ SSH ══════>│  localhost:15901             │
│  autossh (keeps alive)   │   tunnel     │  sshd (tunnel-user, no shell│
│                          │              │                              │
│  Descriptron conda envs  │              │  guacd ──> localhost:15901   │
│  GPU (RTX A4000/3090)    │              │  Guacamole ──> guacd         │
│                          │              │  Nginx ──> Guacamole         │
└──────────────────────────┘              │  Browser <── Nginx :443      │
                                          └──────────────────────────────┘
```

### Port mapping convention

| User # | Username  | RunPod VNC | Hetzner tunnel port |
|--------|-----------|-----------|---------------------|
| 1      | alice     | 5901      | 15901               |
| 2      | bob       | 5901      | 15902               |
| 3      | carol     | 5901      | 15903               |

Each user gets a unique tunnel port on Hetzner: `15900 + user_number`.

## Setup Steps

### Step 1: Generate SSH key pair (run once on Hetzner)

```bash
./scripts/setup-tunnel-keys.sh
```

This creates:
- `/root/.descriptron-tunnel/tunnel_key` (private key — goes into RunPod pods)
- `/root/.descriptron-tunnel/tunnel_key.pub` (public key — stays on Hetzner)
- A restricted `descriptron-tunnel` user on Hetzner that can ONLY create tunnels (no shell, no commands)

### Step 2: Patch docker-compose.yml (run once on Hetzner)

```bash
./scripts/patch-docker-compose.sh
docker compose down && docker compose up -d
```

This adds `extra_hosts: ["host.docker.internal:host-gateway"]` to the `guacd` service so it can reach the SSH tunnel ports on the host machine. Without this, guacd (inside Docker) cannot see `localhost` on the host where tunnels terminate.

### Step 3: Add the private key to your RunPod template

In your RunPod template's **Docker command** or **environment variables**, set:

```
TUNNEL_KEY=<base64-encoded private key>
TUNNEL_HOST=<your-hetzner-IP-or-domain>
TUNNEL_PORT=15901
```

Or paste the key content into RunPod's "secrets" if available.

### Step 4: Add tunnel startup to your Descriptron Docker image

Add to your Dockerfile (or the container's startup script):

```bash
# Install autossh
apt-get update && apt-get install -y autossh openssh-client

# Copy the startup wrapper
COPY scripts/runpod-entrypoint.sh /opt/runpod-entrypoint.sh
RUN chmod +x /opt/runpod-entrypoint.sh
```

### Step 5: Register user with tunnel port

```bash
./scripts/add-user-runpod.sh alice "Alice Smith" alice@example.com 15901
```

This registers the Guacamole connection pointing to `localhost:15901` instead of a container name.

### Step 6: Start RunPod pod

Start the pod with environment variables:

```
TUNNEL_KEY_B64=<base64 of private key>
HETZNER_HOST=descriptron.your-domain.com
TUNNEL_PORT=15901
VNC_PORT=5901
```

The pod's entrypoint script will:
1. Decode the SSH key
2. Start VNC server
3. Start autossh reverse tunnel
4. Keep reconnecting if the connection drops

## Files in this package

| File | Where to use | Purpose |
|------|-------------|---------|
| `scripts/setup-tunnel-keys.sh` | Run on Hetzner (once) | Creates SSH keys + tunnel user |
| `scripts/patch-docker-compose.sh` | Run on Hetzner (once) | Adds host-gateway so guacd can reach tunnel ports |
| `scripts/runpod-entrypoint.sh` | Bake into RunPod Docker image | Starts VNC + tunnel on pod boot |
| `scripts/add-user-runpod.sh` | Run on Hetzner (per user) | Registers Guacamole connection via host.docker.internal tunnel |
| `scripts/check-tunnels.sh` | Run on Hetzner (diagnostic) | Shows status of all active tunnels |

## Troubleshooting

**Guacamole still hangs after setup:**
- On Hetzner: `ss -tlnp | grep 159` — do you see the tunnel port listening?
- If not, the tunnel hasn't connected. Check RunPod logs for SSH errors.
- Common cause: Hetzner firewall blocking SSH from RunPod. Ensure port 22 (or your custom SSH port) is open for inbound connections.

**Tunnel connects but disconnects:**
- autossh handles reconnection automatically, but RunPod's "stop" events kill the process
- If the pod restarts, the tunnel re-establishes within ~30 seconds

**"Host key verification failed":**
- The entrypoint script uses `StrictHostKeyChecking=no` for the first connection
- For production, bake Hetzner's host key into the Docker image

**Multiple users on one RunPod pod:**
- Not recommended. Each user should get their own pod for isolation.
- If needed, run multiple VNC servers (5901, 5902) and multiple tunnels.

**FileBrowser can't see RunPod files:**
- FileBrowser runs on Hetzner and mounts local volumes
- For RunPod file access: users should use `scp` or the Guacamole drive feature
- Alternative: add an rsync cron job in the RunPod entrypoint
