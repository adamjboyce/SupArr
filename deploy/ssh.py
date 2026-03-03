"""
SupArr Deploy — SSH operations.

Key generation, deployment, connectivity testing, rsync, and .env merge.
All operations use subprocess — no paramiko, no dependencies.
"""

import os
import shlex
import subprocess
from pathlib import Path

from deploy.config import parse_env_file

SSH_KEY_PATH = os.path.expanduser("~/.ssh/suparr_deploy_key")
REMOTE_PROJECT_PATH = "/opt/suparr"

SSH_OPTS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=10",
    "-o", "ConnectTimeout=10",
]

# API keys to preserve from remote .env on re-deploy
MERGE_API_KEYS = [
    "RADARR_API_KEY", "SONARR_API_KEY", "LIDARR_API_KEY",
    "PROWLARR_API_KEY", "BAZARR_API_KEY", "BOOKSHELF_API_KEY",
    "WHISPARR_API_KEY", "SABNZBD_API_KEY",
]


def _ssh_cmd(key_path=None):
    """Build base SSH command list."""
    cmd = ["ssh"] + SSH_OPTS
    kp = key_path or SSH_KEY_PATH
    if os.path.exists(kp):
        cmd += ["-i", kp]
    return cmd


def _rsync_ssh(key_path=None):
    """Build SSH command string for rsync -e flag."""
    parts = ["ssh"] + SSH_OPTS
    kp = key_path or SSH_KEY_PATH
    if os.path.exists(kp):
        parts += ["-i", kp]
    return " ".join(parts)


# ── Key Management ─────────────────────────────────────────────────────────────

def key_exists():
    """Check if the deploy key already exists."""
    return os.path.exists(SSH_KEY_PATH)


def generate_key():
    """Generate an ED25519 SSH key for deployments."""
    key_dir = os.path.dirname(SSH_KEY_PATH)
    os.makedirs(key_dir, mode=0o700, exist_ok=True)
    if os.path.exists(SSH_KEY_PATH):
        return {"ok": True, "message": "Key already exists"}
    result = subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-f", SSH_KEY_PATH,
         "-N", "", "-C", "suparr-deploy", "-q"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return {"ok": False, "message": f"Key generation failed: {result.stderr}"}
    return {"ok": True, "message": "ED25519 key generated"}


def deploy_key(host, user, password):
    """Deploy SSH key to a target host using sshpass."""
    if not os.path.exists(SSH_KEY_PATH):
        gen = generate_key()
        if not gen["ok"]:
            return gen
    result = subprocess.run(
        ["sshpass", "-p", password, "ssh-copy-id"] + SSH_OPTS +
        ["-i", SSH_KEY_PATH, f"{user}@{host}"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return {"ok": False, "message": f"Key deploy failed: {result.stderr.strip()}"}
    return {"ok": True, "message": f"Key deployed to {host}"}


def setup_root_access(host, user, password):
    """If SSH user is not root, set up key-only root login.
    Copies the deploy key to root's authorized_keys and enables
    PermitRootLogin prohibit-password.
    """
    if user == "root":
        return {"ok": True, "message": "Already root"}

    # Test if root key auth already works
    test = test_connection(host, "root")
    if test["ok"]:
        return {"ok": True, "message": "Root key auth already working"}

    # Deploy key to non-root user first
    deploy_result = deploy_key(host, user, password)
    if not deploy_result["ok"]:
        return deploy_result

    # Copy key to root via the non-root user
    pubkey = Path(SSH_KEY_PATH + ".pub").read_text().strip()
    commands = [
        "sudo mkdir -p /root/.ssh",
        "sudo chmod 700 /root/.ssh",
        f"echo {shlex.quote(pubkey)} | sudo tee -a /root/.ssh/authorized_keys > /dev/null",
        "sudo chmod 600 /root/.ssh/authorized_keys",
        "sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config",
        "sudo systemctl restart sshd || sudo service sshd restart",
    ]
    cmd_str = " && ".join(commands)
    result = subprocess.run(
        _ssh_cmd() + [f"{user}@{host}", cmd_str],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return {"ok": False, "message": f"Root setup failed: {result.stderr.strip()}"}

    # Verify root access works
    test = test_connection(host, "root")
    if not test["ok"]:
        return {"ok": False, "message": "Root key deployed but verification failed"}

    return {"ok": True, "message": f"Root access configured on {host}"}


# ── Connectivity ───────────────────────────────────────────────────────────────

def test_connection(host, user="root"):
    """Test SSH connectivity to a host. Returns {ok, message, user}."""
    try:
        result = subprocess.run(
            _ssh_cmd() + [f"{user}@{host}", "echo ok"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and "ok" in result.stdout:
            return {"ok": True, "message": f"Connected to {host}", "user": user}
        return {"ok": False, "message": f"SSH failed: {result.stderr.strip()}", "user": user}
    except subprocess.TimeoutExpired:
        return {"ok": False, "message": f"Connection timed out: {host}", "user": user}
    except FileNotFoundError:
        return {"ok": False, "message": "SSH client not found", "user": user}


def can_sudo(host, user):
    """Check if user has passwordless sudo on host."""
    if user == "root":
        return True
    result = subprocess.run(
        _ssh_cmd() + [f"{user}@{host}", "sudo -n true 2>/dev/null && echo yes || echo no"],
        capture_output=True, text=True, timeout=10
    )
    return result.stdout.strip() == "yes"


# ── File Sync ──────────────────────────────────────────────────────────────────

def rsync_project(host, user="root", project_dir=None):
    """Rsync project files to remote host at /opt/suparr.
    Excludes .env, .git, *.swp, and the deploy/ GUI package.
    """
    src = project_dir or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    src = src.rstrip("/") + "/"
    result = subprocess.run(
        ["rsync", "-az", "--delete",
         "-e", _rsync_ssh(),
         "--exclude", ".env",
         "--exclude", "*.swp",
         "--exclude", ".git",
         "--exclude", ".mal",
         "--exclude", "deploy/",
         src, f"{user}@{host}:{REMOTE_PROJECT_PATH}/"],
        capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        return {"ok": False, "message": f"rsync failed: {result.stderr.strip()}"}
    return {"ok": True, "message": f"Project synced to {host}:{REMOTE_PROJECT_PATH}"}


def rsync_env(host, local_env_path, remote_env_path, user="root"):
    """Sync a single .env file to the remote host."""
    result = subprocess.run(
        ["rsync", "-az",
         "-e", _rsync_ssh(),
         local_env_path, f"{user}@{host}:{remote_env_path}"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return {"ok": False, "message": f".env sync failed: {result.stderr.strip()}"}
    return {"ok": True, "message": f".env synced to {host}:{remote_env_path}"}


def fix_permissions(host, user="root"):
    """Fix script and .env permissions on remote host."""
    sudo = "" if user == "root" else "sudo "
    cmd = (
        f"{sudo}chmod +x {REMOTE_PROJECT_PATH}/scripts/*.sh && "
        f"{sudo}chmod 600 {REMOTE_PROJECT_PATH}/machine*-*/.env 2>/dev/null || true"
    )
    subprocess.run(
        _ssh_cmd() + [f"{user}@{host}", cmd],
        capture_output=True, text=True, timeout=15
    )


# ── .env Merge ─────────────────────────────────────────────────────────────────

def read_remote_env(host, remote_path, user="root"):
    """Read an .env file from the remote host. Returns content string or empty."""
    result = subprocess.run(
        _ssh_cmd() + [f"{user}@{host}", f"cat {shlex.quote(remote_path)} 2>/dev/null"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        return ""
    return result.stdout


def merge_remote_env_keys(host, remote_env_path, local_env_path, user="root"):
    """Preserve populated API keys from remote .env into local .env.
    Matches remote-deploy.sh merge_remote_env_keys() behavior.
    """
    remote_content = read_remote_env(host, remote_env_path, user)
    if not remote_content:
        return 0

    remote_env = parse_env_file(remote_content)
    local_content = Path(local_env_path).read_text(encoding="utf-8")
    local_env = parse_env_file(local_content)

    merged = 0
    for key in MERGE_API_KEYS:
        local_val = local_env.get(key, "")
        if local_val:
            continue  # Local already has a value
        remote_val = remote_env.get(key, "")
        if remote_val:
            # Replace the empty key line with the remote value
            local_content = local_content.replace(
                f"{key}=", f"{key}='{remote_val}'"
            )
            merged += 1

    if merged > 0:
        Path(local_env_path).write_text(local_content, encoding="utf-8")

    return merged


# ── Remote Command Execution ───────────────────────────────────────────────────

def remote_exec(host, command, user="root", timeout=300):
    """Execute a command on a remote host. Returns (returncode, stdout, stderr)."""
    result = subprocess.run(
        _ssh_cmd() + [f"{user}@{host}", command],
        capture_output=True, text=True, timeout=timeout
    )
    return result.returncode, result.stdout, result.stderr


def remote_exec_stream(host, command, user="root"):
    """Execute a command on a remote host with streaming stdout.
    Returns a Popen object with stdout as a pipe.
    """
    return subprocess.Popen(
        _ssh_cmd() + [f"{user}@{host}", command],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
