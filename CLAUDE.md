# SupArr — Media Stack

**Repo:** `git@github.com:adamjboyce/SupArr.git`
**Working directory:** `/home/jolly/SupArr/media-stack-final/`
**Production:** Privateer (`192.168.1.209`) at `/opt/suparr`

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

9 crons installed during deploy, all in root's crontab on Privateer:
- `*/15` disk_guard.sh — pause downloads when NVMe low
- `*/30` arr-health-monitor.sh — service health checks
- `*/30` auto-import.py — force-import stuck items
- `*/30` container-watchdog.sh --quiet — silent recovery
- `10 3` missing-search.sh — search for wanted content
- `0 4` download-cleanup.sh — clean old downloads
- `15 5` container-watchdog.sh — post-Watchtower recovery
- `0 6 */3` arr-trakt-refresh.sh — keep Trakt tokens alive
- `0 */6` queue-cleanup.sh — purge stale items

Two more crons, added outside the deploy wizard and only discovered/relocated 2026-08-12 (were sitting in jolly's personal crontab, undocumented — see `.mal/lessons-learned.md` 2026-08-12):
- `0 4` sonarr-history-trim.sh — trims Sonarr's `DownloadHistory` table >7 days old. **Active.**
- `0 */2` arr-maintenance.sh — qBit seed purge, DownloadHistory trim (all *arrs), Commands-table cap (docker stop/TRUNCATE/docker start when >500 rows), calls ghost-cleanup.sh. **DISABLED** (commented out in root's crontab) — the Commands-table truncate's hard container bounce was confirmed as the cause of SAB's queue appearing to periodically purge itself. Root cause of the Commands backlog itself is still open. `jolly`'s crontab also ran `container-watchdog.sh --quiet` independently of root's identical entry — redundant, left as-is for now.

Any script that can `docker stop`/`TRUNCATE`/restart a production *arr container on an automated schedule needs a home in this list and a `.mal/decisions.md` entry at install time — not a personal crontab nobody else checks.

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
- arr-postgres data lives at `${APPDATA}/arr-postgres/data` and is guarded: `create_host_path: false` + healthcheck requires `.suparr-live-datadir` in the data dir. If arr-postgres is unhealthy while `pg_isready` passes, it's mounted on the wrong cluster — do not "fix" it by touching the marker elsewhere. See `.mal/decisions.md` 2026-10-19.
- Never hand-edit `/opt/suparr` on a host without committing the same change here in the same session — a later sync reverts it (root cause of the 2026-07-22 arr DB rollback).
