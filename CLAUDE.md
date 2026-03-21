# SupArr — Media Stack

**Repo:** `git@github.com:adamjboyce/SupArr.git`
**Working directory:** `/home/jolly/SupArr/media-stack-final/`
**Production:** Privateer (`192.168.1.27`) at `/opt/suparr`

Docker Compose media stack: Gluetun VPN, qBittorrent, SABnzbd, Sonarr, Radarr, Prowlarr, Seerr (v3.1.0), Tdarr, Recyclarr, Bazarr, with autoheal sidecar for Gluetun resilience.

## Bazarr Setup

Bazarr handles automatic subtitle downloads. Config lives at `/opt/arr-stack/bazarr/config/` on Privateer.

**Configured providers:**
- Podnapisi (no account needed)
- OpenSubtitles.com (no account needed for basic)
- Subf2m / Subscene (no account needed, user-agent set)
- Animetosho (no account needed, good for anime)
- SubDL (API key in config)

**Language profile:** "English + Forced" — downloads both regular English subs and forced-only subs (for foreign audio segments).

**Arr integration:** Connected to Sonarr and Radarr via Docker DNS (`sonarr:8989`, `radarr:7878`). SignalR live sync enabled.

**Default behavior:** All new series and movies get the "English + Forced" profile automatically. Bazarr searches for missing subs every 6 hours and upgrades existing subs for 7 days.

**UI:** `http://192.168.1.27:6767`

---

# Architecture Map
<!-- Added 2026-03-20. Components documented here are audited by health checks. -->
<!-- New builds are added by Reorx after pipeline completion. -->
<!-- Format: Name, Status, Files, Connections, Unwired items. -->

## Components

<!-- Components will be added here as builds complete the pipeline. -->
