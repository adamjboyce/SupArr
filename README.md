# SupArr — Automated Deployment

Two machines. One NAS. One script.

## Quick Start

### Option A: Remote Deploy (from your desktop)

```bash
tar -xzf suparr.tar.gz
cd media-stack-final
./remote-deploy.sh     # Prompts for everything. Deploys both machines in parallel.
```

Run from WSL2, Linux, or macOS. Collects all config up front, SSHs into both machines, deploys in parallel. No need to log into each machine individually.

### Option B: On-Machine Deploy

```bash
tar -xzf suparr.tar.gz
cd media-stack-final
sudo ./setup.sh        # Prompts for everything. Deploys. Configures.
```

Run directly on each machine. Auto-detects which box it's on (iGPU = Plex, 128GB = *arr), asks for creds interactively, writes `.env`, installs everything, starts all containers, and configures them via API.

### Option C: Direct (No Prompts)

```bash
# Machine 2 (start here)
cd media-stack-final/machine2-arr
cp .env.example .env && nano .env
sudo ../scripts/init-machine2-arr.sh

# Machine 1
cd media-stack-final/machine1-plex
cp .env.example .env && nano .env
sudo ../scripts/init-machine1-plex.sh
```

All scripts are **re-run safe** — skip already-configured items on re-run.

## What's Automated

### Machine 2 (*arr stack) — `init-machine2-arr.sh`
- System packages + Docker installation
- NFS mounts to NAS (media + downloads, enables hardlinks)
- Directory structure (app data, media folders, download dirs)
- qBittorrent pre-seeded with correct paths, categories, seed ratios
- All containers started
- **API keys auto-collected** from freshly started containers → saved to .env
- Radarr: root folders (movies, docs, stand-up, concerts, anime-movies), qBit + SABnzbd download clients, naming conventions
- Sonarr: root folders (tv, anime), download clients, naming
- Lidarr: root folder (music), download client
- **Readarr: root folders (books, audiobooks), download client**
- **Whisparr: root folder (adult), download client**
- Prowlarr → Radarr/Sonarr/Lidarr connections established
- Prowlarr → FlareSolverr proxy added
- Recyclarr TRaSH Guide quality profiles synced
- **qBittorrent password changed** from default
- **Bazarr → Sonarr/Radarr connected, English + forced subs configured**
- **Download client passwords synced** across all *arr apps

### Machine 1 (Plex) — `init-machine1-plex.sh`
- System packages + Intel iGPU drivers (non-free)
- iGPU verification (/dev/dri/renderD128)
- Docker installation
- NFS mount to NAS
- Kometa config deployed with API keys from .env
- Homepage dashboard template deployed
- All containers started
- **Plex preferences patched:**
  - Hardware transcoding enabled (Quick Sync)
  - Subtitle mode: "Shown with foreign audio" (the forced subs fix)
  - Transcoder: prefer higher speed
  - Transcode temp dir on local SSD

### Remote Deploy (`remote-deploy.sh`)
- Prerequisites check (ssh, sshpass, rsync)
- Collects ALL config in one interactive session on the desktop
- Generates SSH key pair and pushes to both targets
- Generates machine-specific `.env` files
- Rsyncs project files to `/opt/suparr` on each target
- Launches init scripts on both machines **in parallel**
- Post-deploy summary with all service URLs and cross-machine config hints

## Manual Finishing Touches

Both scripts print a summary. The main items:

**Machine 2:**
- Prowlarr: add your actual indexers (credentials required)
- SABnzbd: run setup wizard, add Usenet servers
- Bazarr: add subtitle providers (OpenSubtitles.com)
- Radarr Lists: create MDBList filters (RT > 85%, etc.) and add to Radarr → Settings → Lists

**Machine 1:**
- Plex: complete setup wizard, add libraries, claim server
- Tdarr: add libraries, plugins (Migz5ConvertContainer → Migz1FFMPEG → Migz3CleanAudio → Migz4CleanSubs), set Migz4CleanSubs to **KEEP forced subtitle tracks**
- Overseerr: connect to Plex + Radarr/Sonarr on Machine 2
- Kometa: verify config, first run (`docker exec kometa python kometa.py --run`)

## Re-Running

All scripts are **idempotent** — safe to re-run at any time. They skip items that are already configured, which is useful for:
- Adding SABnzbd API key after running its setup wizard
- Updating Prowlarr connections after manual indexer setup
- Re-syncing Recyclarr after config changes

## Architecture

```
  Machine 1: i5-8500 / 32GB             Machine 2: Xeon E-2334 / 128GB
  ┌─────────────────────────┐            ┌──────────────────────────────┐
  │ Plex (Quick Sync HW)    │            │ Gluetun (NordVPN)           │
  │ Tdarr (H.265/QSV)       │            │   ├── qBittorrent (masked)  │
  │ Kometa (aesthetics)      │            │   └── SABnzbd (masked)      │
  │ Overseerr (requests)     │            │ Prowlarr + FlareSolverr     │
  │ Tautulli (analytics)     │            │ Radarr, Sonarr, Lidarr      │
  │ Homepage (dashboard)     │            │ Readarr, Bazarr, Whisparr   │
  │ Tailscale (remote)       │            │ Recyclarr, Autobrr, FileBot │
  └────────┬────────────────┘            │ Unpackerr, Notifiarr        │
           │          10GbE              │ Homepage, Dozzle, Tailscale  │
           └──────────────┬──────────────┴──────────┬───────────────────┘
                          │                         │
                 ┌────────┴─────────────────────────┘
                 │        NAS (NFS)
                 │  /media   /downloads
                 └──────────────────────
```

## File Structure
```
media-stack-final/
├── setup.sh                               ← On-machine interactive setup
├── remote-deploy.sh                       ← Desktop remote deploy (both machines)
├── README.md
├── scripts/
│   ├── init-machine1-plex.sh              ← Plex init (called by setup/remote-deploy)
│   └── init-machine2-arr.sh               ← *arr init (called by setup/remote-deploy)
├── machine1-plex/
│   ├── .env.example
│   ├── docker-compose.yml
│   └── config-templates/
│       ├── kometa.yml
│       └── homepage-services.yaml
└── machine2-arr/
    ├── .env.example
    ├── docker-compose.yml
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
| Tdarr codec target | Manual (printed) | H.265 via QSV, MKV container |
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
