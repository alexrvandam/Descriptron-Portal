"""
Descriptron Portal Orchestrator
================================
Manages RunPod GPU pod lifecycle and integrates with Guacamole.

Endpoints:
  GET  /api/status              - Portal health check
  GET  /api/sessions            - List all sessions (admin)
  POST /api/sessions/start      - Start a GPU session for a user
  POST /api/sessions/stop       - Stop a user's GPU session
  GET  /api/sessions/<user>     - Get session status for a user

The orchestrator:
  1. Creates RunPod pods with the Descriptron Docker image
  2. Waits for the pod to be ready and VNC to be accessible
  3. Registers a VNC connection in Guacamole's database
  4. Monitors pods and auto-terminates idle ones
"""

import os
import time
import json
import secrets
import hashlib
import logging
import threading
from datetime import datetime, timedelta, timezone
from functools import wraps

import runpod
import psycopg2
from psycopg2.extras import RealDictCursor
from flask import Flask, request, jsonify, render_template_string, session, redirect, url_for
from apscheduler.schedulers.background import BackgroundScheduler

# ─── Configuration ───────────────────────────────────────────────────────

RUNPOD_API_KEY = os.environ["RUNPOD_API_KEY"]
DESCRIPTRON_IMAGE = os.environ.get("DESCRIPTRON_IMAGE", "descriptron-portal:latest")
RUNPOD_GPU_TYPE = os.environ.get("RUNPOD_GPU_TYPE", "NVIDIA RTX A4000")
RUNPOD_GPU_FALLBACKS = os.environ.get("RUNPOD_GPU_FALLBACKS", "").strip()
GPU_FALLBACK_ORDER = [
    "NVIDIA RTX A4000",          # 16 GB, ~$0.26/hr
    "NVIDIA GeForce RTX 3090",   # 24 GB, ~$0.44/hr
    "NVIDIA RTX A5000",          # 24 GB, ~$0.50/hr
    "NVIDIA GeForce RTX 4090",   # 24 GB, ~$0.69/hr
    "NVIDIA RTX A6000",          # 48 GB, ~$0.79/hr
]


def get_gpu_candidates():
    if RUNPOD_GPU_FALLBACKS:
        return [g.strip() for g in RUNPOD_GPU_FALLBACKS.split("|") if g.strip()]
    return [RUNPOD_GPU_TYPE]


RUNPOD_NETWORK_VOLUME_ID = os.environ.get("RUNPOD_NETWORK_VOLUME_ID", "")
RUNPOD_DATACENTER_ID = os.environ.get("RUNPOD_DATACENTER_ID", "")
DOMAIN = os.environ.get("DOMAIN", "localhost")
SECRET_KEY = os.environ.get("SECRET_KEY", "change-me")
IDLE_TIMEOUT = int(os.environ.get("POD_IDLE_TIMEOUT_MINUTES", "120"))
CONTAINER_DISK_GB = int(os.environ.get("POD_CONTAINER_DISK_GB", "50"))
VOLUME_GB = int(os.environ.get("POD_VOLUME_GB", "20"))

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "postgres"),
    "dbname": os.environ.get("DB_NAME", "guacamole_db"),
    "user": os.environ.get("DB_USER", "guacamole_user"),
    "password": os.environ.get("DB_PASSWORD", ""),
}

# Initialize RunPod
runpod.api_key = RUNPOD_API_KEY

# ─── Logging ─────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("orchestrator")

# ─── Session Store ───────────────────────────────────────────────────────

DATA_DIR = "/app/data"
SESSIONS_FILE = os.path.join(DATA_DIR, "sessions.json")
sessions = {}  # username -> {pod_id, status, vnc_host, vnc_port, started_at, ...}
sessions_lock = threading.Lock()


def save_sessions():
    """Persist session state to disk."""
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(SESSIONS_FILE, "w") as f:
        json.dump(sessions, f, default=str, indent=2)


def load_sessions():
    """Load session state from disk."""
    global sessions
    if os.path.exists(SESSIONS_FILE):
        try:
            with open(SESSIONS_FILE) as f:
                sessions = json.load(f)
            log.info(f"Loaded {len(sessions)} sessions from disk")
        except Exception as e:
            log.warning(f"Failed to load sessions: {e}")


# ─── Database Helpers ────────────────────────────────────────────────────

def get_db():
    """Get a PostgreSQL connection."""
    return psycopg2.connect(**DB_CONFIG)


def verify_guacamole_password(username, password):
    """Check password by authenticating against Guacamole's REST API."""
    import urllib.request
    import urllib.parse
    try:
        data = urllib.parse.urlencode({
            'username': username,
            'password': password,
        }).encode('utf-8')
        req = urllib.request.Request(
            'http://guac-web:8080/guacamole/api/tokens',
            data=data,
            method='POST',
        )
        resp = urllib.request.urlopen(req, timeout=5)
        result = json.loads(resp.read())
        # If we get a token back, the credentials are valid
        if result.get('authToken'):
            # Delete the token immediately (we don't need it)
            try:
                delete_req = urllib.request.Request(
                    f'http://guac-web:8080/guacamole/api/tokens/{result["authToken"]}',
                    method='DELETE',
                )
                urllib.request.urlopen(delete_req, timeout=5)
            except Exception:
                pass
            return True
        return False
    except urllib.error.HTTPError:
        return False
    except Exception as e:
        log.error(f"Password verification error: {e}")
        return False


def register_vnc_connection(username, full_name, vnc_host, vnc_port):
    """
    Register a VNC connection in Guacamole's database for a user.
    If the connection already exists, update the host/port.
    """
    conn_name = f"{full_name} - Descriptron GPU Session"

    with get_db() as db:
        with db.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT connection_id FROM guacamole_connection WHERE connection_name = %s",
                (conn_name,),
            )
            existing = cur.fetchone()

            if existing:
                conn_id = existing["connection_id"]
                cur.execute(
                    "UPDATE guacamole_connection_parameter SET parameter_value = %s "
                    "WHERE connection_id = %s AND parameter_name = 'hostname'",
                    (vnc_host, conn_id),
                )
                cur.execute(
                    "UPDATE guacamole_connection_parameter SET parameter_value = %s "
                    "WHERE connection_id = %s AND parameter_name = 'port'",
                    (str(vnc_port), conn_id),
                )
                log.info(f"Updated VNC connection for {username}: {vnc_host}:{vnc_port}")
            else:
                cur.execute(
                    "INSERT INTO guacamole_connection (connection_name, protocol) "
                    "VALUES (%s, 'vnc') RETURNING connection_id",
                    (conn_name,),
                )
                conn_id = cur.fetchone()["connection_id"]

                params = {
                    "hostname": vnc_host,
                    "port": str(vnc_port),
                    "password": "",
                    "color-depth": "24",
                    "cursor": "local",
                    "clipboard-encoding": "UTF-8",
                    "resize-method": "display-update",
                    "enable-audio": "false",
                    "enable-drive": "true",
                    "drive-path": f"/workspace/{username}/results",
                    "drive-name": "Download Files",
                    "create-drive-path": "true",
                }
                for name, value in params.items():
                    cur.execute(
                        "INSERT INTO guacamole_connection_parameter "
                        "(connection_id, parameter_name, parameter_value) "
                        "VALUES (%s, %s, %s)",
                        (conn_id, name, value),
                    )

                cur.execute(
                    "SELECT entity_id FROM guacamole_entity "
                    "WHERE name = %s AND type = 'USER'",
                    (username,),
                )
                entity = cur.fetchone()
                if entity:
                    cur.execute(
                        "INSERT INTO guacamole_connection_permission "
                        "(entity_id, connection_id, permission) VALUES (%s, %s, 'READ') "
                        "ON CONFLICT DO NOTHING",
                        (entity["entity_id"], conn_id),
                    )

                log.info(f"Created VNC connection for {username}: {vnc_host}:{vnc_port}")

        db.commit()
    return conn_id


def remove_vnc_connection(username, full_name):
    """Remove the VNC connection from Guacamole."""
    conn_name = f"{full_name} - Descriptron GPU Session"
    with get_db() as db:
        with db.cursor() as cur:
            cur.execute(
                "SELECT connection_id FROM guacamole_connection "
                "WHERE connection_name = %s",
                (conn_name,),
            )
            row = cur.fetchone()
            if row:
                conn_id = row[0]
                cur.execute(
                    "DELETE FROM guacamole_connection_permission WHERE connection_id = %s",
                    (conn_id,),
                )
                cur.execute(
                    "DELETE FROM guacamole_connection_parameter WHERE connection_id = %s",
                    (conn_id,),
                )
                cur.execute(
                    "DELETE FROM guacamole_connection WHERE connection_id = %s",
                    (conn_id,),
                )
        db.commit()
    log.info(f"Removed VNC connection for {username}")


# ─── RunPod Pod Management ───────────────────────────────────────────────

def create_pod(username, full_name, upload_token=""):
    """
    Create a RunPod GPU pod for a user.
    Returns pod info dict on success.
    """
    pod_name = f"descriptron-{username}"
    env_vars = {
        "DESCRIPTRON_USER": username,
        "DESCRIPTRON_DISPLAY_NAME": full_name,
        "FILE_MANAGER_TOKEN": upload_token,
    }

    kwargs = {
        "name": pod_name,
        "image_name": DESCRIPTRON_IMAGE,
        "gpu_type_id": RUNPOD_GPU_TYPE,
        "cloud_type": "SECURE",
        "gpu_count": 1,
        "volume_in_gb": VOLUME_GB,
        "container_disk_in_gb": CONTAINER_DISK_GB,
        "min_vcpu_count": 4,
        "min_memory_in_gb": 16,
        "ports": "5901/tcp,6080/http,8888/tcp",
        "volume_mount_path": "/workspace",
        "env": env_vars,
        "docker_args": "",
    }

    if RUNPOD_NETWORK_VOLUME_ID:
        kwargs["network_volume_id"] = RUNPOD_NETWORK_VOLUME_ID

    if RUNPOD_DATACENTER_ID:
        kwargs["data_center_id"] = RUNPOD_DATACENTER_ID

    gpu_candidates = get_gpu_candidates()
    last_err = None

    for gpu in gpu_candidates:
        kwargs["gpu_type_id"] = gpu
        log.info(f"Creating RunPod pod for {username} with GPU {gpu}...")

        try:
            pod = runpod.create_pod(**kwargs)
            log.info(f"Pod created: {pod['id']} for {username} (GPU={gpu})")
            return pod

        except Exception as e:
            last_err = e
            msg = str(e)

            capacity_signals = [
                "there are no longer any instances available",
                "no longer any instances available",
                "requested specifications",
                "insufficient capacity",
                "no instances available",
            ]
            if any(sig in msg.lower() for sig in capacity_signals):
                log.warning(f"GPU {gpu} unavailable/capacity issue. Trying next GPU...")
                continue

            log.error(f"Failed to create pod for {username} (GPU={gpu}): {e}")
            raise

    raise RuntimeError(
        f"No RunPod GPUs available for requested list: {gpu_candidates} "
        f"(datacenter={RUNPOD_DATACENTER_ID}, volume={RUNPOD_NETWORK_VOLUME_ID})"
    ) from last_err


def wait_for_pod_ready(pod_id, timeout=300):
    """
    Wait for a RunPod pod to be RUNNING and return its VNC endpoint.
    Returns (vnc_host, vnc_port) or raises TimeoutError.
    """
    start = time.time()
    while time.time() - start < timeout:
        try:
            pod = runpod.get_pod(pod_id)
            status = pod.get("desiredStatus", "UNKNOWN")
            runtime = pod.get("runtime", {})

            if status == "RUNNING" and runtime:
                ports = runtime.get("ports", [])
                for port_info in ports:
                    if port_info.get("privatePort") == 5901:
                        vnc_host = port_info.get("ip", "")
                        vnc_port = port_info.get("publicPort", 0)
                        if vnc_host and vnc_port:
                            time.sleep(10)
                            return vnc_host, vnc_port

            if status in ("EXITED", "ERROR", "TERMINATED"):
                raise RuntimeError(f"Pod {pod_id} entered state: {status}")

        except Exception as e:
            if "not found" in str(e).lower():
                raise
            log.debug(f"Waiting for pod {pod_id}: {e}")

        time.sleep(10)

    raise TimeoutError(f"Pod {pod_id} did not become ready within {timeout}s")


def stop_pod(pod_id):
    """Stop (not terminate) a RunPod pod — can be resumed later."""
    try:
        runpod.stop_pod(pod_id)
        log.info(f"Stopped pod {pod_id}")
    except Exception as e:
        log.error(f"Failed to stop pod {pod_id}: {e}")


def terminate_pod(pod_id):
    """Permanently terminate a RunPod pod."""
    try:
        runpod.terminate_pod(pod_id)
        log.info(f"Terminated pod {pod_id}")
    except Exception as e:
        log.error(f"Failed to terminate pod {pod_id}: {e}")


# ─── Flask App ───────────────────────────────────────────────────────────

app = Flask(__name__)
app.secret_key = SECRET_KEY
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=12)


def login_required(f):
    """Decorator to require authentication."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'username' not in session:
            return redirect('/login')
        return f(*args, **kwargs)
    return decorated


# ─── Login / Logout ─────────────────────────────────────────────────────

LOGIN_HTML = """
<!DOCTYPE html>
<html>
<head>
    <title>Descriptron Portal — Login</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
               background: #0f172a; color: #e2e8f0; min-height: 100vh;
               display: flex; flex-direction: column; align-items: center; justify-content: center; }
        .login-card { background: #1e293b; border: 1px solid #334155; border-radius: 12px;
                     padding: 2.5rem; width: 100%; max-width: 400px; }
        .login-card h1 { font-size: 1.5rem; margin-bottom: 0.5rem; color: #f1f5f9; }
        .login-card p { color: #94a3b8; margin-bottom: 1.5rem; font-size: 0.9rem; }
        label { display: block; color: #94a3b8; font-size: 0.8rem; margin-bottom: 0.25rem;
                text-transform: uppercase; letter-spacing: 0.05em; }
        input { width: 100%; padding: 0.75rem; border-radius: 8px; border: 1px solid #334155;
                background: #0f172a; color: #e2e8f0; font-size: 1rem; margin-bottom: 1rem; }
        input:focus { outline: none; border-color: #2563eb; }
        button { width: 100%; padding: 0.75rem; border-radius: 8px; border: none;
                background: #2563eb; color: white; font-size: 1rem; font-weight: 500;
                cursor: pointer; transition: background 0.2s; }
        button:hover { background: #1d4ed8; }
        .error { background: #7f1d1d; border: 1px solid #991b1b; color: #fca5a5;
                padding: 0.75rem; border-radius: 8px; margin-bottom: 1rem; font-size: 0.9rem; }
        .footer { margin-top: 2rem; color: #475569; font-size: 0.8rem; }
    </style>
</head>
<body>
    <div class="login-card">
        <h1>🔬 Descriptron Portal</h1>
        <p>Sign in with your Descriptron account</p>
        {% if error %}<div class="error">{{ error }}</div>{% endif %}
        <form method="POST" action="/login">
            <label>Username</label>
            <input type="text" name="username" required autofocus>
            <label>Password</label>
            <input type="password" name="password" required>
            <button type="submit">Sign In</button>
        </form>
    </div>
    <div class="footer">Museum für Naturkunde Berlin</div>
</body>
</html>
"""


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        if 'username' in session:
            return redirect('/dashboard')
        return render_template_string(LOGIN_HTML, error=None)

    username = request.form.get("username", "").strip().lower()
    password = request.form.get("password", "")

    if not username or not password:
        return render_template_string(LOGIN_HTML, error="Please enter username and password.")

    if verify_guacamole_password(username, password):
        session['username'] = username
        session.permanent = True
        return redirect('/dashboard')
    else:
        return render_template_string(LOGIN_HTML, error="Invalid username or password.")


@app.route("/logout")
def logout():
    session.pop('username', None)
    return redirect('/login')


@app.route("/")
def index():
    return redirect('/dashboard')


# ─── API Endpoints ───────────────────────────────────────────────────────

@app.route("/api/status")
def api_status():
    """Health check."""
    return jsonify({
        "status": "ok",
        "active_sessions": len([s for s in sessions.values() if s.get("status") == "running"]),
        "gpu_type": RUNPOD_GPU_TYPE,
        "gpu_fallbacks": get_gpu_candidates(),
        "image": DESCRIPTRON_IMAGE,
    })


@app.route("/api/sessions")
def api_sessions():
    """List all sessions (for admin dashboard)."""
    auth = request.headers.get("X-Admin-Key", "")
    if auth != SECRET_KEY:
        return jsonify({"error": "unauthorized"}), 401
    return jsonify(sessions)


@app.route("/api/sessions/<username>")
def api_session_status(username):
    """Get session status for a specific user."""
    # Only allow users to see their own session
    if 'username' not in session or session['username'] != username:
        return jsonify({"error": "unauthorized"}), 401

    user_session = sessions.get(username, {})
    return jsonify({
        "username": username,
        "status": user_session.get("status", "inactive"),
        "pod_id": user_session.get("pod_id", ""),
        "started_at": user_session.get("started_at", ""),
        "gpu_type": user_session.get("gpu_type", ""),
        "cost_per_hr": user_session.get("cost_per_hr", 0),
        "file_manager_url": user_session.get("file_manager_url", ""),
    })


@app.route("/api/sessions/start", methods=["POST"])
def api_start_session():
    """Start a GPU session for the logged-in user."""
    if 'username' not in session:
        return jsonify({"error": "unauthorized"}), 401

    username = session['username']
    data = request.json or {}
    full_name = data.get("full_name", username)

    # Check if session already active
    with sessions_lock:
        if username in sessions and sessions[username].get("status") == "running":
            return jsonify({
                "status": "already_running",
                "pod_id": sessions[username]["pod_id"],
                "message": "Session already active. Connect via Guacamole.",
            })

        sessions[username] = {
            "status": "starting",
            "started_at": datetime.now(timezone.utc).isoformat(),
            "full_name": full_name,
        }
        save_sessions()

    # Create pod in background thread
    def _create():
        try:
            upload_token = secrets.token_urlsafe(32)
            pod = create_pod(username, full_name, upload_token)
            pod_id = pod["id"]

            with sessions_lock:
                sessions[username]["pod_id"] = pod_id
                sessions[username]["status"] = "provisioning"
                save_sessions()

            # Wait for pod to be ready
            vnc_host, vnc_port = wait_for_pod_ready(pod_id)

            # Get file manager URL from pod ports (with retries)
            file_manager_url = ""
            for _attempt in range(6):
                try:
                    pod_info = runpod.get_pod(pod_id)
                    for port_info in pod_info.get("runtime", {}).get("ports", []):
                        if port_info.get("privatePort") == 8888:
                            fm_host = port_info.get("ip", "")
                            fm_port = port_info.get("publicPort", 0)
                            if fm_host and fm_port:
                                file_manager_url = f"http://{fm_host}:{fm_port}?token={upload_token}"
                                break
                except Exception:
                    pass
                if file_manager_url:
                    break
                log.info(f"Waiting for file manager port mapping (attempt {_attempt + 1}/6)...")
                time.sleep(10)

            if not file_manager_url:
                log.warning(f"Could not detect file manager URL for {username}")

            # Register in Guacamole
            register_vnc_connection(username, full_name, vnc_host, vnc_port)

            # Get cost info
            try:
                pod_info = runpod.get_pod(pod_id)
                cost = pod_info.get("costPerHr", 0)
                gpu = pod_info.get("machine", {}).get("gpuDisplayName", RUNPOD_GPU_TYPE)
            except Exception:
                cost = 0
                gpu = RUNPOD_GPU_TYPE

            with sessions_lock:
                sessions[username].update({
                    "status": "running",
                    "vnc_host": vnc_host,
                    "vnc_port": vnc_port,
                    "file_manager_url": file_manager_url,
                    "upload_token": upload_token,
                    "gpu_type": gpu,
                    "cost_per_hr": cost,
                    "last_activity": datetime.now(timezone.utc).isoformat(),
                })
                save_sessions()

            log.info(f"Session ready for {username}: {vnc_host}:{vnc_port}")

        except Exception as e:
            log.error(f"Failed to start session for {username}: {e}")
            with sessions_lock:
                sessions[username]["status"] = f"error: {str(e)[:100]}"
                save_sessions()

    thread = threading.Thread(target=_create, daemon=True)
    thread.start()

    return jsonify({
        "status": "starting",
        "message": "GPU pod is being provisioned. This takes 2-5 minutes. "
                   "Refresh this page or check Guacamole — your desktop will "
                   "appear automatically when ready.",
    })


@app.route("/api/sessions/stop", methods=["POST"])
def api_stop_session():
    """Stop the logged-in user's GPU session."""
    if 'username' not in session:
        return jsonify({"error": "unauthorized"}), 401

    username = session['username']
    data = request.json or {}
    do_terminate = data.get("terminate", False)

    user_session = sessions.get(username, {})
    pod_id = user_session.get("pod_id")

    if not pod_id:
        return jsonify({"error": "no active session"}), 404

    if do_terminate:
        try:
            stop_pod(pod_id)
            time.sleep(5)
        except Exception:
            pass
        terminate_pod(pod_id)
        remove_vnc_connection(username, user_session.get("full_name", username))
        with sessions_lock:
            sessions.pop(username, None)
            save_sessions()
        return jsonify({"status": "terminated"})
    else:
        stop_pod(pod_id)
        with sessions_lock:
            sessions[username]["status"] = "stopped"
            save_sessions()
        return jsonify({"status": "stopped", "message": "Pod stopped. Resume anytime."})


# ─── User-Facing Dashboard ──────────────────────────────────────────────

DASHBOARD_HTML = """
<!DOCTYPE html>
<html>
<head>
    <title>Descriptron Portal</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
               background: #0f172a; color: #e2e8f0; min-height: 100vh; }
        .header { background: #1e293b; padding: 1.5rem 2rem; border-bottom: 1px solid #334155;
                  position: relative; }
        .header h1 { font-size: 1.5rem; color: #f1f5f9; }
        .header p { color: #94a3b8; margin-top: 0.25rem; }
        .user-info { position: absolute; top: 1.5rem; right: 2rem; }
        .user-info span { color: #94a3b8; margin-right: 1rem; }
        .user-info a { color: #60a5fa; text-decoration: none; font-size: 0.9rem; }
        .user-info a:hover { text-decoration: underline; }
        .container { max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px;
                padding: 2rem; margin-bottom: 1.5rem; }
        .card h2 { color: #f1f5f9; margin-bottom: 1rem; font-size: 1.25rem; }
        .status { display: inline-block; padding: 0.25rem 0.75rem; border-radius: 999px;
                  font-size: 0.875rem; font-weight: 500; }
        .status-running { background: #065f46; color: #6ee7b7; }
        .status-starting { background: #92400e; color: #fcd34d; }
        .status-stopped { background: #374151; color: #9ca3af; }
        .status-inactive { background: #374151; color: #6b7280; }
        .status-error { background: #7f1d1d; color: #fca5a5; }
        .btn { display: inline-block; padding: 0.75rem 1.5rem; border-radius: 8px;
               font-size: 1rem; font-weight: 500; cursor: pointer; border: none;
               text-decoration: none; transition: all 0.2s; }
        .btn-primary { background: #2563eb; color: white; }
        .btn-primary:hover { background: #1d4ed8; }
        .btn-danger { background: #dc2626; color: white; }
        .btn-danger:hover { background: #b91c1c; }
        .btn-secondary { background: #475569; color: white; }
        .btn-secondary:hover { background: #374151; }
        .btn:disabled { opacity: 0.5; cursor: not-allowed; }
        .info-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin: 1rem 0; }
        .info-item label { display: block; color: #94a3b8; font-size: 0.75rem;
                          text-transform: uppercase; letter-spacing: 0.05em; }
        .info-item span { color: #f1f5f9; font-size: 1rem; }
        .actions { display: flex; gap: 1rem; margin-top: 1.5rem; flex-wrap: wrap; }
        .spinner { display: inline-block; width: 16px; height: 16px;
                   border: 2px solid #fcd34d; border-top-color: transparent;
                   border-radius: 50%; animation: spin 0.8s linear infinite;
                   vertical-align: middle; margin-right: 0.5rem; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .footer { text-align: center; padding: 2rem; color: #475569; font-size: 0.875rem; }
        .msg { padding: 1rem; border-radius: 8px; margin-bottom: 1rem; }
        .msg-info { background: #1e3a5f; border: 1px solid #2563eb; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🔬 Descriptron Portal</h1>
        <p>AI-powered morphological analysis — Museum für Naturkunde Berlin</p>
        <div class="user-info">
            <span>👤 {{ session["username"] }}</span>
            <a href="/logout">Sign Out</a>
        </div>
    </div>
    <div class="container">
        <div class="card" id="session-card">
            <h2>Your GPU Session</h2>
            <div id="session-info">Loading...</div>
        </div>

        <div class="card">
            <h2>Quick Guide</h2>
            <p style="color: #94a3b8; line-height: 1.6;">
                1. Click <strong>Start GPU Session</strong> to provision a GPU pod (takes 2-5 min)<br>
                2. Once ready, click <strong>Open Desktop</strong> to launch your Descriptron workspace<br>
                3. Use <strong>Upload Files</strong> to transfer images to/from your workspace<br>
                4. <strong>Stop</strong> your session when done to save costs (your data is preserved)<br>
                5. <strong>Terminate</strong> removes the pod completely when you are finished
            </p>
        </div>
    </div>
    <div class="footer">
        Descriptron Portal &middot; Center for Integrative Biodiversity Discovery &middot; MfN Berlin
    </div>

    <script>
        // Username comes from server-side session (no URL parameter needed)
        let username = '{{ session["username"] }}';
        let pollInterval = null;

        async function fetchStatus() {
            try {
                const res = await fetch(`/api/sessions/${username}`);
                if (res.status === 401) {
                    window.location.href = '/login';
                    return;
                }
                const data = await res.json();
                renderSession(data);
            } catch (e) {
                console.error(e);
            }
        }

        function renderSession(data) {
            const statusClass = {
                running: 'status-running', starting: 'status-starting',
                provisioning: 'status-starting', stopped: 'status-stopped',
                inactive: 'status-inactive',
            }[data.status] || (data.status?.startsWith('error') ? 'status-error' : 'status-inactive');

            let html = `<span class="status ${statusClass}">`;
            if (data.status === 'starting' || data.status === 'provisioning') {
                html += `<span class="spinner"></span>`;
            }
            html += `${data.status?.toUpperCase() || 'INACTIVE'}</span>`;

            if (data.status === 'running') {
                html += `
                <div class="info-grid">
                    <div class="info-item"><label>GPU</label><span>${data.gpu_type || 'N/A'}</span></div>
                    <div class="info-item"><label>Cost</label><span>$${(data.cost_per_hr || 0).toFixed(2)}/hr</span></div>
                    <div class="info-item"><label>Started</label><span>${new Date(data.started_at).toLocaleString()}</span></div>
                    <div class="info-item"><label>Pod ID</label><span>${data.pod_id || 'N/A'}</span></div>
                </div>
                <div class="actions">
                    <a href="/guacamole/" class="btn btn-primary" target="_blank">🖥️ Open Desktop</a>
                    ${data.file_manager_url ? `<a href="${data.file_manager_url}" class="btn btn-secondary" target="_blank">📁 Upload Files</a>` : ''}
                    <button class="btn btn-danger" onclick="stopSession(false)">⏸ Stop Session</button>
                    <button class="btn btn-secondary" onclick="stopSession(true)">🗑 Terminate</button>
                </div>`;
                clearInterval(pollInterval);
            } else if (data.status === 'starting' || data.status === 'provisioning') {
                html += `
                <div class="msg msg-info" style="margin-top:1rem">
                    <span class="spinner"></span>
                    Provisioning GPU pod... This typically takes 2-5 minutes.
                    The page will update automatically.
                </div>`;
                if (!pollInterval) pollInterval = setInterval(fetchStatus, 10000);
            } else if (data.status === 'stopped') {
                html += `
                <div class="actions" style="margin-top:1rem">
                    <button class="btn btn-primary" onclick="startSession()">▶ Resume Session</button>
                    <button class="btn btn-secondary" onclick="stopSession(true)">🗑 Terminate & Delete Pod</button>
                </div>`;
            } else if (data.status?.startsWith('error')) {
                html += `
                <p style="color:#fca5a5; margin-top:1rem">${data.status}</p>
                <div class="actions" style="margin-top:1rem">
                    <button class="btn btn-primary" onclick="startSession()">🔄 Retry</button>
                </div>`;
            } else {
                html += `
                <p style="color:#94a3b8; margin-top:1rem">No active session. Start one to begin working.</p>
                <div class="actions" style="margin-top:1rem">
                    <button class="btn btn-primary" onclick="startSession()">🚀 Start GPU Session</button>
                </div>`;
            }

            document.getElementById('session-info').innerHTML = html;
        }

        async function startSession() {
            try {
                const res = await fetch('/api/sessions/start', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({full_name: username}),
                });
                const data = await res.json();
                fetchStatus();
                if (!pollInterval) pollInterval = setInterval(fetchStatus, 10000);
            } catch (e) {
                alert('Failed to start session: ' + e.message);
            }
        }

        async function stopSession(terminate) {
            const action = terminate ? 'terminate' : 'stop';
            if (!confirm(`Are you sure you want to ${action} your session?`)) return;
            try {
                await fetch('/api/sessions/stop', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({terminate: terminate}),
                });
                fetchStatus();
            } catch (e) {
                alert('Failed: ' + e.message);
            }
        }

        fetchStatus();
        pollInterval = setInterval(fetchStatus, 15000);
    </script>
</body>
</html>
"""


@app.route("/dashboard")
@login_required
def dashboard():
    """User-facing dashboard for starting/stopping GPU sessions."""
    return render_template_string(DASHBOARD_HTML)


# ─── Background Tasks ───────────────────────────────────────────────────

def check_idle_pods():
    """Auto-stop pods that have been idle for too long."""
    now = datetime.now(timezone.utc)
    with sessions_lock:
        for username, user_session in list(sessions.items()):
            if user_session.get("status") != "running":
                continue
            last_activity = user_session.get("last_activity", user_session.get("started_at", ""))
            if not last_activity:
                continue
            try:
                last_dt = datetime.fromisoformat(last_activity.replace("Z", "+00:00"))
                idle_minutes = (now - last_dt).total_seconds() / 60
                if idle_minutes > IDLE_TIMEOUT:
                    log.warning(
                        f"Auto-stopping idle pod for {username} "
                        f"(idle {idle_minutes:.0f} min > {IDLE_TIMEOUT} min)"
                    )
                    pod_id = user_session.get("pod_id")
                    if pod_id:
                        stop_pod(pod_id)
                        user_session["status"] = "stopped"
                        save_sessions()
            except Exception as e:
                log.debug(f"Error checking idle for {username}: {e}")


def sync_pod_status():
    """Periodically check RunPod for actual pod status and sync."""
    with sessions_lock:
        for username, user_session in list(sessions.items()):
            pod_id = user_session.get("pod_id")
            if not pod_id:
                continue
            try:
                pod = runpod.get_pod(pod_id)
                actual_status = pod.get("desiredStatus", "UNKNOWN")
                if actual_status == "EXITED" and user_session.get("status") == "running":
                    user_session["status"] = "stopped"
                    save_sessions()
                elif actual_status == "RUNNING" and user_session.get("status") != "running":
                    user_session["status"] = "running"
                    user_session["last_activity"] = datetime.now(timezone.utc).isoformat()
                    save_sessions()
            except Exception:
                pass


# ─── Main ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    load_sessions()

    scheduler = BackgroundScheduler()
    scheduler.add_job(check_idle_pods, "interval", minutes=5)
    scheduler.add_job(sync_pod_status, "interval", minutes=2)
    scheduler.add_job(save_sessions, "interval", minutes=1)
    scheduler.start()

    log.info("Descriptron Orchestrator starting...")
    log.info(f"  Image: {DESCRIPTRON_IMAGE}")
    log.info(f"  GPU:   {RUNPOD_GPU_TYPE}")
    log.info(f"  Idle timeout: {IDLE_TIMEOUT} min")

    app.run(host="0.0.0.0", port=5000, debug=False)

