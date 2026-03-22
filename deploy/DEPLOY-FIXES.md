# Deploy Script Fixes — First Clean-Room Deploy (2026-03-21)

All 15 issues discovered during the first clean-room deploy have been fixed
as of 2026-03-22. Ready for next wipe-and-test cycle.

## Init Script Bugs

1. **NFS mounts must happen before arr configuration** ✅ FIXED
   - Added NFS mount verification gate between Phase 4b and Phase 5
   - Fatal exit if NAS_IP is configured but mount is not active

2. **`set -euo pipefail` + pipelines that return no matches** ✅ FIXED
   - Full audit: 8 fragile pipelines guarded with `|| true`
   - All informational grep/jq/awk in pipelines protected

3. **Indexer seeding — `$?` check after `set -e`** ✅ FIXED
   - Changed to `if arr_api ...; then` pattern

## Missing Pre-Configuration

4. **SABnzbd host whitelist** ✅ FIXED
   - Pre-seeded in Phase 5 before first start (host_whitelist in sabnzbd.ini)

5. **SABnzbd categories** ✅ FIXED
   - Categories created via API in Phase 8 (added `books` category)

6. **Download client API requires `priority` field** ✅ ALREADY HAD IT
   - All payloads already included `"priority": 1`

## Env Var / Compose Issues

7. **VPN env var prefix mismatch** ✅ FIXED
   - config.py now writes `VPN_*` names matching compose expectations
   - Multi-provider support added (10 providers + custom OpenVPN)

8. **Gluetun recreation orphans network-dependent containers** ✅ FIXED
   - Script already uses `docker compose up -d` (not restart)
   - Added documentation comment in Phase 6

## Fresh Debian Gaps

9. **Missing packages not detected** ✅ FIXED
   - Pre-flight check after Phase 1 verifies curl, jq, git, wget

10. **SSH key deployment flow** ✅ PREVIOUSLY IMPLEMENTED
    - sshpass + ssh -tt for TTY

11. **NOPASSWD sudo as deploy prereq** ✅ PREVIOUSLY IMPLEMENTED
    - Auto-grant via su -c, auto-revoke in finally block

## GUI Issues

12. **No service picker** ✅ FIXED
    - 29-component picker with 6 tiers, dependency hierarchy, Docker Compose profiles

13. **No log view on failure** ✅ FIXED
    - Terminal stays visible on failure with error banner + "View Report" button

14. **Form data lost on server restart** ✅ FIXED
    - localStorage persistence with fallback restore

15. **Server doesn't auto-kill previous instance** ✅ FIXED
    - lsof PID kill + SO_REUSEADDR on server socket
