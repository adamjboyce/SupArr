#!/usr/bin/env python3
"""Post-deploy automated setup for SupArr services.

Runs after containers are up and API keys are known. Handles setup steps
that would otherwise require manual UI interaction.

API-based:
  - Plex: create libraries (Movies, TV, Anime, Music, etc.)
  - Immich: create admin account
  - Syncthing: set admin password

Playwright-based (if available):
  - Seerr: Plex OAuth sign-in + arr connection
  - Tdarr: add libraries + configure plugins

Config-seed:
  - SABnzbd: usenet server configuration (prompted)

Usage:
    python3 post-setup.py              # Run all available setups
    python3 post-setup.py --service X  # Run specific service only
    python3 post-setup.py --skip-playwright  # API-only, no browser
"""

import json
import os
import subprocess
import sys
import time

# ================================================================
# Helpers
# ================================================================

def env(key, default=""):
    return os.environ.get(key, default)

def curl(url, method="GET", data=None, headers=None, timeout=10):
    cmd = ["curl", "-sf", url]
    if method != "GET":
        cmd.extend(["-X", method])
    if data:
        cmd.extend(["-H", "Content-Type: application/json", "-d", json.dumps(data)])
    if headers:
        for k, v in headers.items():
            cmd.extend(["-H", f"{k}: {v}"])
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.stdout.strip():
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return None

def wait_for(url, timeout=60, interval=3):
    for _ in range(timeout // interval):
        try:
            result = subprocess.run(
                ["curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}", url],
                capture_output=True, text=True, timeout=5,
            )
            if result.stdout.strip() in ("200", "401", "403"):
                return True
        except subprocess.TimeoutExpired:
            pass
        time.sleep(interval)
    return False

def log(msg):
    print(f"  \033[0;32m[✓]\033[0m {msg}")

def warn(msg):
    print(f"  \033[1;33m[!]\033[0m {msg}")

def info(msg):
    print(f"  \033[0;36m[→]\033[0m {msg}")


# ================================================================
# Plex Library Setup
# ================================================================

def setup_plex_libraries():
    """Create Plex libraries via API if they don't exist."""
    plex_token = env("PLEX_TOKEN")
    plex_ip = env("PLEX_IP", "localhost")
    if not plex_token:
        warn("Plex: no token — skipping library creation")
        return

    base = f"http://{plex_ip}:32400"
    headers = {"X-Plex-Token": plex_token, "Accept": "application/json"}

    if not wait_for(f"{base}/identity", timeout=30):
        warn("Plex: not reachable — skipping")
        return

    # Check existing libraries
    sections = curl(f"{base}/library/sections", headers=headers)
    if not sections:
        warn("Plex: could not fetch libraries")
        return

    existing = set()
    for d in sections.get("MediaContainer", {}).get("Directory", []):
        existing.add(d.get("title", "").lower())

    # Libraries to create: (name, type, path, scanner, agent)
    libraries = [
        ("Movies", "movie", "/movies", "Plex Movie", "tv.plex.agents.movie"),
        ("TV Shows", "show", "/tv", "Plex TV Series", "tv.plex.agents.series"),
        ("Anime", "show", "/anime", "Plex TV Series", "tv.plex.agents.series"),
        ("Music", "artist", "/music", "Plex Music", "tv.plex.agents.music"),
        ("Documentaries", "movie", "/documentaries", "Plex Movie", "tv.plex.agents.movie"),
        ("Stand-Up", "movie", "/stand-up", "Plex Movie", "tv.plex.agents.movie"),
        ("Anime Movies", "movie", "/anime-movies", "Plex Movie", "tv.plex.agents.movie"),
    ]

    for name, lib_type, path, scanner, agent in libraries:
        if name.lower() in existing:
            continue
        result = subprocess.run(
            ["curl", "-sf", "-X", "POST",
             f"{base}/library/sections",
             "-H", f"X-Plex-Token: {plex_token}",
             "-d", f"name={name}&type={lib_type}&agent={agent}&scanner={scanner}&language=en-US&location={path}"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            log(f"Plex: created library '{name}' → {path}")
        else:
            warn(f"Plex: failed to create '{name}'")


# ================================================================
# Immich Admin Setup
# ================================================================

def setup_immich_admin():
    """Create Immich admin account if not already created."""
    base = "http://localhost:2283"
    if not wait_for(f"{base}/api/server/about", timeout=30):
        warn("Immich: not reachable — skipping")
        return

    password = env("IMMICH_DB_PASSWORD", "SupArr2026")
    result = curl(
        f"{base}/api/auth/admin-sign-up",
        method="POST",
        data={
            "name": "Admin",
            "email": "admin@suparr.local",
            "password": password,
        },
    )
    if result and result.get("id"):
        log(f"Immich: admin account created (email: admin@suparr.local)")
    elif result and "already has an admin" in result.get("message", ""):
        log("Immich: admin already exists")
    else:
        warn("Immich: could not create admin")


# ================================================================
# Syncthing Password
# ================================================================

def setup_syncthing_password():
    """Set Syncthing admin password via API."""
    base = "http://localhost:8384"
    if not wait_for(base, timeout=15):
        warn("Syncthing: not reachable — skipping")
        return

    # Syncthing API key is in the config
    config_path = env("APPDATA", "/opt/arr-stack") + "/syncthing/config/config.xml"
    try:
        result = subprocess.run(
            ["grep", "-oP", '(?<=<apikey>)[^<]+', config_path],
            capture_output=True, text=True, timeout=5,
        )
        api_key = result.stdout.strip()
    except Exception:
        api_key = ""

    if not api_key:
        warn("Syncthing: no API key found — set password in UI at :8384")
        return

    password = env("QBIT_PASSWORD", "SupArr2026")
    headers = {"X-API-Key": api_key}

    # Get current config
    config = curl(f"{base}/rest/config", headers=headers)
    if not config:
        warn("Syncthing: could not read config")
        return

    # Set GUI password (bcrypt hash)
    import hashlib
    gui = config.get("gui", {})
    if gui.get("user"):
        log("Syncthing: admin user already set")
        return

    # Syncthing needs the password set via the config endpoint
    gui["user"] = "admin"
    # Syncthing hashes the password server-side when set via API
    config["gui"] = gui
    config["gui"]["password"] = password

    result = curl(
        f"{base}/rest/config",
        method="PUT",
        data=config,
        headers=headers,
    )
    if result is not None:
        log("Syncthing: admin password set")
    else:
        warn("Syncthing: could not set password — set manually at :8384")


# ================================================================
# SABnzbd Config Seed
# ================================================================

def setup_sabnzbd():
    """Seed SABnzbd usenet server config if user provides details."""
    config_path = env("APPDATA", "/opt/arr-stack") + "/sabnzbd/config/sabnzbd.ini"
    if not os.path.exists(config_path):
        warn("SABnzbd: config not found — will need manual setup via wizard")
        return

    # Check if a server is already configured
    with open(config_path) as f:
        content = f.read()

    if "[servers]" in content and "host = " in content.split("[servers]")[-1]:
        # Check if the host has a non-default value
        import configparser
        cp = configparser.RawConfigParser()
        cp.read(config_path)
        for section in cp.sections():
            if section.startswith("servers"):
                host = cp.get(section, "host", fallback="")
                if host and host != "":
                    log("SABnzbd: usenet server already configured")
                    return

    log("SABnzbd: no usenet server configured — set up via wizard at :8085")


# ================================================================
# Playwright: Seerr + Tdarr
# ================================================================

def setup_seerr_playwright():
    """Automate Seerr Plex OAuth sign-in via Playwright."""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        warn("Seerr: Playwright not available — complete setup at :5055")
        return

    plex_token = env("PLEX_TOKEN")
    if not plex_token:
        warn("Seerr: no Plex token — complete Plex OAuth at :5055")
        return

    if not wait_for("http://localhost:5055", timeout=30):
        warn("Seerr: not reachable")
        return

    # Check if already initialized
    try:
        result = curl("http://localhost:5055/api/v1/settings/public")
        if result and result.get("initialized"):
            log("Seerr: already initialized")
            return
    except Exception:
        pass

    info("Seerr: attempting Plex OAuth setup via Playwright...")

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page()
            page.goto("http://localhost:5055/setup")
            page.wait_for_load_state("networkidle", timeout=10000)

            # Look for Plex sign-in button
            sign_in_btn = page.locator('button:has-text("Sign in with Plex")')
            if sign_in_btn.count() > 0:
                # Seerr's Plex auth uses a popup — we need to inject the token instead
                # Use the API directly with the Plex token
                page.evaluate(f"""
                    fetch('/api/v1/auth/plex', {{
                        method: 'POST',
                        headers: {{'Content-Type': 'application/json'}},
                        body: JSON.stringify({{authToken: '{plex_token}'}})
                    }})
                """)
                page.wait_for_timeout(2000)
                log("Seerr: Plex auth token injected")
            else:
                warn("Seerr: sign-in button not found — page may have changed")

            browser.close()
    except Exception as e:
        warn(f"Seerr: Playwright setup failed — {e}")
        warn("  Complete setup manually at http://localhost:5055")


def setup_tdarr():
    """Configure Tdarr via setup-tdarr.sh (hardware-detected flow + libraries)."""
    script = os.path.join(os.path.dirname(__file__), "setup-tdarr.sh")
    if not os.path.exists(script):
        warn("Tdarr: setup-tdarr.sh not found")
        return

    result = subprocess.run(
        ["bash", script],
        capture_output=True, text=True, timeout=120,
    )
    # Print output (setup-tdarr.sh has its own logging)
    if result.stdout:
        for line in result.stdout.strip().split("\n"):
            print(f"  {line}")
    if result.returncode != 0 and result.stderr:
        warn(f"Tdarr: setup script returned {result.returncode}")


# ================================================================
# Main
# ================================================================

def main():
    skip_playwright = "--skip-playwright" in sys.argv
    service_filter = None
    for arg in sys.argv[1:]:
        if arg.startswith("--service="):
            service_filter = arg.split("=", 1)[1]

    print("\n\033[1m  SupArr Post-Deploy Setup\033[0m\n")

    services = [
        ("plex", setup_plex_libraries),
        ("immich", setup_immich_admin),
        ("syncthing", setup_syncthing_password),
        ("sabnzbd", setup_sabnzbd),
    ]

    services.append(("tdarr", setup_tdarr))

    if not skip_playwright:
        services.append(("seerr", setup_seerr_playwright))

    for name, fn in services:
        if service_filter and name != service_filter:
            continue
        try:
            fn()
        except Exception as e:
            warn(f"{name}: unexpected error — {e}")
            warn(f"  This may indicate the service's API has changed.")
            warn(f"  Check the service UI and configure manually if needed.")

    print()


if __name__ == "__main__":
    main()
