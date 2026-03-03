"""
SupArr Deploy — Configuration schema, validation, and .env generation.

Defines every config field, its defaults, validation rules, and which .env
file(s) it belongs to. Generates .env files matching the exact format of
remote-deploy.sh (single-quoted values, header comments).
"""

import os
import re
import secrets
from pathlib import Path

# ── Timezones (common subset — covers most users) ─────────────────────────────
TIMEZONES = [
    "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
    "America/Anchorage", "America/Phoenix", "America/Toronto", "America/Vancouver",
    "America/Mexico_City", "America/Sao_Paulo", "America/Argentina/Buenos_Aires",
    "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Amsterdam",
    "Europe/Madrid", "Europe/Rome", "Europe/Stockholm", "Europe/Warsaw",
    "Europe/Moscow", "Europe/Istanbul",
    "Asia/Tokyo", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Singapore",
    "Asia/Kolkata", "Asia/Seoul", "Asia/Dubai", "Asia/Bangkok",
    "Australia/Sydney", "Australia/Melbourne", "Australia/Perth",
    "Pacific/Auckland", "Pacific/Honolulu",
    "Africa/Johannesburg", "Africa/Cairo",
    "UTC",
]

# ── Field Schema ───────────────────────────────────────────────────────────────
# Each field: (key, label, default, section, options)
# options dict keys:
#   secret: bool       — mask in UI, never log
#   optional: bool     — blank is valid
#   envs: list         — which .env files include this field ("plex", "arr")
#   condition: str     — JS-style condition for visibility
#   help: str          — tooltip/help text
#   placeholder: str   — input placeholder
#   type: str          — "text", "password", "select", "toggle", "readonly"
#   choices: list      — for select fields
#   validate: str      — regex pattern for validation

FIELD_SCHEMA = [
    # ── Step 1: Deploy Mode ────────────────────────────────────────────────
    {
        "key": "deploy_mode",
        "label": "Deploy Mode",
        "default": "two",
        "section": "mode",
        "type": "choice",
        "choices": [
            {"value": "two", "label": "Two Machines", "description": "Spyglass (Plex) + Privateer (*arr)"},
            {"value": "single", "label": "Single Machine", "description": "Everything on one box"},
        ],
    },

    # ── Step 2: Target Machines ────────────────────────────────────────────
    {
        "key": "plex_ip",
        "label": "Spyglass (Plex) IP",
        "default": "",
        "section": "targets",
        "type": "text",
        "placeholder": "192.168.1.100",
        "validate": r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$",
        "help": "IP address of the Plex machine",
        "condition": "deploy_mode === 'two'",
    },
    {
        "key": "arr_ip",
        "label": "Privateer (*arr) IP",
        "default": "",
        "section": "targets",
        "type": "text",
        "placeholder": "192.168.1.101",
        "validate": r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$",
        "help": "IP address of the *arr machine",
        "condition": "deploy_mode === 'two'",
    },
    {
        "key": "single_ip",
        "label": "Machine IP",
        "default": "",
        "section": "targets",
        "type": "text",
        "placeholder": "192.168.1.100",
        "validate": r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$",
        "help": "IP address of the single machine",
        "condition": "deploy_mode === 'single'",
    },
    {
        "key": "ssh_user",
        "label": "SSH Username",
        "default": "root",
        "section": "targets",
        "type": "text",
    },
    {
        "key": "ssh_pass",
        "label": "SSH Password",
        "default": "",
        "section": "targets",
        "type": "password",
        "secret": True,
        "help": "Used once to deploy SSH keys, then discarded",
    },
    {
        "key": "nas_ip",
        "label": "NAS IP",
        "default": "",
        "section": "targets",
        "type": "text",
        "optional": True,
        "placeholder": "192.168.1.76",
        "help": "For NFS mounts. Leave blank if no NAS.",
    },

    # ── Step 3: Storage & Network ──────────────────────────────────────────
    {
        "key": "puid",
        "label": "User ID (PUID)",
        "default": "1000",
        "section": "storage",
        "type": "text",
        "validate": r"^\d+$",
    },
    {
        "key": "pgid",
        "label": "Group ID (PGID)",
        "default": "1000",
        "section": "storage",
        "type": "text",
        "validate": r"^\d+$",
    },
    {
        "key": "tz",
        "label": "Timezone",
        "default": "America/Chicago",
        "section": "storage",
        "type": "select",
        "choices": [{"value": tz, "label": tz} for tz in TIMEZONES],
    },
    {
        "key": "plex_media_root",
        "label": "Spyglass Media Root",
        "default": "/mnt/media",
        "section": "storage",
        "type": "text",
        "help": "Where Plex finds media files",
        "condition": "deploy_mode === 'two'",
    },
    {
        "key": "plex_appdata",
        "label": "Spyglass App Data",
        "default": "/opt/media-stack",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'two'",
    },
    {
        "key": "arr_media_root",
        "label": "Privateer Media Root",
        "default": "/mnt/media",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'two'",
    },
    {
        "key": "arr_downloads_root",
        "label": "Privateer Downloads Root",
        "default": "/mnt/downloads",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'two'",
    },
    {
        "key": "arr_appdata",
        "label": "Privateer App Data",
        "default": "/opt/arr-stack",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'two'",
    },
    # Single-machine paths
    {
        "key": "media_root",
        "label": "Media Root",
        "default": "/mnt/media",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'single'",
    },
    {
        "key": "downloads_root",
        "label": "Downloads Root",
        "default": "/mnt/downloads",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'single'",
    },
    {
        "key": "single_plex_appdata",
        "label": "Plex App Data",
        "default": "/opt/media-stack",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'single'",
    },
    {
        "key": "single_arr_appdata",
        "label": "*arr App Data",
        "default": "/opt/arr-stack",
        "section": "storage",
        "type": "text",
        "condition": "deploy_mode === 'single'",
    },
    # NAS exports
    {
        "key": "nas_media_export",
        "label": "NAS Media Export",
        "default": "/var/nfs/shared/media",
        "section": "storage",
        "type": "text",
        "condition": "nas_ip !== ''",
    },
    {
        "key": "nas_downloads_export",
        "label": "NAS Downloads Export",
        "default": "/var/nfs/shared/media/downloads",
        "section": "storage",
        "type": "text",
        "condition": "nas_ip !== ''",
    },
    {
        "key": "nas_backups_export",
        "label": "NAS Backups Export",
        "default": "",
        "section": "storage",
        "type": "text",
        "optional": True,
        "condition": "nas_ip !== ''",
        "help": "For Immich photos, Syncthing. Leave blank to skip.",
    },
    {
        "key": "tailscale_auth_key",
        "label": "Tailscale Auth Key",
        "default": "",
        "section": "storage",
        "type": "text",
        "optional": True,
        "placeholder": "tskey-auth-...",
        "help": "Remote access without port forwarding. Leave blank to skip.",
    },
    {
        "key": "local_subnet",
        "label": "Local Subnet",
        "default": "192.168.1.0/24",
        "section": "storage",
        "type": "text",
        "validate": r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$",
    },

    # ── Step 4: Plex Config ────────────────────────────────────────────────
    {
        "key": "plex_claim_token",
        "label": "Plex Claim Token",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "placeholder": "claim-...",
        "help": "Get from plex.tv/claim — valid ~4 minutes. Can set later.",
    },
    {
        "key": "plex_token",
        "label": "Plex Token",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "For Kometa and *arr Plex integration. Can set later.",
    },
    {
        "key": "plex_ip_for_kometa",
        "label": "Plex Server IP (for Kometa)",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Auto-detected if blank. Set manually if Plex is on a different host.",
    },
    {
        "key": "tmdb_api_key",
        "label": "TMDb API Key",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Free at themoviedb.org/settings/api",
    },
    {
        "key": "mdblist_api_key",
        "label": "MDBList API Key",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Free at mdblist.com/preferences",
    },
    {
        "key": "trakt_client_id",
        "label": "Trakt Client ID",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Create app at trakt.tv/oauth/applications",
    },
    {
        "key": "trakt_client_secret",
        "label": "Trakt Client Secret",
        "default": "",
        "section": "plex",
        "type": "password",
        "secret": True,
        "optional": True,
    },
    # Trakt OAuth tokens — auto-populated by device auth
    {
        "key": "trakt_access_token",
        "label": "Trakt Access Token",
        "default": "",
        "section": "plex",
        "type": "hidden",
        "optional": True,
    },
    {
        "key": "trakt_refresh_token",
        "label": "Trakt Refresh Token",
        "default": "",
        "section": "plex",
        "type": "hidden",
        "optional": True,
    },
    {
        "key": "trakt_expires",
        "label": "Trakt Token Expiry",
        "default": "",
        "section": "plex",
        "type": "hidden",
        "optional": True,
    },
    {
        "key": "trakt_created_at",
        "label": "Trakt Token Created",
        "default": "",
        "section": "plex",
        "type": "hidden",
        "optional": True,
    },

    # ── Step 5: Arr Config ─────────────────────────────────────────────────
    {
        "key": "vpn_type",
        "label": "VPN Type",
        "default": "wireguard",
        "section": "arr",
        "type": "choice",
        "choices": [
            {"value": "wireguard", "label": "WireGuard / NordLynx", "description": "Recommended — faster, lower overhead"},
            {"value": "openvpn", "label": "OpenVPN", "description": "Legacy — wider compatibility"},
        ],
    },
    {
        "key": "nord_wireguard_key",
        "label": "NordLynx Private Key",
        "default": "",
        "section": "arr",
        "type": "password",
        "secret": True,
        "condition": "vpn_type === 'wireguard'",
        "help": "Get from NordVPN Linux app or API",
    },
    {
        "key": "nord_user",
        "label": "Nord Service Username",
        "default": "",
        "section": "arr",
        "type": "text",
        "condition": "vpn_type === 'openvpn'",
        "help": "Service credentials from nordvpn.com/manual-setup — NOT your account email",
    },
    {
        "key": "nord_pass",
        "label": "Nord Service Password",
        "default": "",
        "section": "arr",
        "type": "password",
        "secret": True,
        "condition": "vpn_type === 'openvpn'",
    },
    {
        "key": "nord_country",
        "label": "VPN Country",
        "default": "United States",
        "section": "arr",
        "type": "text",
    },
    {
        "key": "nord_city",
        "label": "VPN City",
        "default": "",
        "section": "arr",
        "type": "text",
        "optional": True,
        "help": "Leave blank for auto-selection",
    },
    {
        "key": "qbit_password",
        "label": "qBittorrent Password",
        "default": "SupArr2026!",
        "section": "arr",
        "type": "password",
        "secret": True,
    },
    {
        "key": "notifiarr_api_key",
        "label": "Notifiarr API Key",
        "default": "",
        "section": "arr",
        "type": "text",
        "optional": True,
        "help": "From notifiarr.com — leave blank to skip",
    },
    {
        "key": "nzbgeek_api_key",
        "label": "NZBgeek API Key",
        "default": "",
        "section": "arr",
        "type": "text",
        "optional": True,
        "help": "Usenet indexer — leave blank to skip",
    },
    {
        "key": "immich_db_password",
        "label": "Immich DB Password",
        "default": "",  # auto-generated if blank
        "section": "arr",
        "type": "password",
        "secret": True,
        "help": "Auto-generated if left blank. Only change if you have a reason.",
    },
    {
        "key": "migrate_library",
        "label": "Import Existing Library",
        "default": "false",
        "section": "arr",
        "type": "toggle",
        "help": "Mount an existing media library for import",
    },
    {
        "key": "migrate_source",
        "label": "Migration Source Path",
        "default": "/mnt/external/media",
        "section": "arr",
        "type": "text",
        "optional": True,
        "condition": "migrate_library === 'true' && nas_ip === ''",
    },
    {
        "key": "migrate_nas_export",
        "label": "Migration NAS Export",
        "default": "/var/nfs/shared/old-media",
        "section": "arr",
        "type": "text",
        "optional": True,
        "condition": "migrate_library === 'true' && nas_ip !== ''",
    },

    # ── Step 6: Notifications ──────────────────────────────────────────────
    {
        "key": "discord_webhook_url",
        "label": "Discord Webhook URL",
        "default": "",
        "section": "notifications",
        "type": "text",
        "optional": True,
        "placeholder": "https://discord.com/api/webhooks/...",
        "help": "Server Settings → Integrations → Webhooks",
    },
    {
        "key": "watchtower_notification_url",
        "label": "Watchtower Notification URL",
        "default": "",
        "section": "notifications",
        "type": "readonly",
        "optional": True,
        "help": "Auto-derived from Discord webhook",
    },
]


def get_schema():
    """Return the full field schema as a list of dicts."""
    return FIELD_SCHEMA


def get_defaults():
    """Return a dict of key→default for all fields."""
    return {f["key"]: f["default"] for f in FIELD_SCHEMA}


# ── Resolve Effective IPs ──────────────────────────────────────────────────────

def resolve_ips(config):
    """Resolve effective Plex/Arr IPs based on deploy mode."""
    if config.get("deploy_mode") == "single":
        ip = config.get("single_ip", "")
        return ip, ip
    return config.get("plex_ip", ""), config.get("arr_ip", "")


def resolve_paths(config):
    """Resolve effective paths based on deploy mode.
    Returns (plex_media_root, plex_appdata, arr_media_root, arr_downloads_root, arr_appdata)
    """
    if config.get("deploy_mode") == "single":
        return (
            config.get("media_root", "/mnt/media"),
            config.get("single_plex_appdata", "/opt/media-stack"),
            config.get("media_root", "/mnt/media"),
            config.get("downloads_root", "/mnt/downloads"),
            config.get("single_arr_appdata", "/opt/arr-stack"),
        )
    return (
        config.get("plex_media_root", "/mnt/media"),
        config.get("plex_appdata", "/opt/media-stack"),
        config.get("arr_media_root", "/mnt/media"),
        config.get("arr_downloads_root", "/mnt/downloads"),
        config.get("arr_appdata", "/opt/arr-stack"),
    )


# ── Validation ─────────────────────────────────────────────────────────────────

def _eval_condition(condition, config):
    """Evaluate a JS-style condition string against config values.
    Handles: key === 'val', key !== 'val', key !== '', and && conjunctions.
    """
    if not condition:
        return True
    # Split on && and evaluate each part
    parts = [p.strip() for p in condition.split("&&")]
    for part in parts:
        # key === 'value'
        m = re.match(r"(\w+)\s*===\s*'([^']*)'", part)
        if m:
            if config.get(m.group(1), "") != m.group(2):
                return False
            continue
        # key !== 'value'
        m = re.match(r"(\w+)\s*!==\s*'([^']*)'", part)
        if m:
            if config.get(m.group(1), "") == m.group(2):
                return False
            continue
        # key !== ''  (non-empty check)
        m = re.match(r"(\w+)\s*!==\s*''", part)
        if m:
            if not config.get(m.group(1), ""):
                return False
            continue
    return True


def validate_section(config, section):
    """Validate all fields in a section. Returns list of error strings."""
    errors = []
    for field in FIELD_SCHEMA:
        if field.get("section") != section:
            continue
        key = field["key"]
        value = config.get(key, "")
        # Skip hidden/readonly
        if field.get("type") in ("hidden", "readonly"):
            continue
        # Skip fields whose condition is not met (invisible in UI)
        if not _eval_condition(field.get("condition", ""), config):
            continue
        # Required check
        if not field.get("optional") and not value and field.get("type") != "toggle":
            errors.append(f"{field['label']} is required")
            continue
        # Regex validation
        pattern = field.get("validate")
        if pattern and value:
            if not re.match(pattern, value):
                errors.append(f"{field['label']}: invalid format")
    return errors


def validate_all(config):
    """Validate entire config. Returns dict of section→[errors]."""
    sections = sorted(set(f["section"] for f in FIELD_SCHEMA))
    result = {}
    for section in sections:
        errs = validate_section(config, section)
        if errs:
            result[section] = errs
    return result


# ── Discord Webhook → Shoutrrr ─────────────────────────────────────────────────

def derive_watchtower_url(discord_url):
    """Convert Discord webhook URL to Watchtower shoutrrr format.
    https://discord.com/api/webhooks/ID/TOKEN → discord://TOKEN@ID
    """
    if not discord_url:
        return ""
    match = re.match(r"https?://discord\.com/api/webhooks/(\d+)/(.+)", discord_url)
    if match:
        return f"discord://{match.group(2)}@{match.group(1)}"
    return ""


# ── .env Generation ────────────────────────────────────────────────────────────

def _q(value):
    """Single-quote a value for .env. Matches remote-deploy.sh format."""
    return f"'{value}'"


def generate_plex_env(config):
    """Generate Spyglass (Plex) .env content matching remote-deploy.sh format."""
    plex_media, plex_appdata, _, _, _ = resolve_paths(config)
    plex_ip, arr_ip = resolve_ips(config)

    # Kometa plex IP: use explicit value, fall back to plex machine IP
    kometa_plex_ip = config.get("plex_ip_for_kometa") or plex_ip

    # Watchtower URL
    wt_url = derive_watchtower_url(config.get("discord_webhook_url", ""))

    lines = [
        "# =============================================================================",
        "# Spyglass (Plex Server) — Generated by SupArr Deploy GUI",
        "# =============================================================================",
        f"PUID={_q(config.get('puid', '1000'))}",
        f"PGID={_q(config.get('pgid', '1000'))}",
        f"TZ={_q(config.get('tz', 'America/Chicago'))}",
        f"MEDIA_ROOT={_q(plex_media)}",
        f"APPDATA={_q(plex_appdata)}",
        f"NAS_IP={_q(config.get('nas_ip', ''))}",
        f"NAS_MEDIA_EXPORT={_q(config.get('nas_media_export', ''))}",
        f"PLEX_CLAIM_TOKEN={_q(config.get('plex_claim_token', ''))}",
        f"PLEX_TOKEN={_q(config.get('plex_token', ''))}",
        f"PLEX_IP={_q(kometa_plex_ip)}",
        f"TAILSCALE_AUTH_KEY={_q(config.get('tailscale_auth_key', ''))}",
        f"LOCAL_SUBNET={_q(config.get('local_subnet', '192.168.1.0/24'))}",
        f"TMDB_API_KEY={_q(config.get('tmdb_api_key', ''))}",
        f"MDBLIST_API_KEY={_q(config.get('mdblist_api_key', ''))}",
        f"TRAKT_CLIENT_ID={_q(config.get('trakt_client_id', ''))}",
        f"TRAKT_CLIENT_SECRET={_q(config.get('trakt_client_secret', ''))}",
        f"TRAKT_ACCESS_TOKEN={_q(config.get('trakt_access_token', ''))}",
        f"TRAKT_REFRESH_TOKEN={_q(config.get('trakt_refresh_token', ''))}",
        f"TRAKT_EXPIRES={_q(config.get('trakt_expires', ''))}",
        f"TRAKT_CREATED_AT={_q(config.get('trakt_created_at', ''))}",
        f"DISCORD_WEBHOOK_URL={_q(config.get('discord_webhook_url', ''))}",
        f"WATCHTOWER_NOTIFICATION_URL={_q(wt_url)}",
    ]
    return "\n".join(lines) + "\n"


def generate_arr_env(config):
    """Generate Privateer (*arr) .env content matching remote-deploy.sh format."""
    _, _, arr_media, arr_downloads, arr_appdata = resolve_paths(config)
    plex_ip, arr_ip = resolve_ips(config)

    kometa_plex_ip = config.get("plex_ip_for_kometa") or plex_ip
    wt_url = derive_watchtower_url(config.get("discord_webhook_url", ""))

    # Auto-generate Immich DB password if blank
    immich_pw = config.get("immich_db_password", "")
    if not immich_pw:
        immich_pw = secrets.token_hex(12)

    lines = [
        "# =============================================================================",
        "# Privateer (*arr Stack) — Generated by SupArr Deploy GUI",
        "# =============================================================================",
        f"PUID={_q(config.get('puid', '1000'))}",
        f"PGID={_q(config.get('pgid', '1000'))}",
        f"TZ={_q(config.get('tz', 'America/Chicago'))}",
        f"MEDIA_ROOT={_q(arr_media)}",
        f"DOWNLOADS_ROOT={_q(arr_downloads)}",
        f"APPDATA={_q(arr_appdata)}",
        f"NAS_IP={_q(config.get('nas_ip', ''))}",
        f"NAS_MEDIA_EXPORT={_q(config.get('nas_media_export', ''))}",
        f"NAS_DOWNLOADS_EXPORT={_q(config.get('nas_downloads_export', ''))}",
        f"NAS_BACKUPS_EXPORT={_q(config.get('nas_backups_export', ''))}",
        f"NORD_VPN_TYPE={_q(config.get('vpn_type', 'wireguard'))}",
        f"NORD_USER={_q(config.get('nord_user', ''))}",
        f"NORD_PASS={_q(config.get('nord_pass', ''))}",
        f"NORD_WIREGUARD_KEY={_q(config.get('nord_wireguard_key', ''))}",
        f"NORD_COUNTRY={_q(config.get('nord_country', 'United States'))}",
        f"NORD_CITY={_q(config.get('nord_city', ''))}",
        f"LOCAL_SUBNET={_q(config.get('local_subnet', '192.168.1.0/24'))}",
        f"TAILSCALE_AUTH_KEY={_q(config.get('tailscale_auth_key', ''))}",
        f"QBIT_PASSWORD={_q(config.get('qbit_password', 'SupArr2026!'))}",
        "RADARR_API_KEY=",
        "SONARR_API_KEY=",
        "LIDARR_API_KEY=",
        "PROWLARR_API_KEY=",
        "BAZARR_API_KEY=",
        "BOOKSHELF_API_KEY=",
        "WHISPARR_API_KEY=",
        "SABNZBD_API_KEY=",
        f"NZBGEEK_API_KEY={_q(config.get('nzbgeek_api_key', ''))}",
        f"NOTIFIARR_API_KEY={_q(config.get('notifiarr_api_key', ''))}",
        f"TRAKT_ACCESS_TOKEN={_q(config.get('trakt_access_token', ''))}",
        f"PLEX_TOKEN={_q(config.get('plex_token', ''))}",
        f"PLEX_IP={_q(kometa_plex_ip)}",
        f"TMDB_API_KEY={_q(config.get('tmdb_api_key', ''))}",
        f"IMMICH_DB_PASSWORD={_q(immich_pw)}",
        f"MIGRATE_LIBRARY={_q(config.get('migrate_library', 'false'))}",
        f"MIGRATE_SOURCE={_q(config.get('migrate_source', ''))}",
        f"MIGRATE_NAS_EXPORT={_q(config.get('migrate_nas_export', ''))}",
        f"DISCORD_WEBHOOK_URL={_q(config.get('discord_webhook_url', ''))}",
        f"WATCHTOWER_NOTIFICATION_URL={_q(wt_url)}",
    ]
    return "\n".join(lines) + "\n"


# ── .env File I/O ──────────────────────────────────────────────────────────────

def write_env(content, path):
    """Write .env content to file with 0600 permissions."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    os.chmod(path, 0o600)


def parse_env_file(content):
    """Parse a .env file into a dict. Handles single-quoted values."""
    result = {}
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        # Strip surrounding single quotes
        if value.startswith("'") and value.endswith("'"):
            value = value[1:-1]
        result[key] = value
    return result


def load_existing_env(project_dir):
    """Load existing .env files and map values back to config keys.
    Returns a partial config dict for pre-filling the form.
    """
    config = {}
    plex_env_path = os.path.join(project_dir, "machine1-plex", ".env")
    arr_env_path = os.path.join(project_dir, "machine2-arr", ".env")

    plex_env = {}
    arr_env = {}
    if os.path.exists(plex_env_path):
        plex_env = parse_env_file(Path(plex_env_path).read_text(encoding="utf-8"))
    if os.path.exists(arr_env_path):
        arr_env = parse_env_file(Path(arr_env_path).read_text(encoding="utf-8"))

    if not plex_env and not arr_env:
        return config

    # Map .env keys back to config keys
    env_to_config = {
        # From plex .env
        "PUID": "puid",
        "PGID": "pgid",
        "TZ": "tz",
        "NAS_IP": "nas_ip",
        "NAS_MEDIA_EXPORT": "nas_media_export",
        "PLEX_CLAIM_TOKEN": "plex_claim_token",
        "PLEX_TOKEN": "plex_token",
        "PLEX_IP": "plex_ip_for_kometa",
        "TAILSCALE_AUTH_KEY": "tailscale_auth_key",
        "LOCAL_SUBNET": "local_subnet",
        "TMDB_API_KEY": "tmdb_api_key",
        "MDBLIST_API_KEY": "mdblist_api_key",
        "TRAKT_CLIENT_ID": "trakt_client_id",
        "TRAKT_CLIENT_SECRET": "trakt_client_secret",
        "TRAKT_ACCESS_TOKEN": "trakt_access_token",
        "TRAKT_REFRESH_TOKEN": "trakt_refresh_token",
        "TRAKT_EXPIRES": "trakt_expires",
        "TRAKT_CREATED_AT": "trakt_created_at",
        "DISCORD_WEBHOOK_URL": "discord_webhook_url",
    }

    # Pull from plex .env first
    for env_key, config_key in env_to_config.items():
        val = plex_env.get(env_key, "")
        if val:
            config[config_key] = val

    # Plex-specific path mapping
    if plex_env.get("MEDIA_ROOT"):
        config["plex_media_root"] = plex_env["MEDIA_ROOT"]
    if plex_env.get("APPDATA"):
        config["plex_appdata"] = plex_env["APPDATA"]

    # Arr-specific mappings
    arr_to_config = {
        "NORD_VPN_TYPE": "vpn_type",
        "NORD_USER": "nord_user",
        "NORD_PASS": "nord_pass",
        "NORD_WIREGUARD_KEY": "nord_wireguard_key",
        "NORD_COUNTRY": "nord_country",
        "NORD_CITY": "nord_city",
        "QBIT_PASSWORD": "qbit_password",
        "NZBGEEK_API_KEY": "nzbgeek_api_key",
        "NOTIFIARR_API_KEY": "notifiarr_api_key",
        "IMMICH_DB_PASSWORD": "immich_db_password",
        "MIGRATE_LIBRARY": "migrate_library",
        "MIGRATE_SOURCE": "migrate_source",
        "MIGRATE_NAS_EXPORT": "migrate_nas_export",
        "NAS_DOWNLOADS_EXPORT": "nas_downloads_export",
        "NAS_BACKUPS_EXPORT": "nas_backups_export",
    }

    for env_key, config_key in arr_to_config.items():
        val = arr_env.get(env_key, "")
        if val:
            config[config_key] = val

    # Arr path mapping
    if arr_env.get("MEDIA_ROOT"):
        config["arr_media_root"] = arr_env["MEDIA_ROOT"]
    if arr_env.get("DOWNLOADS_ROOT"):
        config["arr_downloads_root"] = arr_env["DOWNLOADS_ROOT"]
    if arr_env.get("APPDATA"):
        config["arr_appdata"] = arr_env["APPDATA"]

    return config


# ── Service URL Generation ─────────────────────────────────────────────────────

PLEX_SERVICES = [
    ("Plex", 32400, "/web"),
    ("Tdarr", 8265, ""),
    ("Overseerr", 5055, ""),
    ("Tautulli", 8181, ""),
    ("Uptime Kuma", 3001, ""),
    ("Homepage", 3100, ""),
]

ARR_SERVICES = [
    ("Prowlarr", 9696, ""),
    ("Radarr", 7878, ""),
    ("Sonarr", 8989, ""),
    ("Lidarr", 8686, ""),
    ("Bookshelf", 8787, ""),
    ("Bazarr", 6767, ""),
    ("Whisparr", 6969, ""),
    ("qBittorrent", 8080, ""),
    ("SABnzbd", 8085, ""),
    ("Audiobookshelf", 13378, ""),
    ("Immich", 2283, ""),
    ("Syncthing", 8384, ""),
    ("Stash", 9999, ""),
    ("Homepage", 3101, ""),
    ("Dozzle", 8888, ""),
    ("Notifiarr", 5454, ""),
    ("FileBot", 5800, ""),
    ("Autobrr", 7474, ""),
]


def get_service_urls(config):
    """Generate service URL cards for post-deploy report."""
    plex_ip, arr_ip = resolve_ips(config)
    result = {"plex": [], "arr": []}
    for name, port, path in PLEX_SERVICES:
        result["plex"].append({
            "name": name,
            "url": f"http://{plex_ip}:{port}{path}",
            "port": port,
        })
    for name, port, path in ARR_SERVICES:
        result["arr"].append({
            "name": name,
            "url": f"http://{arr_ip}:{port}{path}",
            "port": port,
        })
    return result
