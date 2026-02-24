# SupArr — Automated Deployment

Two machines. One NAS. One script. Pirate names.

- **Spyglass** = Plex machine (you look through it to see things)
- **Privateer** = *arr machine (licensed pirate ship running the fleet)

## Quick Start

### Option A: Remote Deploy (from your desktop)

```bash
tar -xzf suparr.tar.gz
cd media-stack-final
./remote-deploy.sh     # Prompts for everything. Deploys both machines in parallel.
```

Run from WSL2, Linux, or macOS. Collects all config up front, SSHs into both machines, deploys in parallel. Supports two-machine or single-machine mode.

### Option B: On-Machine Deploy

```bash
tar -xzf suparr.tar.gz
cd media-stack-final
sudo ./setup.sh        # Prompts for everything. Deploys. Configures.
```

Run directly on each machine. Auto-detects role (iGPU = Spyglass, high RAM = Privateer), asks for creds interactively, writes `.env`, installs everything, starts all containers, and configures them via API.

### Option C: Direct (No Prompts)

```bash
# Privateer (start here)
cd media-stack-final/machine2-arr
cp .env.example .env && nano .env
sudo ../scripts/init-machine2-arr.sh

# Spyglass
cd media-stack-final/machine1-plex
cp .env.example .env && nano .env
sudo ../scripts/init-machine1-plex.sh
```

### Option D: Single Machine (Everything on One Box)

```bash
sudo ./setup.sh        # Choose option 3: "Both — Single Machine"
```

Or via remote deploy: `./remote-deploy.sh` and choose "Single Machine" mode.

Both stacks run on one machine with separate APPDATA directories. Homepage runs on port 3100 (Spyglass) and 3101 (Privateer). Tailscale gets unique container names to avoid conflicts.

All scripts are **re-run safe** — skip already-configured items on re-run.

## What's Automated

### Privateer (*arr stack) — `init-machine2-arr.sh`
- System packages + Docker installation
- Machine hostname set to `privateer`
- NFS mounts to NAS (media + downloads, enables hardlinks)
- Directory structure (app data, media folders, download dirs)
- qBittorrent pre-seeded with correct paths, categories, seed ratios
- All containers started (with `--remove-orphans`)
- **API keys auto-collected** from freshly started containers → saved to .env
- Detects changed API keys on re-run (not just empty ones)
- Radarr: root folders (movies, docs, stand-up, concerts, anime-movies), qBit + SABnzbd download clients, naming conventions
- Sonarr: root folders (tv, anime), download clients, naming
- Lidarr: root folder (music), download client
- Readarr: root folders (books, audiobooks), download client
- Whisparr: root folder (adult), download client
- Prowlarr → Radarr/Sonarr/Lidarr connections established
- Prowlarr → FlareSolverr proxy added
- Recyclarr TRaSH Guide quality profiles synced (keys always substituted)
- qBittorrent password changed from default
- Bazarr → Sonarr/Radarr connected, English + forced subs configured
- Download client passwords synced across all *arr apps
- **Auto-redownload on failure** enabled (failed download → auto-search for alternative)
- **Discord notifications** for all *arr apps (grab, import, health issues) — if webhook configured
- **Download health monitor** — detects and removes stalled torrents, auto-searches replacements
- **Import lists** — Trakt Popular/Trending + TMDb Popular auto-configured for Radarr/Sonarr (if tokens provided)
- **Plex Connect** — library scan notification on import for Radarr/Sonarr/Lidarr/Readarr (if Plex token provided)
- **Config backup** — weekly tar+gzip with 7-day rotation + Discord notification
- **Maintenance robot** — daily disk space alerts, stale download cleanup, empty directory cleanup
- **Weekly digest** — summarizes recently imported content to Discord
- Docker healthchecks on all services

### Spyglass (Plex) — `init-machine1-plex.sh`
- System packages + Intel iGPU drivers (non-free)
- Machine hostname set to `spyglass`
- iGPU verification (/dev/dri/renderD128)
- Docker installation
- NFS mount to NAS
- Kometa config deployed with API keys + Trakt OAuth tokens from .env
- Kometa enhanced: content_rating, country, franchise, based collections; Anime + Music libraries
- Homepage dashboard template deployed
- **Config backup** — weekly tar+gzip with 7-day rotation + Discord notification
- All containers started (with `--remove-orphans`)
- **Plex preferences patched:**
  - Hardware transcoding enabled (Quick Sync)
  - Subtitle mode: "Shown with foreign audio" (the forced subs fix)
  - Transcoder: prefer higher speed
  - Transcode temp dir on local SSD
- **Uptime Kuma** monitoring dashboard
- Docker healthchecks on all services

### Remote Deploy (`remote-deploy.sh`)
- Prerequisites check (ssh, sshpass, rsync)
- **Two-machine or single-machine** deploy mode
- Collects ALL config in one interactive session on the desktop
- Input validation (IPs, absolute paths)
- Generates SSH key pair and pushes to targets
- Generates machine-specific `.env` files
- Rsyncs project files to `/opt/suparr` on each target
- Two-machine: launches init scripts **in parallel**
- Single-machine: runs init scripts **sequentially**
- Post-deploy summary with all service URLs and cross-machine config hints
- **Trakt device auth** — interactive OAuth flow during setup, tokens propagated to Kometa + import lists
- **Overseerr Plex Watchlist** sync auto-enabled
- **Post-deploy polling:** waits for Overseerr setup wizard + Plex libraries, then auto-configures Overseerr → Radarr/Sonarr and triggers Kometa first run

## Manual Finishing Touches

Both scripts print a summary. The main items:

**Privateer:**
- Prowlarr: add your actual indexers (credentials required)
- SABnzbd: run setup wizard, add Usenet servers
- Bazarr: add subtitle providers (OpenSubtitles.com)
- Radarr Lists: create MDBList filters (RT > 85%, etc.) and add to Radarr → Settings → Lists

**Spyglass:**
- Plex: complete setup wizard, add libraries, claim server
- Tdarr: add libraries, plugins (Migz5ConvertContainer → Migz1FFMPEG → Migz3CleanAudio → Migz4CleanSubs), set Migz4CleanSubs to **KEEP forced subtitle tracks**
- Overseerr: sign in with Plex (Radarr/Sonarr auto-configured when using setup.sh or remote-deploy.sh)
- Kometa: auto-triggered when Plex libraries are detected (manual if using direct mode: `docker exec kometa python kometa.py --run`)
- Tautulli: add Discord webhook for playback notifications
- Uptime Kuma (http://localhost:3001): create admin account, add monitors for all services

## Monitoring & Notifications

### Discord Notifications
Provide a Discord webhook URL during setup. One URL covers everything:
- **\*arr apps** (Radarr, Sonarr, Lidarr, Readarr, Prowlarr): grab started, import complete, upgrades, health issues
- **Watchtower** (both machines): container image updates (auto-derived shoutrrr format)
- **Download monitor**: stalled torrent removal alerts

Tautulli Discord notifications require manual setup (30-second config in the Tautulli UI).

### Uptime Kuma
Dashboard at `http://SPYGLASS_IP:3001`. Manual setup — add monitors pointing to each service's healthcheck endpoint. All services have Docker healthchecks so you can use the Docker container monitor type.

### Download Health Monitor
Runs on Privateer as a lightweight Alpine container. Checks all *arr queues every hour for stalled torrents (warning status > 6 hours). Removes stalled items with blocklist so *arr auto-searches for alternatives. Combined with `autoRedownloadFailed`, the flow is:

1. Download fails or stalls → monitor removes it + blocklists
2. *arr automatically searches for alternative release
3. Discord notification sent

Configure thresholds via environment variables in the compose file (`STALL_THRESHOLD_HOURS`, `CHECK_INTERVAL`).

### Docker Healthchecks
Every service with a web UI or API has a Docker healthcheck. This enables:
- `docker ps` shows health status at a glance
- Uptime Kuma can monitor container health directly
- Dependent services (qBit/SABnzbd) wait for gluetun to be healthy before starting

## Content Discovery

Content finds you — no more manual searching.

### Trakt Import Lists
During setup, provide your Trakt client ID + secret. The setup script runs an interactive **device auth flow** — you visit a URL, enter a code, and tokens are auto-populated everywhere they're needed (Kometa config, import lists).

Radarr and Sonarr get auto-configured import lists:
- **Trakt Popular** — top 100 popular movies/shows
- **Trakt Trending** — top 50 currently trending
- **TMDb Popular** — TMDb's popular list (if TMDb API key provided)

All import lists auto-search on add, so new trending content gets grabbed automatically.

### Plex Watchlist via Overseerr
Overseerr's Plex Watchlist sync is auto-enabled. Add something to your Plex Watchlist from any device → Overseerr picks it up → sends to Radarr/Sonarr → downloads automatically.

### Plex Connect (Library Scan on Import)
When *arr apps finish importing content, they notify Plex to scan the library immediately. No more waiting for scheduled scans — new content appears in Plex within seconds of import completing. Configured for Radarr, Sonarr, Lidarr, and Readarr.

## Kometa — Library Aesthetics

Kometa makes your Plex look like a real streaming service with auto-generated collections and poster overlays.

**Movies** — collections: basic, IMDb, TMDb, Trakt, universe (MCU, Star Wars, etc.), studio, seasonal, award, decade, genre, resolution, audio language, subtitle language, content rating, country, franchise, based on. Overlays: resolution, audio codec, video format, ratings, streaming availability.

**TV Shows** — collections: basic, TMDb, Trakt, network, genre, resolution, content rating, country, based on. Overlays: resolution, audio codec, video format, ratings, streaming, status (returning/ended/canceled).

**Anime** — collections: basic, MyAnimeList, genre. Overlays: resolution, ratings, streaming. Mass rating from MAL.

**Music** — collections: genre.

Trakt OAuth tokens are pre-populated via the device auth flow, so Kometa has full Trakt access from first run.

## Maintenance Automation

### Config Backup
Both machines run a weekly backup container that tar+gzips the entire APPDATA directory, keeps 7 days of backups, and sends Discord notifications. Backups stored at `${APPDATA}/backups/`.

### Maintenance Robot (Privateer)
Daily maintenance cycle:
1. **Disk space monitoring** — alerts Discord when any mount exceeds 85% usage
2. **Stale download cleanup** — removes incomplete downloads older than 7 days (`.!qB` for qBit, `.nzb.tmp` for SABnzbd)
3. **Empty directory cleanup** — removes empty media subdirectories left behind after *arr removes content

### Weekly Content Digest
Queries *arr history APIs every 7 days and sends a formatted Discord summary of recently imported movies, TV shows, and music albums.

## 40TB Library Import

FileBot container is deployed on Privateer for large library imports:
- **FileBot UI**: `http://localhost:5800`
- Point FileBot at your existing library → rename/organize into the correct folder structure
- *arr apps detect new content via library scan
- Hardlinks work because downloads and media are on the same NFS filesystem
- For very large imports, use FileBot to organize first, then trigger a manual *arr library scan

## OS Compatibility

Init scripts auto-detect the package manager and install distro-appropriate packages.

| Distro | Package Manager | Status |
|--------|----------------|--------|
| Debian 12 / Ubuntu 22+ | apt | Fully tested |
| Fedora / RHEL 9+ | dnf | Supported |
| Arch Linux | pacman | Supported |

Docker installation uses `get.docker.com` which works across all supported distros. Intel iGPU driver packages are mapped per-distro (Spyglass only).

## Re-Running

All scripts are **idempotent** — safe to re-run at any time:
- API keys are re-read live and compared (detects rotated keys)
- Recyclarr/Kometa credentials always re-substituted
- Config templates only deployed if missing (creds always updated)
- `--remove-orphans` cleans up any renamed containers
- qBit password: tries custom password first (fast on re-run), falls back to default

Useful re-run scenarios:
- Adding SABnzbd API key after running its setup wizard
- Updating Prowlarr connections after manual indexer setup
- Re-syncing Recyclarr after config changes

## Architecture

```
  Spyglass (Plex)                        Privateer (*arr)
  ┌─────────────────────────┐            ┌──────────────────────────────┐
  │ Plex (Quick Sync HW)    │            │ Gluetun (NordVPN)           │
  │ Tdarr (H.265 encoding)  │            │   ├── qBittorrent (masked)  │
  │ Kometa (aesthetics)      │            │   └── SABnzbd (masked)      │
  │ Overseerr (requests)     │            │ Prowlarr + FlareSolverr     │
  │ Tautulli (analytics)     │            │ Radarr, Sonarr, Lidarr      │
  │ Uptime Kuma (monitoring) │            │ Readarr, Bazarr, Whisparr   │
  │ Homepage (:3100)         │            │ Recyclarr, Autobrr, FileBot │
  │ Tailscale (remote)       │            │ Unpackerr, Notifiarr        │
  │ Backup (weekly)          │            │ Download Monitor (health)    │
  └────────┬────────────────┘            │ Backup, Maintenance, Digest  │
           │                              │ Homepage (:3101), Dozzle     │
           └──────────────┬──────────────┤ Tailscale (remote)           │
                          │              └──────────┬───────────────────┘
                 ┌────────┴─────────────────────────┘
                 │        NAS (NFS)
                 │  /media   /downloads
                 └──────────────────────
```

Single-machine mode: both stacks run on the same box, different APPDATA dirs.

## Hardware Recommendations

| | Spyglass (Plex) | Privateer (*arr) | Single Machine |
|---|---|---|---|
| **CPU** | Intel with Quick Sync (6th gen+) | Any modern CPU | Intel with Quick Sync |
| **RAM** | 16 GB min, 32 GB recommended | 32 GB min, 64 GB+ for large libraries | 64 GB+ recommended |
| **Storage** | SSD for app data + transcode temp | SSD for app data + download scratch | SSD for both workloads |
| **Network** | Fast link to NAS | Fast link to NAS | N/A (local) |

**Notes:**
- Intel Quick Sync is what makes Plex hardware transcoding work — AMD and NVIDIA GPUs can work but need different driver setup (not automated by this script)
- More RAM on Privateer helps when running 10+ containers with large library databases
- SSD for Plex transcoding temp avoids I/O bottlenecks during playback
- 10 GbE between machines and NAS is ideal for large libraries but gigabit works fine for most setups

## File Structure
```
media-stack-final/
├── setup.sh                               ← On-machine interactive setup (1/2/both)
├── remote-deploy.sh                       ← Desktop remote deploy (two-machine or single)
├── README.md
├── scripts/
│   ├── init-machine1-plex.sh              ← Spyglass init (called by setup/remote-deploy)
│   ├── init-machine2-arr.sh               ← Privateer init (called by setup/remote-deploy)
│   ├── download-monitor.sh               ← Stall detection + auto-removal (runs in container)
│   ├── backup.sh                          ← Config backup with rotation (runs in container)
│   ├── maintenance.sh                     ← Disk monitoring + cleanup (runs in container)
│   └── weekly-digest.sh                   ← Weekly content summary (runs in container)
├── machine1-plex/
│   ├── .env.example
│   ├── docker-compose.yml                 ← +backup-spyglass container
│   └── config-templates/
│       ├── kometa.yml                     ← Movies, TV, Anime, Music libraries
│       └── homepage-services.yaml
└── machine2-arr/
    ├── .env.example
    ├── docker-compose.yml                 ← +backup-privateer, maintenance, weekly-digest
    ├── config-seeds/
    │   └── qbittorrent/
    │       └── qBittorrent.conf
    └── config-templates/
        └── recyclarr.yml
```

## Key Settings Baked In

| Setting | Where | Value |
|---------|-------|-------|
| Plex HW transcoding | Preferences.xml | Quick Sync enabled |
| Plex subtitle mode | Preferences.xml | "Shown with foreign audio" |
| Bazarr forced subs | API automated | English Normal + Forced = Both |
| Bazarr connections | API automated | Sonarr + Radarr connected |
| Tdarr subtitle cleanup | Manual (printed) | Keep forced tracks |
| Tdarr codec target | Manual (printed) | H.265, MKV container |
| Tdarr audio cleanup | Manual (printed) | Keep English + original language |
| Radarr naming | API automated | `{Movie Title} ({Release Year}) [{Quality Full}]` |
| Sonarr naming | API automated | `{Series Title} - S{season:00}E{episode:00} - {Episode Title}` |
| qBittorrent password | API automated | Set during setup prompts |
| qBittorrent seed ratio | Pre-seeded config | 2.0 ratio / 7 day max |
| Recyclarr profiles | Config template | TRaSH Guide HD Bluray + WEB / WEB-1080p |
| VPN kill switch | Gluetun default | Automatic — no leak possible |
| Download categories | API automated | radarr, sonarr, lidarr, readarr, whisparr |
| Readarr root folders | API automated | /books, /audiobooks |
| Whisparr root folder | API automated | /adult |
| Auto-redownload | API automated | Failed downloads trigger automatic re-search |
| Discord notifications | API automated | All *arr apps → grab, import, health events |
| Stall detection | download-monitor | 6h threshold, 1h check interval |
| Watchtower notifications | .env derived | Auto-converted from Discord webhook to shoutrrr |
| Trakt import lists | API automated | Popular (100) + Trending (50) for Radarr/Sonarr |
| TMDb import lists | API automated | TMDb Popular for Radarr/Sonarr |
| Plex Connect | API automated | Library scan on import for all *arr apps |
| Overseerr Watchlist | API automated | Plex Watchlist sync enabled |
| Config backup | backup container | Weekly, 7-day retention |
| Disk monitoring | maintenance container | Alert at 85% usage, daily check |
| Stale download cleanup | maintenance container | Remove incomplete >7 days |
| Weekly digest | weekly-digest container | Discord summary every 7 days |

## Configuration Variables

| Variable | Where | Description |
|----------|-------|-------------|
| `DISCORD_WEBHOOK_URL` | Both .env files | Discord webhook for all notifications (optional) |
| `WATCHTOWER_NOTIFICATION_URL` | Both .env files | Auto-derived from Discord webhook (shoutrrr format) |
| `TRAKT_CLIENT_ID` | Plex .env | Trakt OAuth app client ID (for Kometa + import lists) |
| `TRAKT_CLIENT_SECRET` | Plex .env | Trakt OAuth app client secret |
| `TRAKT_ACCESS_TOKEN` | Both .env files | Auto-populated by device auth flow in setup.sh |
| `TRAKT_REFRESH_TOKEN` | Plex .env | Auto-populated by device auth flow |
| `PLEX_TOKEN` | Both .env files | Plex auth token (for Kometa + Plex Connect notifications) |
| `PLEX_IP` | Both .env files | Plex server IP (for Kometa + Plex Connect) |
| `TMDB_API_KEY` | Both .env files | TMDb API key (for Kometa + import lists) |
| `STALL_THRESHOLD_HOURS` | Privateer compose | Hours before stalled torrent is removed (default: 6) |
| `CHECK_INTERVAL` | Privateer compose | Seconds between download health checks (default: 3600) |
| `DISK_ALERT_THRESHOLD` | Privateer compose | Disk usage % to trigger alert (default: 85) |
| `BACKUP_RETENTION_DAYS` | Both compose files | Days to keep config backups (default: 7) |
| `BACKUP_INTERVAL` | Both compose files | Seconds between backups (default: 604800 = 7 days) |

All *arr API keys are auto-populated by the init script. See `.env.example` files for the complete list.

## Security

- No shell injection: all user input handled via `printf -v` (not `eval`)
- IP addresses validated (octet range check)
- All paths validated as absolute (must start with `/`)
- `.env` files written with `chmod 600`
- SSH keys use ed25519
