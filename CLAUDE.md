# SupArr — Media Stack

**Repo:** `git@github.com:adamjboyce/SupArr.git`
**Working directory:** `/home/jolly/SupArr/media-stack-final/`
**Production:** Privateer (`192.168.1.209`) at `/opt/suparr`
**Old Privateer (Foundry):** `192.168.1.27` — still running arr stack, being migrated

Two-machine Docker Compose stack with deploy wizard GUI. Spyglass (Plex + transcoding + disc ripping) and Privateer (*arr apps + downloads + automation).

## Architecture

**Spyglass (machine1-plex):** Plex, Tdarr, Kometa, Seerr, Tautulli, Stash + tagger, MakeMKV, Handbrake, Homepage, Uptime Kuma, Watchtower, backup.

**Privateer (machine2-arr):** Gluetun VPN (multi-provider), qBittorrent, SABnzbd, Radarr, Sonarr, Lidarr, Bookshelf, Whisparr, Bazarr, Prowlarr, FlareSolverr, Recyclarr, Autobrr, Notifiarr, Unpackerr, Immich (4 containers), Syncthing, Audiobookshelf, autoheal, Watchtower, Dozzle, Homepage, download-monitor, maintenance, weekly-digest, backup.

## Deploy Wizard

Web GUI at `deploy/`. 10-step wizard: Mode → Targets → Storage → Plex → *arr → Components → Notifications → Review → Deploy → Report.

**Key files:**
- `deploy/config.py` — Schema, validation, .env generation, component registry
- `deploy/server.py` — HTTP server + REST API + SSE streaming
- `deploy/deployer.py` — Orchestration, rsync, init execution
- `deploy/static/` — Vanilla JS/HTML/CSS wizard UI

### Component Picker

31 components across 6 tiers. Docker Compose profiles control which services start. `COMPOSE_PROFILES` written to `.env` by the wizard.

- **Always-on:** gluetun, tailscale, autoheal, watchtower, homepage, dozzle, backup, maintenance, download-monitor, unpackerr
- **Deselectable infra (warn):** prowlarr, flaresolverr, bazarr, recyclarr, notifiarr
- **Download clients:** qbittorrent, sabnzbd
- **Content managers:** radarr, sonarr, lidarr, bookshelf, whisparr
- **Disc ripping:** makemkv, handbrake (Spyglass)
- **Plex add-ons:** stash, stash-tagger (auto-enabled with whisparr)
- **Optional:** autobrr, weekly-digest, immich, syncthing, audiobookshelf

### Hardware Detection

`scripts/detect-hardware.sh` — sourced by both init scripts. Exports `HW_*` variables:
- GPU type/gen → Tdarr codec (AV1 vs HEVC, hardware vs software)
- Dual-GPU detection (iGPU + discrete) → dual Tdarr workers
- CPU cores → worker counts, SVT-AV1 for 8+ core CPU-only
- Optical drive → Blu-ray vs DVD capability
- `TDARR_DEDICATED=true` in .env flips GPU priority for dedicated transcode boxes

### Customization Options

All wired end-to-end (wizard → .env → init script):
- **VPN provider:** 10 providers + custom OpenVPN. Conditional credential fields.
- **Quality tier:** HD (1080p), 4K UHD, or Both. Drives Recyclarr template selection.
- **Media categories:** 11 toggleable categories. Drives folders, root folders, Plex/Tdarr libraries.
- **Import lists:** Trakt, TMDb, StevenLu, IMDb, MDBList — conditional API keys.
- **Tdarr schedule:** off-hours / 24-7 / overnight.
- **Download speed limits:** Applied to qBit + SABnzbd.

## System Crons (Phase 8g)

9 crons installed during deploy:
- `*/15` disk_guard.sh — pause downloads when NVMe low
- `*/30` arr-health-monitor.sh — service health checks
- `*/30` auto-import.py — force-import stuck items
- `*/30` container-watchdog.sh --quiet — silent recovery
- `10 3` missing-search.sh — search for wanted content
- `0 4` download-cleanup.sh — clean old downloads
- `15 5` container-watchdog.sh — post-Watchtower recovery
- `0 6 */3` arr-trakt-refresh.sh — keep Trakt tokens alive
- `0 */6` queue-cleanup.sh — purge stale items

## Bazarr Setup

Automatic subtitle downloads. Providers: Podnapisi, OpenSubtitles.com, Subf2m/Subscene, Animetosho, SubDL.
Language profile: "English + Forced". Searches every 6 hours, upgrades subs for 7 days.

## Key Decisions

- Stash lives on Spyglass (with Plex), not Privateer. Moved 2026-03-22.
- Bookshelf replaces Readarr (Readarr metadata server dead since June 2025).
- NVMe incomplete dirs for downloads (not NFS) — prevents GIL stalls.
- Recyclarr uses TRaSH Guide profiles, tier-selected (HD/4K/Both).
- SABnzbd host whitelist pre-seeded before first start.
- All download client additions guarded by `is_selected` per service.
