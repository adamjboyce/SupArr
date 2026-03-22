"""
SupArr Deploy — Deployment orchestration.

Manages the full deploy lifecycle: project sync, .env generation + merge,
init script execution with real-time output parsing, and post-deploy
polling (Overseerr auto-config, Kometa first run).
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
from queue import Queue, Empty

from deploy import ssh, config


# ── Pre-flight checks ────────────────────────────────────────────────────────

REQUIRED_TOOLS = ["rsync", "ssh"]


def preflight_check():
    """Verify local dependencies, auto-installing any that are missing.
    Returns (ok, message).
    """
    missing = [t for t in REQUIRED_TOOLS if shutil.which(t) is None]
    if not missing:
        return True, ""

    # Auto-install via apt
    try:
        subprocess.run(
            ["sudo", "apt-get", "update", "-qq"],
            check=True, capture_output=True, timeout=60,
        )
        subprocess.run(
            ["sudo", "apt-get", "install", "-y", "-qq"] + missing,
            check=True, capture_output=True, timeout=120,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        names = ", ".join(missing)
        return False, f"Failed to install {names}: {e}. Install manually: sudo apt-get install -y {' '.join(missing)}"

    # Verify they're actually available now
    still_missing = [t for t in missing if shutil.which(t) is None]
    if still_missing:
        names = ", ".join(still_missing)
        return False, f"Installed but still not found: {names}. Check your PATH."

    return True, f"Auto-installed: {', '.join(missing)}"

REMOTE_PROJECT_PATH = "/opt/suparr"

# ANSI escape stripper
ANSI_RE = re.compile(r"\x1b\[[\d;]*m")

# Line classification patterns
PHASE_RE = re.compile(r"Phase\s+(\d+)")
SUCCESS_MARKERS = {"✓", "✔", "[✓]", "[ok]"}
WARNING_MARKERS = {"!", "[!]", "⚠", "[warn]"}
ERROR_MARKERS = {"✗", "✘", "[✗]", "[error]", "[err]"}


def strip_ansi(text):
    """Remove ANSI color codes from text."""
    return ANSI_RE.sub("", text)


def classify_line(line):
    """Classify a log line by severity. Returns event type string."""
    clean = strip_ansi(line).strip()
    if not clean:
        return "log"
    # Phase detection
    if PHASE_RE.search(clean):
        return "phase"
    lower = clean.lower()
    # Check markers at start of line
    for m in ERROR_MARKERS:
        if clean.startswith(m) or lower.startswith(m.lower()):
            return "error"
    for m in WARNING_MARKERS:
        if clean.startswith(m) or lower.startswith(m.lower()):
            return "warning"
    for m in SUCCESS_MARKERS:
        if clean.startswith(m) or lower.startswith(m.lower()):
            return "success"
    # Fallback checks
    if "error" in lower or "failed" in lower or "fatal" in lower:
        return "error"
    if "warning" in lower or "warn:" in lower:
        return "warning"
    return "log"


def extract_phase(line):
    """Extract phase number from a line, or None."""
    clean = strip_ansi(line)
    match = PHASE_RE.search(clean)
    if match:
        return int(match.group(1))
    return None


# ── Deploy State ───────────────────────────────────────────────────────────────

class DeployState:
    """Thread-safe deploy state tracker."""

    def __init__(self):
        self.status = "idle"  # idle, syncing, deploying, post_deploy, done, error, cancelled
        self.plex_phase = 0
        self.plex_total_phases = 11
        self.arr_phase = 0
        self.arr_total_phases = 9
        self.plex_result = None  # None, 0 (success), >0 (failure)
        self.arr_result = None
        self.plex_queue = Queue()
        self.arr_queue = Queue()
        self.postdeploy_queue = Queue()
        self.error_message = ""
        self._lock = threading.Lock()
        self._cancel = threading.Event()
        self._processes = []

    def set_status(self, status):
        with self._lock:
            self.status = status

    def get_state(self):
        with self._lock:
            return {
                "status": self.status,
                "plex_phase": self.plex_phase,
                "plex_total_phases": self.plex_total_phases,
                "arr_phase": self.arr_phase,
                "arr_total_phases": self.arr_total_phases,
                "plex_result": self.plex_result,
                "arr_result": self.arr_result,
                "error": self.error_message,
            }

    def cancel(self):
        self._cancel.set()
        with self._lock:
            for proc in self._processes:
                try:
                    proc.kill()
                except OSError:
                    pass
            self.status = "cancelled"

    @property
    def cancelled(self):
        return self._cancel.is_set()

    def register_process(self, proc):
        with self._lock:
            self._processes.append(proc)


# Global state — only one deploy at a time
_deploy_state = None


def get_deploy_state():
    global _deploy_state
    if _deploy_state is None:
        _deploy_state = DeployState()
    return _deploy_state


def reset_deploy_state():
    global _deploy_state
    _deploy_state = DeployState()
    return _deploy_state


# ── Init Script Execution ──────────────────────────────────────────────────────

def _run_init_thread(host, label, script, deploy_user, state, queue, role):
    """Run an init script on a remote host, streaming output to a queue."""
    env_prefix = f"DEPLOY_USER={shlex.quote(deploy_user)}"
    cmd = f"{env_prefix} bash {REMOTE_PROJECT_PATH}/scripts/{script}"

    try:
        proc = ssh.remote_exec_stream(host, cmd)
        state.register_process(proc)

        for line in proc.stdout:
            if state.cancelled:
                proc.kill()
                break
            line = line.rstrip("\n")
            clean = strip_ansi(line)
            event_type = classify_line(line)

            # Update phase counter
            phase = extract_phase(line)
            if phase is not None:
                with state._lock:
                    if role == "plex":
                        state.plex_phase = phase
                    else:
                        state.arr_phase = phase

            queue.put({
                "type": event_type,
                "data": clean,
                "machine": label,
            })

        proc.wait()
        rc = proc.returncode

        with state._lock:
            if role == "plex":
                state.plex_result = rc
            else:
                state.arr_result = rc

        if rc == 0:
            queue.put({"type": "done", "data": f"{label} completed successfully", "machine": label})
        else:
            queue.put({"type": "error", "data": f"{label} failed (exit code {rc})", "machine": label})

    except Exception as e:
        queue.put({"type": "error", "data": f"{label} error: {str(e)}", "machine": label})
        with state._lock:
            if role == "plex":
                state.plex_result = 1
            else:
                state.arr_result = 1


# ── Full Deploy Orchestration ──────────────────────────────────────────────────

def start_deploy(cfg, project_dir):
    """Kick off the full deployment. Returns the deploy state object.
    Runs in a background thread.
    """
    state = reset_deploy_state()
    thread = threading.Thread(
        target=_deploy_main, args=(cfg, project_dir, state),
        daemon=True
    )
    thread.start()
    return state


def _deploy_main(cfg, project_dir, state):
    """Main deploy sequence — runs in background thread."""
    plex_ip, arr_ip = config.resolve_ips(cfg)
    plex_media, plex_appdata, arr_media, arr_downloads, arr_appdata = config.resolve_paths(cfg)
    single_machine = cfg.get("deploy_mode") == "single"
    ssh_user = cfg.get("ssh_user", "root")

    try:
        # ── Phase 1: Generate .env files ───────────────────────────────────
        state.set_status("syncing")
        _emit_both(state, "log", "Generating .env files...")

        plex_env_content = config.generate_plex_env(cfg)
        arr_env_content = config.generate_arr_env(cfg)

        # Write to temp files
        tmpdir = tempfile.mkdtemp(prefix="suparr_deploy_")
        plex_env_path = os.path.join(tmpdir, "plex.env")
        arr_env_path = os.path.join(tmpdir, "arr.env")
        config.write_env(plex_env_content, plex_env_path)
        config.write_env(arr_env_content, arr_env_path)

        if state.cancelled:
            return

        # ── Phase 2: Merge remote API keys ─────────────────────────────────
        _emit_both(state, "log", "Checking for existing API keys on remote...")

        plex_remote_env = f"{REMOTE_PROJECT_PATH}/machine1-plex/.env"
        arr_remote_env = f"{REMOTE_PROJECT_PATH}/machine2-arr/.env"

        target_host = plex_ip if not single_machine else plex_ip
        merged = ssh.merge_remote_env_keys(target_host, plex_remote_env, plex_env_path)
        if merged > 0:
            _emit_both(state, "success", f"Preserved {merged} API key(s) from Spyglass")

        if single_machine:
            merged = ssh.merge_remote_env_keys(plex_ip, arr_remote_env, arr_env_path)
        else:
            merged = ssh.merge_remote_env_keys(arr_ip, arr_remote_env, arr_env_path)
        if merged > 0:
            _emit_both(state, "success", f"Preserved {merged} API key(s) from Privateer")

        if state.cancelled:
            return

        # ── Phase 3: Rsync project + .env files ───────────────────────────
        _emit_both(state, "log", "Syncing project files...")

        if single_machine:
            hosts = [plex_ip]
        else:
            hosts = [plex_ip, arr_ip]

        for host in hosts:
            result = ssh.rsync_project(host, "root", project_dir)
            if not result["ok"]:
                state.error_message = result["message"]
                state.set_status("error")
                _emit_both(state, "error", result["message"])
                return
            _emit_both(state, "success", f"Project synced to {host}")

        # Sync .env files
        for host in hosts:
            ssh.rsync_env(host, plex_env_path, plex_remote_env)
            ssh.rsync_env(host, arr_env_path, arr_remote_env)
            ssh.fix_permissions(host)

        _emit_both(state, "success", ".env files deployed")

        if state.cancelled:
            return

        # ── Phase 4: Run init scripts ──────────────────────────────────────
        state.set_status("deploying")
        deploy_user = cfg.get("ssh_user", "root")

        if single_machine:
            # Sequential on same machine
            _emit_both(state, "log", f"Running init scripts on {plex_ip}...")

            _run_init_thread(
                plex_ip, "Spyglass", "init-machine1-plex.sh",
                deploy_user, state, state.plex_queue, "plex"
            )
            if state.cancelled:
                return
            _run_init_thread(
                plex_ip, "Privateer", "init-machine2-arr.sh",
                deploy_user, state, state.arr_queue, "arr"
            )
        else:
            # Parallel on two machines
            _emit_both(state, "log", "Launching init scripts in parallel...")

            plex_thread = threading.Thread(
                target=_run_init_thread,
                args=(plex_ip, "Spyglass", "init-machine1-plex.sh",
                      deploy_user, state, state.plex_queue, "plex"),
                daemon=True
            )
            arr_thread = threading.Thread(
                target=_run_init_thread,
                args=(arr_ip, "Privateer", "init-machine2-arr.sh",
                      deploy_user, state, state.arr_queue, "arr"),
                daemon=True
            )
            plex_thread.start()
            arr_thread.start()
            plex_thread.join()
            arr_thread.join()

        if state.cancelled:
            return

        # ── Phase 5: Post-deploy ───────────────────────────────────────────
        plex_ok = state.plex_result == 0
        arr_ok = state.arr_result == 0

        if plex_ok and arr_ok:
            state.set_status("post_deploy")
            _start_postdeploy(cfg, state)
        elif plex_ok or arr_ok:
            state.set_status("post_deploy")
            which = "Spyglass" if plex_ok else "Privateer"
            failed = "Privateer" if plex_ok else "Spyglass"
            state.postdeploy_queue.put({
                "type": "warning",
                "data": f"{failed} failed. {which} succeeded — running post-deploy for {which}.",
            })
            _start_postdeploy(cfg, state)
        else:
            state.set_status("error")
            state.error_message = "Both machines failed"

    except Exception as e:
        state.error_message = str(e)
        state.set_status("error")
        _emit_both(state, "error", f"Deploy error: {e}")

    finally:
        # Revoke NOPASSWD sudo — deploy is done, lock it back down
        deploy_user = cfg.get("ssh_user", "root")
        if deploy_user != "root":
            for host in hosts:
                try:
                    ssh.remote_exec(host, "root",
                        f"rm -f /etc/sudoers.d/{deploy_user}")
                    _emit_both(state, "log", f"Revoked NOPASSWD sudo on {host}")
                except Exception:
                    _emit_both(state, "warning",
                        f"Could not revoke sudo on {host} — remove /etc/sudoers.d/{deploy_user} manually")

        # Clean up temp files
        try:
            import shutil
            if 'tmpdir' in locals():
                shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass


def _emit_both(state, event_type, message):
    """Push a message to both machine queues."""
    event = {"type": event_type, "data": message, "machine": "system"}
    state.plex_queue.put(event)
    state.arr_queue.put(event)


# ── Post-Deploy Automation ─────────────────────────────────────────────────────

def _start_postdeploy(cfg, state):
    """Start post-deploy polling in a background thread."""
    thread = threading.Thread(
        target=_postdeploy_loop, args=(cfg, state),
        daemon=True
    )
    thread.start()


def _postdeploy_loop(cfg, state):
    """Poll for Overseerr wizard completion and Plex libraries → Kometa."""
    plex_ip, arr_ip = resolve_ips_from_cfg(cfg)
    _, plex_appdata, _, _, _ = config.resolve_paths(cfg)
    plex_token = cfg.get("plex_token", "")
    single_machine = cfg.get("deploy_mode") == "single"

    need_overseerr = state.plex_result == 0 and state.arr_result == 0
    need_kometa = state.plex_result == 0
    overseerr_done = False
    kometa_done = False

    poll_max = 7200  # 2 hours
    poll_interval = 60
    elapsed = 0

    q = state.postdeploy_queue
    q.put({"type": "log", "data": "Starting post-deploy checks..."})

    while elapsed < poll_max and not state.cancelled:
        time.sleep(poll_interval)
        elapsed += poll_interval

        # Check Overseerr
        if need_overseerr and not overseerr_done:
            if _check_overseerr_ready(plex_ip, plex_appdata):
                q.put({"type": "success", "data": "Overseerr is ready — configuring..."})
                ok = _configure_overseerr(plex_ip, arr_ip, plex_appdata, cfg, single_machine)
                if ok:
                    q.put({"type": "success", "data": "Overseerr → Radarr + Sonarr configured"})
                overseerr_done = True

        # Check Plex libraries → Kometa
        if need_kometa and not kometa_done:
            if _check_plex_libraries(plex_ip, plex_token):
                q.put({"type": "success", "data": "Plex libraries detected — triggering Kometa..."})
                _trigger_kometa(plex_ip, plex_appdata)
                kometa_done = True
                q.put({"type": "success", "data": "Kometa first run started"})

        # All done?
        if (overseerr_done or not need_overseerr) and (kometa_done or not need_kometa):
            q.put({"type": "done", "data": "All post-deploy automation complete"})
            state.set_status("done")
            return

        mins = elapsed // 60
        waiting = []
        if need_overseerr and not overseerr_done:
            waiting.append("Overseerr wizard")
        if need_kometa and not kometa_done:
            waiting.append("Plex libraries")
        q.put({"type": "log", "data": f"Waiting for {' + '.join(waiting)}... ({mins}m elapsed)"})

    # Timeout
    if need_overseerr and not overseerr_done:
        q.put({"type": "warning", "data": "Overseerr timed out. Re-deploy to configure."})
    if need_kometa and not kometa_done:
        q.put({"type": "warning", "data": "Kometa timed out. Run manually: docker exec kometa python kometa.py --run"})
    q.put({"type": "done", "data": "Post-deploy polling finished"})
    state.set_status("done")


def resolve_ips_from_cfg(cfg):
    """Convenience wrapper for config.resolve_ips."""
    return config.resolve_ips(cfg)


# ── Overseerr Auto-Config ─────────────────────────────────────────────────────

def _http_get(url, headers=None, timeout=10):
    """Simple HTTP GET via urllib."""
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def _http_post(url, data, headers=None, timeout=10):
    """Simple HTTP POST via urllib."""
    body = json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json",
        **(headers or {}),
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def _check_overseerr_ready(plex_ip, plex_appdata):
    """Check if Overseerr is initialized and API-ready."""
    # Read API key from settings
    rc, stdout, _ = ssh.remote_exec(
        plex_ip,
        f"jq -r '.main.apiKey // empty' '{plex_appdata}/overseerr/config/settings.json' 2>/dev/null",
        timeout=10,
    )
    if rc != 0 or not stdout.strip():
        return False
    # Check public endpoint
    data = _http_get(f"http://{plex_ip}:5055/api/v1/settings/public")
    if not data:
        return False
    return data.get("initialized", False)


def _configure_overseerr(plex_ip, arr_ip, plex_appdata, cfg, single_machine):
    """Auto-configure Overseerr → Radarr/Sonarr. Returns True on success."""
    # Get Overseerr API key
    rc, stdout, _ = ssh.remote_exec(
        plex_ip,
        f"jq -r '.main.apiKey // empty' '{plex_appdata}/overseerr/config/settings.json' 2>/dev/null",
        timeout=10,
    )
    os_key = stdout.strip()
    if not os_key:
        return False

    os_headers = {"X-Api-Key": os_key}
    os_url = f"http://{plex_ip}:5055/api/v1"
    target = "localhost" if single_machine else arr_ip

    # Read API keys from remote .env
    remote_env_content = ssh.read_remote_env(
        arr_ip if not single_machine else plex_ip,
        f"{REMOTE_PROJECT_PATH}/machine2-arr/.env"
    )
    remote_env = config.parse_env_file(remote_env_content) if remote_env_content else {}
    radarr_key = remote_env.get("RADARR_API_KEY", "")
    sonarr_key = remote_env.get("SONARR_API_KEY", "")

    success = True

    # Configure Radarr
    if radarr_key:
        existing = _http_get(f"{os_url}/settings/radarr", os_headers)
        if existing is not None and len(existing) == 0:
            # Get quality profiles
            profiles = _http_get(
                f"http://{target}:7878/api/v3/qualityprofile",
                {"X-Api-Key": radarr_key}
            ) or []
            prof = next((p for p in profiles if p.get("name") == "HD Bluray + WEB"), None)
            if not prof and profiles:
                prof = profiles[0]
            prof_id = prof["id"] if prof else 1
            prof_name = prof["name"] if prof else "Any"

            roots = _http_get(
                f"http://{target}:7878/api/v3/rootfolder",
                {"X-Api-Key": radarr_key}
            ) or []
            root_path = roots[0]["path"] if roots else "/movies"

            _http_post(f"{os_url}/settings/radarr", {
                "name": "Radarr", "hostname": target, "port": 7878,
                "apiKey": radarr_key, "useSsl": False, "baseUrl": "",
                "activeProfileId": prof_id, "activeProfileName": prof_name,
                "activeDirectory": root_path, "is4k": False,
                "minimumAvailability": "released", "isDefault": True,
                "externalUrl": "", "syncEnabled": False, "preventSearch": False,
            }, os_headers)

    # Configure Sonarr
    if sonarr_key:
        existing = _http_get(f"{os_url}/settings/sonarr", os_headers)
        if existing is not None and len(existing) == 0:
            profiles = _http_get(
                f"http://{target}:8989/api/v3/qualityprofile",
                {"X-Api-Key": sonarr_key}
            ) or []
            prof = next((p for p in profiles if p.get("name") == "WEB-1080p"), None)
            if not prof and profiles:
                prof = profiles[0]
            prof_id = prof["id"] if prof else 1
            prof_name = prof["name"] if prof else "Any"

            roots = _http_get(
                f"http://{target}:8989/api/v3/rootfolder",
                {"X-Api-Key": sonarr_key}
            ) or []
            root_path = roots[0]["path"] if roots else "/tv"
            anime_path = next(
                (r["path"] for r in roots if "anime" in r.get("path", "").lower()),
                "/anime"
            )

            _http_post(f"{os_url}/settings/sonarr", {
                "name": "Sonarr", "hostname": target, "port": 8989,
                "apiKey": sonarr_key, "useSsl": False, "baseUrl": "",
                "activeProfileId": prof_id, "activeProfileName": prof_name,
                "activeDirectory": root_path,
                "activeAnimeProfileId": prof_id, "activeAnimeProfileName": prof_name,
                "activeAnimeDirectory": anime_path,
                "is4k": False, "enableSeasonFolders": True, "isDefault": True,
                "externalUrl": "", "syncEnabled": False, "preventSearch": False,
            }, os_headers)

    # Enable Plex Watchlist sync
    _http_post(f"{os_url}/settings/plex", {"watchlistSync": True}, os_headers)

    return success


# ── Plex / Kometa ──────────────────────────────────────────────────────────────

def _check_plex_libraries(plex_ip, plex_token):
    """Check if Plex has any libraries configured."""
    headers = {}
    url = f"http://{plex_ip}:32400/library/sections"
    if plex_token:
        url += f"?X-Plex-Token={plex_token}"
        headers["Accept"] = "application/json"
    data = _http_get(url, headers)
    if not data:
        return False
    container = data.get("MediaContainer", {})
    return container.get("size", 0) > 0


def _trigger_kometa(plex_ip, plex_appdata):
    """Trigger Kometa first run if not already triggered."""
    marker = f"{plex_appdata}/kometa/.first-run-triggered"
    rc, _, _ = ssh.remote_exec(plex_ip, f"test -f {shlex.quote(marker)}", timeout=5)
    if rc == 0:
        return  # Already triggered

    # Verify kometa container is running
    rc, stdout, _ = ssh.remote_exec(
        plex_ip,
        "docker ps --filter name=kometa --format '{{.Status}}'",
        timeout=5,
    )
    if "Up" not in (stdout or ""):
        return

    # Trigger and mark
    ssh.remote_exec(plex_ip, "docker exec -d kometa python kometa.py --run", timeout=10)
    ssh.remote_exec(plex_ip, f"touch {shlex.quote(marker)}", timeout=5)


# ── Trakt Device Auth ──────────────────────────────────────────────────────────

class TraktAuth:
    """Manages Trakt OAuth device auth flow."""

    DEVICE_CODE_URL = "https://api.trakt.tv/oauth/device/code"
    DEVICE_TOKEN_URL = "https://api.trakt.tv/oauth/device/token"

    def __init__(self, client_id, client_secret):
        self.client_id = client_id
        self.client_secret = client_secret
        self.user_code = None
        self.device_code = None
        self.verification_url = None
        self.expires_in = 0
        self.interval = 5
        self.status = "idle"  # idle, pending, success, error, timeout
        self.tokens = {}
        self.queue = Queue()
        self._thread = None

    def start(self):
        """Initiate device auth flow. Returns device code info."""
        data = json.dumps({"client_id": self.client_id}).encode()
        req = urllib.request.Request(
            self.DEVICE_CODE_URL,
            data=data,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read().decode())
        except Exception as e:
            self.status = "error"
            return {"ok": False, "message": f"Could not reach Trakt: {e}"}

        self.user_code = result.get("user_code", "")
        self.device_code = result.get("device_code", "")
        self.verification_url = result.get("verification_url", "https://trakt.tv/activate")
        self.expires_in = result.get("expires_in", 600)
        self.interval = result.get("interval", 5)
        self.status = "pending"

        # Start polling in background
        self._thread = threading.Thread(target=self._poll, daemon=True)
        self._thread.start()

        return {
            "ok": True,
            "user_code": self.user_code,
            "verification_url": self.verification_url,
            "expires_in": self.expires_in,
        }

    def _poll(self):
        """Poll Trakt for token completion."""
        elapsed = 0
        while elapsed < self.expires_in:
            time.sleep(self.interval)
            elapsed += self.interval

            data = json.dumps({
                "code": self.device_code,
                "client_id": self.client_id,
                "client_secret": self.client_secret,
            }).encode()
            req = urllib.request.Request(
                self.DEVICE_TOKEN_URL,
                data=data,
                headers={"Content-Type": "application/json"},
            )
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    result = json.loads(resp.read().decode())
                    if result.get("access_token"):
                        self.tokens = {
                            "access_token": result["access_token"],
                            "refresh_token": result.get("refresh_token", ""),
                            "expires_in": result.get("expires_in", ""),
                            "created_at": result.get("created_at", ""),
                        }
                        self.status = "success"
                        self.queue.put({"status": "success", "tokens": self.tokens})
                        return
            except urllib.error.HTTPError:
                # 400 = pending, keep polling
                pass
            except Exception:
                pass

            self.queue.put({"status": "pending", "elapsed": elapsed})

        self.status = "timeout"
        self.queue.put({"status": "timeout"})

    def get_status(self):
        return {
            "status": self.status,
            "user_code": self.user_code,
            "verification_url": self.verification_url,
            "tokens": self.tokens,
        }


# Global Trakt auth instance
_trakt_auth = None


def start_trakt_auth(client_id, client_secret):
    global _trakt_auth
    _trakt_auth = TraktAuth(client_id, client_secret)
    return _trakt_auth.start()


def get_trakt_auth():
    global _trakt_auth
    return _trakt_auth
