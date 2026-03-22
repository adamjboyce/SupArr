"""
SupArr Deploy — HTTP server, route dispatch, and SSE helpers.

stdlib-only HTTP server with REST API + SSE streaming.
Binds to localhost only. Session token auth on all API routes.
"""

import json
import mimetypes
import os
import secrets
import threading
import time
from functools import partial
from http.server import HTTPServer, BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from queue import Empty
from urllib.parse import parse_qs, urlparse

from deploy import config, ssh, deployer

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
SESSION_TOKEN = secrets.token_urlsafe(32)

# MIME types for static files
mimetypes.add_type("application/javascript", ".js")
mimetypes.add_type("text/css", ".css")


class SupArrHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the SupArr deploy GUI."""

    server_version = "SupArr-Deploy/1.0"

    def log_message(self, format, *args):
        """Suppress default stderr logging for clean terminal output."""
        pass

    # ── Routing ───────────────────────────────────────────────────────────────

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        routes = {
            "/": self._serve_index,
            "/api/config/schema": self._get_schema,
            "/api/config/components": self._get_components,
            "/api/config/load": self._get_config_load,
            "/api/deploy/status": self._get_deploy_status,
            "/api/deploy/stream": self._get_deploy_stream,
            "/api/postdeploy/stream": self._get_postdeploy_stream,
            "/api/trakt/poll": self._get_trakt_poll,
        }

        if path in routes:
            routes[path]()
        elif path.startswith("/static/"):
            self._serve_static(path)
        else:
            self._send_error(404, "Not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        routes = {
            "/api/config/validate": self._post_config_validate,
            "/api/config/save": self._post_config_save,
            "/api/ssh/test": self._post_ssh_test,
            "/api/ssh/setup-keys": self._post_ssh_setup_keys,
            "/api/trakt/start": self._post_trakt_start,
            "/api/deploy/start": self._post_deploy_start,
            "/api/deploy/cancel": self._post_deploy_cancel,
        }

        if path in routes:
            routes[path]()
        else:
            self._send_error(404, "Not found")

    # ── Auth ──────────────────────────────────────────────────────────────────

    def _check_auth(self):
        """Verify session token from header or query param. Returns True if valid."""
        token = self.headers.get("X-Session-Token", "")
        if not token:
            # Fall back to query param (needed for EventSource — can't send headers)
            qs = parse_qs(urlparse(self.path).query)
            token = qs.get("token", [""])[0]
        if token != SESSION_TOKEN:
            self._send_error(401, "Invalid session token")
            return False
        return True

    # ── Response Helpers ──────────────────────────────────────────────────────

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status, message):
        self._send_json({"error": message}, status)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def _start_sse(self):
        """Begin an SSE response. Returns True if headers sent."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        return True

    def _send_sse_event(self, event_type, data):
        """Send a single SSE event."""
        try:
            payload = json.dumps(data) if isinstance(data, dict) else str(data)
            msg = f"event: {event_type}\ndata: {payload}\n\n"
            self.wfile.write(msg.encode("utf-8"))
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    # ── Static File Serving ───────────────────────────────────────────────────

    def _serve_index(self):
        """Serve index.html with session token injected."""
        index_path = os.path.join(STATIC_DIR, "index.html")
        if not os.path.exists(index_path):
            self._send_error(404, "index.html not found")
            return
        content = Path(index_path).read_text(encoding="utf-8")
        # Inject session token as meta tag
        token_tag = f'<meta name="session-token" content="{SESSION_TOKEN}">'
        content = content.replace("</head>", f"  {token_tag}\n</head>", 1)
        body = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, path):
        """Serve static files from deploy/static/."""
        # Prevent directory traversal
        rel = path[len("/static/"):]
        if ".." in rel or rel.startswith("/"):
            self._send_error(403, "Forbidden")
            return
        file_path = os.path.join(STATIC_DIR, rel)
        if not os.path.isfile(file_path):
            self._send_error(404, "Not found")
            return
        mime, _ = mimetypes.guess_type(file_path)
        mime = mime or "application/octet-stream"
        body = Path(file_path).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        if mime in ("text/css", "application/javascript"):
            self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    # ── Config API ────────────────────────────────────────────────────────────

    def _get_schema(self):
        if not self._check_auth():
            return
        self._send_json({
            "schema": config.get_schema(),
            "defaults": config.get_defaults(),
            "timezones": config.TIMEZONES,
        })

    def _get_components(self):
        if not self._check_auth():
            return
        self._send_json(config.get_component_registry())

    def _get_config_load(self):
        if not self._check_auth():
            return
        project_dir = self.server.project_dir
        existing = config.load_existing_env(project_dir)
        self._send_json({"config": existing, "found": bool(existing)})

    def _post_config_validate(self):
        if not self._check_auth():
            return
        body = self._read_body()
        cfg = body.get("config", {})
        section = body.get("section", "")
        if section:
            errors = config.validate_section(cfg, section)
            self._send_json({"valid": len(errors) == 0, "errors": errors})
        else:
            all_errors = config.validate_all(cfg)
            self._send_json({"valid": len(all_errors) == 0, "errors": all_errors})

    def _post_config_save(self):
        if not self._check_auth():
            return
        body = self._read_body()
        cfg = body.get("config", {})

        # Validate everything
        errors = config.validate_all(cfg)
        if errors:
            self._send_json({"ok": False, "errors": errors}, 400)
            return

        # Generate and write .env files locally
        project_dir = self.server.project_dir
        plex_env = config.generate_plex_env(cfg)
        arr_env = config.generate_arr_env(cfg)

        plex_path = os.path.join(project_dir, "machine1-plex", ".env")
        arr_path = os.path.join(project_dir, "machine2-arr", ".env")

        config.write_env(plex_env, plex_path)
        config.write_env(arr_env, arr_path)

        self._send_json({
            "ok": True,
            "message": ".env files generated",
            "plex_env_path": plex_path,
            "arr_env_path": arr_path,
        })

    # ── SSH API ───────────────────────────────────────────────────────────────

    def _post_ssh_test(self):
        if not self._check_auth():
            return
        body = self._read_body()
        host = body.get("host", "")
        user = body.get("user", "root")
        if not host:
            self._send_json({"ok": False, "message": "No host provided"})
            return
        result = ssh.test_connection(host, user)
        self._send_json(result)

    def _post_ssh_setup_keys(self):
        if not self._check_auth():
            return
        body = self._read_body()
        hosts = body.get("hosts", [])
        user = body.get("user", "root")
        password = body.get("password", "")
        root_password = body.get("root_password", "")
        results = []

        # Generate key if needed
        if not ssh.key_exists():
            gen = ssh.generate_key()
            if not gen["ok"]:
                self._send_json({"ok": False, "message": gen["message"], "results": []})
                return
            results.append({"host": "local", "action": "keygen", "ok": True, "message": gen["message"]})

        for host in hosts:
            if user == "root":
                # Deploy key directly to root
                dep = ssh.deploy_key(host, "root", password)
                results.append({"host": host, "action": "deploy_key", **dep})
            else:
                # Deploy key to user, then set up root access
                setup = ssh.setup_root_access(host, user, password, root_password)
                results.append({"host": host, "action": "root_access", **setup})

            # Verify connectivity
            test = ssh.test_connection(host, "root")
            results.append({"host": host, "action": "verify", **test})

        all_ok = all(r.get("ok", False) for r in results if r["action"] == "verify")
        self._send_json({"ok": all_ok, "results": results})

    # ── Trakt API ─────────────────────────────────────────────────────────────

    def _post_trakt_start(self):
        if not self._check_auth():
            return
        body = self._read_body()
        client_id = body.get("client_id", "")
        client_secret = body.get("client_secret", "")
        if not client_id or not client_secret:
            self._send_json({"ok": False, "message": "Client ID and secret required"})
            return
        result = deployer.start_trakt_auth(client_id, client_secret)
        self._send_json(result)

    def _get_trakt_poll(self):
        if not self._check_auth():
            return
        auth = deployer.get_trakt_auth()
        if not auth:
            self._send_json({"status": "idle"})
            return

        self._start_sse()
        while True:
            try:
                event = auth.queue.get(timeout=15)
                if not self._send_sse_event("trakt", event):
                    break
                if event.get("status") in ("success", "timeout", "error"):
                    break
            except Empty:
                # Heartbeat
                if not self._send_sse_event("heartbeat", {"ts": time.time()}):
                    break
            # Check if auth is done
            if auth.status in ("success", "timeout", "error"):
                self._send_sse_event("trakt", auth.get_status())
                break

    # ── Deploy API ────────────────────────────────────────────────────────────

    def _post_deploy_start(self):
        if not self._check_auth():
            return
        body = self._read_body()
        cfg = body.get("config", {})
        if not cfg:
            self._send_json({"ok": False, "message": "No config provided"})
            return

        state = deployer.get_deploy_state()
        if state.status in ("syncing", "deploying", "post_deploy"):
            self._send_json({"ok": False, "message": "Deploy already in progress"})
            return

        project_dir = self.server.project_dir
        self.server._last_config = cfg
        deployer.start_deploy(cfg, project_dir)
        self._send_json({"ok": True, "message": "Deploy started"})

    def _post_deploy_cancel(self):
        if not self._check_auth():
            return
        state = deployer.get_deploy_state()
        state.cancel()
        self._send_json({"ok": True, "message": "Deploy cancelled"})

    def _get_deploy_status(self):
        if not self._check_auth():
            return
        state = deployer.get_deploy_state()
        data = state.get_state()
        data["services"] = {}
        # Include service URLs once done
        if state.status in ("done", "post_deploy"):
            saved_config = getattr(self.server, "_last_config", None)
            if saved_config:
                data["services"] = config.get_service_urls(saved_config)
        self._send_json(data)

    def _get_deploy_stream(self):
        """SSE stream of deploy output. Merges both machine queues."""
        if not self._check_auth():
            return
        state = deployer.get_deploy_state()
        self._start_sse()

        while True:
            sent = False
            # Drain plex queue
            try:
                while True:
                    event = state.plex_queue.get_nowait()
                    if not self._send_sse_event(event.get("type", "log"), event):
                        return
                    sent = True
            except Empty:
                pass

            # Drain arr queue
            try:
                while True:
                    event = state.arr_queue.get_nowait()
                    if not self._send_sse_event(event.get("type", "log"), event):
                        return
                    sent = True
            except Empty:
                pass

            # Check if deploy is finished
            if state.status in ("done", "error", "cancelled"):
                self._send_sse_event("status", {
                    "status": state.status,
                    "error": state.error_message,
                })
                break

            if not sent:
                # No events — send heartbeat and sleep briefly
                if not self._send_sse_event("heartbeat", {"ts": time.time()}):
                    break
                time.sleep(0.5)

    def _get_postdeploy_stream(self):
        """SSE stream of post-deploy polling events."""
        if not self._check_auth():
            return
        state = deployer.get_deploy_state()
        self._start_sse()

        while True:
            try:
                event = state.postdeploy_queue.get(timeout=15)
                if not self._send_sse_event(event.get("type", "log"), event):
                    break
                if event.get("type") == "done":
                    break
            except Empty:
                if not self._send_sse_event("heartbeat", {"ts": time.time()}):
                    break
                if state.status in ("done", "error", "cancelled"):
                    self._send_sse_event("status", {"status": state.status})
                    break


class SupArrServer(ThreadingHTTPServer):
    """Threaded HTTP server — SSE streams won't block other requests."""

    allow_reuse_address = True

    def __init__(self, addr, handler, project_dir):
        self.project_dir = project_dir
        self._last_config = None
        super().__init__(addr, handler)


def find_port(start=8765, end=8775):
    """Find an available port in range."""
    import socket
    for port in range(start, end + 1):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(("127.0.0.1", port))
                return port
        except OSError:
            continue
    return None


def start_server(project_dir, port=None):
    """Start the SupArr deploy server. Returns (server, port, token)."""
    if port is None:
        port = find_port()
    if port is None:
        raise RuntimeError("No available port found (tried 8765-8775)")

    server = SupArrServer(("127.0.0.1", port), SupArrHandler, project_dir)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    return server, port, SESSION_TOKEN


if __name__ == "__main__":
    import signal
    import subprocess as _sp
    import sys

    project_dir = str(Path(__file__).resolve().parent.parent)
    port = int(sys.argv[1]) if len(sys.argv) > 1 else None

    # Kill previous instance on the same port
    _target_port = port or 8765
    try:
        result = _sp.run(
            ["lsof", "-ti", f":{_target_port}"],
            capture_output=True, text=True
        )
        if result.stdout.strip():
            for pid in result.stdout.strip().split("\n"):
                pid = pid.strip()
                if pid and int(pid) != os.getpid():
                    os.kill(int(pid), signal.SIGTERM)
                    print(f"  Killed previous instance (PID {pid}) on port {_target_port}")
                    time.sleep(0.5)
    except Exception:
        pass

    server, port, token = start_server(project_dir, port)
    url = f"http://localhost:{port}/?token={token}"

    print(f"\n  SupArr Deploy running at: {url}\n")

    # Open browser — prefer Windows browser on WSL, fall back to xdg-open
    try:
        _sp.Popen(["cmd.exe", "/c", "start", url.replace("&", "^&")],
                  stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
    except FileNotFoundError:
        import webbrowser
        webbrowser.open(url)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()
