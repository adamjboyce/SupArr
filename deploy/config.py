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
    # ── Import List Sources ──────────────────────────────────────────────
    {
        "key": "import_tmdb",
        "label": "TMDb Popular",
        "default": "true",
        "section": "plex",
        "type": "toggle",
        "help": "Auto-add popular movies and shows from TMDb. Free API key required.",
    },
    {
        "key": "import_stevenlu",
        "label": "StevenLu Popular",
        "default": "true",
        "section": "plex",
        "type": "toggle",
        "help": "Popular movies list — no API key needed. Radarr only.",
    },
    {
        "key": "import_trakt",
        "label": "Trakt Popular & Trending",
        "default": "false",
        "section": "plex",
        "type": "toggle",
        "help": "Popular and trending from Trakt. Requires free Trakt app credentials + device auth.",
    },
    {
        "key": "import_mdblist",
        "label": "MDBList Custom Lists",
        "default": "false",
        "section": "plex",
        "type": "toggle",
        "help": "Your curated MDBList lists (e.g. RT > 85%). Free API key required.",
    },
    {
        "key": "import_imdb",
        "label": "IMDb Watchlist",
        "default": "false",
        "section": "plex",
        "type": "toggle",
        "help": "Import from a public IMDb watchlist. No API key — just the list URL.",
    },

    # ── API Keys (conditional on import list selection) ───────────────
    {
        "key": "tmdb_api_key",
        "label": "TMDb API Key",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Free at themoviedb.org/settings/api",
        "condition": "import_tmdb === 'true'",
    },
    {
        "key": "mdblist_api_key",
        "label": "MDBList API Key",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Free at mdblist.com/preferences",
        "condition": "import_mdblist === 'true'",
    },
    {
        "key": "imdb_list_id",
        "label": "IMDb List ID",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "placeholder": "ls012345678 or ur12345678",
        "help": "From the IMDb list URL. Watchlist: ur + your user number. Custom list: ls + list ID.",
        "condition": "import_imdb === 'true'",
    },
    {
        "key": "trakt_client_id",
        "label": "Trakt Client ID",
        "default": "",
        "section": "plex",
        "type": "text",
        "optional": True,
        "help": "Create app at trakt.tv/oauth/applications",
        "condition": "import_trakt === 'true'",
    },
    {
        "key": "trakt_client_secret",
        "label": "Trakt Client Secret",
        "default": "",
        "section": "plex",
        "type": "password",
        "secret": True,
        "optional": True,
        "condition": "import_trakt === 'true'",
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
        "key": "vpn_provider",
        "label": "VPN Provider",
        "default": "nordvpn",
        "section": "arr",
        "type": "select",
        "choices": [
            {"value": "nordvpn", "label": "NordVPN"},
            {"value": "mullvad", "label": "Mullvad"},
            {"value": "private internet access", "label": "Private Internet Access (PIA)"},
            {"value": "surfshark", "label": "Surfshark"},
            {"value": "protonvpn", "label": "ProtonVPN"},
            {"value": "windscribe", "label": "Windscribe"},
            {"value": "expressvpn", "label": "ExpressVPN"},
            {"value": "cyberghost", "label": "CyberGhost"},
            {"value": "airvpn", "label": "AirVPN"},
            {"value": "ivpn", "label": "IVPN"},
            {"value": "custom", "label": "Custom OpenVPN Config"},
        ],
        "help": "Gluetun-supported VPN provider. Your VPN subscription credentials go below.",
    },
    {
        "key": "vpn_type",
        "label": "VPN Protocol",
        "default": "wireguard",
        "section": "arr",
        "type": "choice",
        "choices": [
            {"value": "wireguard", "label": "WireGuard", "description": "Recommended — faster, lower overhead"},
            {"value": "openvpn", "label": "OpenVPN", "description": "Legacy — wider compatibility"},
        ],
        "condition": "vpn_provider !== 'custom'",
    },
    # WireGuard credentials
    {
        "key": "vpn_wireguard_key",
        "label": "WireGuard Private Key",
        "default": "",
        "section": "arr",
        "type": "password",
        "secret": True,
        "condition": "vpn_type === 'wireguard'",
        "help": "Get from your VPN provider's manual/WireGuard setup page",
    },
    {
        "key": "vpn_wireguard_addresses",
        "label": "WireGuard Addresses",
        "default": "",
        "section": "arr",
        "type": "text",
        "optional": True,
        "condition": "vpn_type === 'wireguard'",
        "placeholder": "10.x.x.x/32",
        "help": "Required for Mullvad/IVPN. Others auto-detect. Get from your WireGuard config.",
    },
    # OpenVPN credentials
    {
        "key": "vpn_user",
        "label": "VPN Username",
        "default": "",
        "section": "arr",
        "type": "text",
        "condition": "vpn_type === 'openvpn'",
        "help": "Service/manual credentials — often different from your account login",
    },
    {
        "key": "vpn_pass",
        "label": "VPN Password",
        "default": "",
        "section": "arr",
        "type": "password",
        "secret": True,
        "condition": "vpn_type === 'openvpn'",
    },
    # Server selection
    {
        "key": "vpn_server_countries",
        "label": "Server Country",
        "default": "United States",
        "section": "arr",
        "type": "text",
        "condition": "vpn_provider !== 'custom'",
    },
    {
        "key": "vpn_server_cities",
        "label": "Server City",
        "default": "",
        "section": "arr",
        "type": "text",
        "optional": True,
        "condition": "vpn_provider !== 'custom'",
        "help": "Leave blank for auto-selection",
    },
    # Custom OpenVPN
    {
        "key": "vpn_custom_config",
        "label": "Custom OpenVPN Config Path",
        "default": "",
        "section": "arr",
        "type": "text",
        "condition": "vpn_provider === 'custom'",
        "placeholder": "/path/to/custom.ovpn",
        "help": "Will be mounted into the Gluetun container",
    },
    {
        "key": "quality_tier",
        "label": "Quality Tier",
        "default": "hd",
        "section": "arr",
        "type": "choice",
        "choices": [
            {"value": "hd", "label": "HD (1080p)", "description": "Standard quality — ~5-15 GB/movie. Best for most setups."},
            {"value": "uhd", "label": "4K UHD", "description": "Ultra HD + HDR — ~30-80 GB/movie. Needs 4K display + storage."},
            {"value": "both", "label": "Both (1080p + 4K)", "description": "Dual profiles — choose per title. Needs the most storage."},
        ],
        "help": "Sets quality profiles in Radarr/Sonarr via Recyclarr. Can be changed post-deploy.",
    },
    # ── Media Categories ──────────────────────────────────────────────────
    {
        "key": "media_categories",
        "label": "Media Categories",
        "default": "movies,tv,anime,anime-movies,documentaries,concerts,stand-up,music,books,audiobooks,adult",
        "section": "arr",
        "type": "text",
        "help": "Comma-separated. Folders, Plex libraries, and Tdarr libraries are created for each.",
    },

    # ── Tdarr Schedule ───────────────────────────────────────────────────
    {
        "key": "tdarr_schedule",
        "label": "Transcode Schedule",
        "default": "offhours",
        "section": "arr",
        "type": "choice",
        "choices": [
            {"value": "offhours", "label": "Off-Hours (1 AM – 5 PM)", "description": "Avoids competing with Plex during evening viewing"},
            {"value": "always", "label": "24/7", "description": "For dedicated transcode boxes or when you don't care"},
            {"value": "overnight", "label": "Overnight (12 AM – 8 AM)", "description": "Minimal impact, slower throughput"},
        ],
    },

    # ── Download Speed Limits ────────────────────────────────────────────
    {
        "key": "download_speed_limit",
        "label": "Download Speed Limit (MB/s)",
        "default": "0",
        "section": "arr",
        "type": "text",
        "optional": True,
        "placeholder": "0 = unlimited",
        "help": "Applied to both qBittorrent and SABnzbd. 0 or blank = no limit.",
        "validate": r"^\d*$",
    },

    # ── MDBList ──────────────────────────────────────────────────────────
    {
        "key": "mdblist_lists",
        "label": "MDBList List IDs",
        "default": "",
        "section": "arr",
        "type": "text",
        "optional": True,
        "condition": "import_mdblist === 'true'",
        "placeholder": "12345, 67890",
        "help": "Comma-separated list IDs from mdblist.com. Find the ID in the list URL.",
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


# ── Component Registry ────────────────────────────────────────────────────────
# Defines every deployable component, its tier, dependencies, and profile name.
# The picker UI renders from this. Docker Compose profiles control startup.
# "profile" is the compose profile name — services without one always start.

COMPONENT_REGISTRY = {
    # ── ALWAYS ON (no profile, no toggle) ────────────────────────────────────
    # These are infrastructure that every deployment needs.
    "gluetun":          {"tier": "infra",     "label": "Gluetun VPN",              "machine": "arr", "always": True},
    "tailscale":        {"tier": "infra",     "label": "Tailscale",                "machine": "both", "always": True},
    "autoheal":         {"tier": "infra",     "label": "Autoheal",                 "machine": "arr", "always": True},
    "watchtower":       {"tier": "infra",     "label": "Watchtower",               "machine": "both", "always": True},
    "homepage":         {"tier": "infra",     "label": "Homepage Dashboard",       "machine": "both", "always": True},
    "dozzle":           {"tier": "infra",     "label": "Dozzle Log Viewer",        "machine": "arr", "always": True},
    "backup":           {"tier": "infra",     "label": "Config Backup",            "machine": "both", "always": True},
    "maintenance":      {"tier": "infra",     "label": "Disk Maintenance",         "machine": "arr", "always": True},
    "download-monitor": {"tier": "infra",     "label": "Download Monitor",         "machine": "arr", "always": True},
    "unpackerr":        {"tier": "infra",     "label": "Unpackerr",                "machine": "arr", "always": True,
                         "desc": "Auto-extracts archives from downloads. Required for usenet and some torrent releases."},

    # ── DESELECTABLE INFRA (on by default, warning if removed) ───────────────
    "prowlarr":         {"tier": "infra-warn", "label": "Prowlarr",      "machine": "arr", "profile": "svc-prowlarr",    "default": True,
                         "desc": "Central indexer hub. All *arr apps pull search results through this. Disabling means manual indexer config in every app."},
    "flaresolverr":     {"tier": "infra-warn", "label": "FlareSolverr",  "machine": "arr", "profile": "svc-flaresolverr","default": True,
                         "desc": "Cloudflare bypass for indexer sites. Without it, many indexers return empty results."},
    "bazarr":           {"tier": "infra-warn", "label": "Bazarr",        "machine": "arr", "profile": "svc-bazarr",      "default": True,
                         "desc": "Automatic subtitle downloads for movies & TV. Searches 5+ providers, upgrades subs for 7 days."},
    "recyclarr":        {"tier": "infra-warn", "label": "Recyclarr",     "machine": "arr", "profile": "svc-recyclarr",   "default": True,
                         "desc": "Syncs TRaSH quality/release profiles to Radarr and Sonarr. Without it, downloads may grab wrong quality or format."},
    "notifiarr":        {"tier": "infra-warn", "label": "Notifiarr",     "machine": "arr", "profile": "svc-notifiarr",   "default": True,
                         "desc": "Central notification hub for all *arr events to Discord. Requires free account at notifiarr.com."},

    # ── DOWNLOAD CLIENTS (pick at least one) ─────────────────────────────────
    "qbittorrent":      {"tier": "download",   "label": "qBittorrent",   "machine": "arr", "profile": "svc-qbittorrent", "default": True,
                         "desc": "Torrent client running through VPN tunnel."},
    "sabnzbd":          {"tier": "download",   "label": "SABnzbd",       "machine": "arr", "profile": "svc-sabnzbd",     "default": True,
                         "desc": "Usenet download client running through VPN tunnel."},

    # ── CONTENT MANAGERS (pick any) ──────────────────────────────────────────
    "radarr":           {"tier": "content",    "label": "Radarr",        "machine": "arr", "profile": "svc-radarr",      "default": True,
                         "desc": "Movie management — searches, grabs, and organizes your film library."},
    "sonarr":           {"tier": "content",    "label": "Sonarr",        "machine": "arr", "profile": "svc-sonarr",      "default": True,
                         "desc": "TV series management — monitors shows, grabs new episodes automatically."},
    "lidarr":           {"tier": "content",    "label": "Lidarr",        "machine": "arr", "profile": "svc-lidarr",      "default": True,
                         "desc": "Music library management — album tracking, automated downloads."},
    "bookshelf":        {"tier": "content",    "label": "Bookshelf",     "machine": "arr", "profile": "svc-bookshelf",   "default": True,
                         "desc": "Book & audiobook management (Readarr fork with working metadata)."},
    "whisparr":         {"tier": "content",    "label": "Whisparr",      "machine": "arr", "profile": "svc-whisparr",    "default": False,
                         "desc": "Adult content management. Enables Stash + studio tagger on Spyglass.",
                         "enables_on_plex": ["stash", "stash-tagger"]},

    # ── SPYGLASS ADD-ONS ─────────────────────────────────────────────────────
    "stash":            {"tier": "plex-addon",  "label": "Stash",              "machine": "plex", "profile": "svc-stash", "default": False,
                         "desc": "Adult content browser & organizer. Auto-enabled when Whisparr is selected.",
                         "auto_with": "whisparr"},
    "stash-tagger":     {"tier": "plex-addon",  "label": "Stash Studio Tagger","machine": "plex", "profile": "svc-stash", "default": False,
                         "desc": "Auto-tags Stash content with production studios every 30 minutes.",
                         "auto_with": "whisparr"},

    # ── DISC RIPPING ─────────────────────────────────────────────────────────
    "makemkv":          {"tier": "disc-rip",   "label": "MakeMKV",            "machine": "plex", "profile": "svc-makemkv", "default": False,
                         "desc": "Rip Blu-ray and DVD discs to MKV via web UI. Needs optical drive."},
    "handbrake":        {"tier": "disc-rip",   "label": "Handbrake",          "machine": "plex", "profile": "svc-handbrake", "default": False,
                         "desc": "Manual video transcoding with full control. Web UI. Works on any video file."},

    # ── OPTIONAL ADD-ONS ─────────────────────────────────────────────────────
    "autobrr":          {"tier": "optional",   "label": "Autobrr",            "machine": "arr", "profile": "svc-autobrr",  "default": False,
                         "desc": "IRC/torrent auto-grab automation for power users."},
    "weekly-digest":    {"tier": "optional",   "label": "Weekly Digest",      "machine": "arr", "profile": "svc-digest",   "default": True,
                         "desc": "Weekly stats summary to Discord — movies, shows, music added."},
    "immich":           {"tier": "optional",   "label": "Immich",             "machine": "arr", "profile": "svc-immich",   "default": True,
                         "desc": "Google Photos replacement — phone backup with AI face/object search. (4 containers)"},
    "syncthing":        {"tier": "optional",   "label": "Syncthing",          "machine": "arr", "profile": "svc-syncthing","default": True,
                         "desc": "Peer-to-peer file sync — phone photos, documents, backups to NAS."},
    "audiobookshelf":   {"tier": "optional",   "label": "Audiobookshelf",     "machine": "arr", "profile": "svc-audiobookshelf", "default": True,
                         "desc": "Audiobook & podcast server with progress tracking and mobile apps."},
}

# Tier display metadata for the picker UI
COMPONENT_TIERS = [
    {"id": "download",   "label": "Download Clients",            "hint": "Pick at least one",                       "min": 1},
    {"id": "content",    "label": "Content Managers",             "hint": "Pick the media types you want",           "min": 0},
    {"id": "infra-warn", "label": "Infrastructure",               "hint": "On by default — deselecting not recommended", "min": 0, "warn": True},
    {"id": "optional",   "label": "Optional Add-ons",            "hint": "Extra features",                          "min": 0},
    {"id": "disc-rip",   "label": "Disc Ripping",                "hint": "Rip your own Blu-rays and DVDs",          "min": 0},
    {"id": "plex-addon", "label": "Spyglass Add-ons",            "hint": "Runs on the Plex machine",                "min": 0},
]


def get_component_registry():
    """Return the component registry and tier metadata for the picker UI."""
    return {"components": COMPONENT_REGISTRY, "tiers": COMPONENT_TIERS}


def get_selected_profiles(config):
    """Build the COMPOSE_PROFILES value from selected services.
    Returns separate profile strings for plex and arr machines.
    """
    selected = config.get("selected_services", {})
    # If no picker data, default to all components with default=True
    if not selected:
        selected = {k: v.get("default", False) for k, v in COMPONENT_REGISTRY.items()
                    if not v.get("always")}

    # Apply dependency: whisparr enables stash on plex
    if selected.get("whisparr"):
        selected["stash"] = True
        selected["stash-tagger"] = True

    arr_profiles = []
    plex_profiles = []
    for key, comp in COMPONENT_REGISTRY.items():
        profile = comp.get("profile")
        if not profile:
            continue  # always-on services have no profile
        if not selected.get(key, comp.get("default", False)):
            continue
        if comp["machine"] in ("arr", "both"):
            arr_profiles.append(profile)
        if comp["machine"] in ("plex", "both"):
            plex_profiles.append(profile)

    # Deduplicate (stash and stash-tagger share svc-stash)
    return ",".join(sorted(set(plex_profiles))), ",".join(sorted(set(arr_profiles)))


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

    plex_profiles, _ = get_selected_profiles(config)

    lines = [
        "# =============================================================================",
        "# Spyglass (Plex Server) — Generated by SupArr Deploy GUI",
        "# =============================================================================",
        f"COMPOSE_PROFILES={_q(plex_profiles)}",
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

    _, arr_profiles = get_selected_profiles(config)

    lines = [
        "# =============================================================================",
        "# Privateer (*arr Stack) — Generated by SupArr Deploy GUI",
        "# =============================================================================",
        f"COMPOSE_PROFILES={_q(arr_profiles)}",
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
        f"VPN_PROVIDER={_q(config.get('vpn_provider', 'nordvpn'))}",
        f"VPN_TYPE={_q(config.get('vpn_type', 'wireguard'))}",
        f"VPN_USER={_q(config.get('vpn_user', ''))}",
        f"VPN_PASS={_q(config.get('vpn_pass', ''))}",
        f"VPN_WIREGUARD_KEY={_q(config.get('vpn_wireguard_key', ''))}",
        f"VPN_WIREGUARD_ADDRESSES={_q(config.get('vpn_wireguard_addresses', ''))}",
        f"VPN_SERVER_COUNTRIES={_q(config.get('vpn_server_countries', 'United States'))}",
        f"VPN_SERVER_CITIES={_q(config.get('vpn_server_cities', ''))}",
        f"VPN_CUSTOM_CONFIG={_q(config.get('vpn_custom_config', ''))}",
        f"VPN_ENDPOINT_IP={_q(config.get('vpn_endpoint_ip', ''))}",
        f"VPN_ENDPOINT_PORT={_q(config.get('vpn_endpoint_port', ''))}",
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
        f"MDBLIST_API_KEY={_q(config.get('mdblist_api_key', ''))}",
        f"IMDB_LIST_ID={_q(config.get('imdb_list_id', ''))}",
        "# Import list sources (true/false)",
        f"IMPORT_TMDB={_q(config.get('import_tmdb', 'true'))}",
        f"IMPORT_STEVENLU={_q(config.get('import_stevenlu', 'true'))}",
        f"IMPORT_TRAKT={_q(config.get('import_trakt', 'false'))}",
        f"IMPORT_MDBLIST={_q(config.get('import_mdblist', 'false'))}",
        f"IMPORT_IMDB={_q(config.get('import_imdb', 'false'))}",
        f"QUALITY_TIER={_q(config.get('quality_tier', 'hd'))}",
        f"MEDIA_CATEGORIES={_q(config.get('media_categories', 'movies,tv,anime,anime-movies,documentaries,concerts,stand-up,music,books,audiobooks,adult'))}",
        f"TDARR_SCHEDULE={_q(config.get('tdarr_schedule', 'offhours'))}",
        f"DOWNLOAD_SPEED_LIMIT={_q(config.get('download_speed_limit', '0'))}",
        f"MDBLIST_LISTS={_q(config.get('mdblist_lists', ''))}",
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
        "VPN_PROVIDER": "vpn_provider",
        "VPN_TYPE": "vpn_type",
        "VPN_USER": "vpn_user",
        "VPN_PASS": "vpn_pass",
        "VPN_WIREGUARD_KEY": "vpn_wireguard_key",
        "VPN_WIREGUARD_ADDRESSES": "vpn_wireguard_addresses",
        "VPN_SERVER_COUNTRIES": "vpn_server_countries",
        "VPN_SERVER_CITIES": "vpn_server_cities",
        "VPN_CUSTOM_CONFIG": "vpn_custom_config",
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
    ("Stash", 9999, ""),
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
