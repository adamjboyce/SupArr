#!/usr/bin/env python3
"""Auto-import blocked downloads across Sonarr, Radarr, and Lidarr.

Sweeps completed queue items and force-imports those stuck on:
- "matched by ID" (Radarr/Sonarr — release name doesn't match but ID does)
- "unmatched tracks" (Lidarr — metadata mismatch on new releases)
- "folder mismatch" (Sonarr — folder naming doesn't match season structure)

Also cleans up:
- "not an upgrade" → remove from queue (keep download)
- "no files found" → remove from queue and client

Run via cron every 30 minutes or on-demand.

Usage:
    python3 auto-import.py              # Run all checks
    python3 auto-import.py --dry-run    # Show what would happen without doing it
"""

from __future__ import annotations

import json
import logging
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("auto-import")

DRY_RUN = "--dry-run" in sys.argv


# ================================================================
# Arr configurations — add API keys here
# ================================================================

ARRS = {
    "sonarr": {
        "base": "http://localhost:8989/api/v3",
        "key_cmd": "docker exec sonarr cat /config/config.xml | grep -oP '(?<=<ApiKey>)[^<]+'",
        "queue_params": "&includeUnknownSeriesItems=true",
        "id_field": "seriesId",
        "import_mode": "copy",
    },
    "radarr": {
        "base": "http://localhost:7878/api/v3",
        "key_cmd": "docker exec radarr cat /config/config.xml | grep -oP '(?<=<ApiKey>)[^<]+'",
        "queue_params": "",
        "id_field": "movieId",
        "import_mode": "move",
    },
    "lidarr": {
        "base": "http://localhost:8686/api/v1",
        "key_cmd": "docker exec lidarr cat /config/config.xml | grep -oP '(?<=<ApiKey>)[^<]+'",
        "queue_params": "&includeUnknownArtistItems=true",
        "id_field": "artistId",
        "import_mode": "move",
    },
}


@dataclass
class ImportAction:
    """A planned import or removal action."""

    arr: str
    action: str  # import | remove | remove_and_delete
    title: str
    queue_ids: list[int]
    download_id: str
    entity_id: int | None  # movieId, seriesId, artistId
    reason: str


def get_api_key(arr_name: str) -> str | None:
    """Get API key from the container's config.xml."""
    try:
        result = subprocess.run(
            ["bash", "-c", ARRS[arr_name]["key_cmd"]],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception:
        return None


def api_call(base: str, key: str, endpoint: str, method: str = "GET", data: dict | None = None) -> dict | list | None:
    """Make an API call to an arr service."""
    cmd = ["curl", "-s", f"{base}{endpoint}", "-H", f"X-Api-Key: {key}"]
    if method in ("POST", "DELETE"):
        cmd.extend(["-X", method, "-H", "Content-Type: application/json"])
        if data:
            cmd.extend(["-d", json.dumps(data)])
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.stdout.strip():
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return None


def classify_issue(record: dict) -> str:
    """Classify the import issue from status messages."""
    for m in record.get("statusMessages", []):
        for msg in m.get("messages", []):
            if "matched to movie by ID" in msg or "matched to series by ID" in msg:
                return "matched_by_id"
            if "was unexpected considering" in msg:
                return "folder_mismatch"
            if "unmatched tracks" in msg.lower() or "Has unmatched tracks" in msg:
                return "unmatched_tracks"
            if "Not a Custom Format upgrade" in msg or "Not an upgrade" in msg:
                return "not_upgrade"
            if "No files found" in msg or "no eligible" in msg.lower():
                return "no_files"
            if "Unable to parse" in msg:
                return "unparseable"
            if "already imported" in msg.lower():
                return "already_imported"
            if "Failed to import" in msg:
                return "import_failed"
    return "unknown"


def scan_queue(arr_name: str, config: dict, api_key: str) -> list[ImportAction]:
    """Scan an arr's completed queue for actionable items."""
    actions: list[ImportAction] = []

    data = api_call(
        config["base"], api_key,
        f"/queue?pageSize=100&status=completed{config['queue_params']}",
    )
    if not data or not isinstance(data, dict):
        return actions

    records = data.get("records", [])
    if not records:
        return actions

    # Group by downloadId
    from collections import defaultdict
    by_download: dict[str, list] = defaultdict(list)
    for r in records:
        did = r.get("downloadId", "")
        if did:
            by_download[did].append(r)

    for download_id, group in by_download.items():
        first = group[0]
        title = first.get("title", "?")[:70]
        state = first.get("trackedDownloadState", "")
        entity_id = first.get(config["id_field"])
        queue_ids = [r["id"] for r in group]
        issue = classify_issue(first)

        # Skip items that are actively importing
        if state == "importing" and issue == "unknown":
            continue

        if issue in ("matched_by_id", "folder_mismatch", "unmatched_tracks", "import_failed"):
            actions.append(ImportAction(
                arr=arr_name,
                action="import",
                title=title,
                queue_ids=queue_ids,
                download_id=download_id,
                entity_id=entity_id,
                reason=issue,
            ))
        elif issue == "not_upgrade":
            actions.append(ImportAction(
                arr=arr_name,
                action="remove",
                title=title,
                queue_ids=queue_ids,
                download_id=download_id,
                entity_id=entity_id,
                reason=issue,
            ))
        elif issue == "no_files":
            actions.append(ImportAction(
                arr=arr_name,
                action="remove_and_delete",
                title=title,
                queue_ids=queue_ids,
                download_id=download_id,
                entity_id=entity_id,
                reason=issue,
            ))
        elif issue == "already_imported":
            actions.append(ImportAction(
                arr=arr_name,
                action="remove",
                title=title,
                queue_ids=queue_ids,
                download_id=download_id,
                entity_id=entity_id,
                reason=issue,
            ))

    return actions


def execute_import(config: dict, api_key: str, action: ImportAction) -> bool:
    """Execute a manual import for a blocked download."""
    id_field = config["id_field"]
    entity_id = action.entity_id

    # Get manual import preview
    params = f"downloadId={action.download_id}&filterExistingFiles=true"
    if entity_id:
        params += f"&{id_field}={entity_id}"

    preview = api_call(config["base"], api_key, f"/manualimport?{params}")
    if not preview or not isinstance(preview, list) or not preview:
        # Try without filtering existing files
        params = params.replace("filterExistingFiles=true", "filterExistingFiles=false")
        preview = api_call(config["base"], api_key, f"/manualimport?{params}")
        if not preview or not isinstance(preview, list) or not preview:
            return False

    files = []
    for item in preview:
        entry = {
            "path": item["path"],
            "quality": item["quality"],
            "languages": item.get("languages", [{"id": 1, "name": "English"}]),
            "downloadId": action.download_id,
            "id": item["id"],
            "indexerFlags": item.get("indexerFlags", 0),
        }

        if item.get("releaseGroup"):
            entry["releaseGroup"] = item["releaseGroup"]

        # Sonarr needs episodeIds and seriesId
        if action.arr == "sonarr":
            eps = item.get("episodes", [])
            if not eps:
                continue
            entry["seriesId"] = entity_id
            entry["seasonNumber"] = item.get("seasonNumber")
            entry["episodeIds"] = [e["id"] for e in eps]

        # Radarr needs movieId
        elif action.arr == "radarr":
            entry["movieId"] = entity_id or item.get("movie", {}).get("id")

        # Lidarr needs artistId, albumId, trackIds
        elif action.arr == "lidarr":
            entry["artistId"] = entity_id or item.get("artist", {}).get("id")
            album = item.get("album", {})
            if album:
                entry["albumId"] = album.get("id")
            tracks = item.get("tracks", [])
            if tracks:
                entry["trackIds"] = [t["id"] for t in tracks]
            entry["disableReleaseSwitching"] = True

        files.append(entry)

    if not files:
        return False

    result = api_call(
        config["base"], api_key, "/command",
        method="POST",
        data={"name": "ManualImport", "importMode": config["import_mode"], "files": files},
    )
    return bool(result and result.get("id"))


def execute_remove(config: dict, api_key: str, action: ImportAction, delete_from_client: bool = False) -> bool:
    """Remove items from the queue."""
    result = api_call(
        config["base"], api_key, "/queue/bulk",
        method="DELETE",
        data={
            "ids": action.queue_ids,
            "removeFromClient": delete_from_client,
            "blocklist": False,
            "skipRedownload": True,
        },
    )
    return result is not None


def main():
    log.info("Auto-import sweep starting%s", " (DRY RUN)" if DRY_RUN else "")

    total_actions = 0
    total_success = 0

    for arr_name, config in ARRS.items():
        api_key = get_api_key(arr_name)
        if not api_key:
            log.warning("%s: could not get API key, skipping", arr_name)
            continue

        actions = scan_queue(arr_name, config, api_key)
        if not actions:
            log.info("%s: queue clean", arr_name)
            continue

        log.info("%s: %d actions to take", arr_name, len(actions))

        for action in actions:
            total_actions += 1
            prefix = "[DRY RUN] " if DRY_RUN else ""

            if action.action == "import":
                log.info("%s%s: IMPORT %s (%s)", prefix, arr_name, action.title, action.reason)
                if not DRY_RUN:
                    ok = execute_import(config, api_key, action)
                    if ok:
                        total_success += 1
                        log.info("  -> OK")
                    else:
                        log.warning("  -> FAILED (no importable files)")
                else:
                    total_success += 1

            elif action.action == "remove":
                log.info("%s%s: REMOVE %s (%s)", prefix, arr_name, action.title, action.reason)
                if not DRY_RUN:
                    ok = execute_remove(config, api_key, action)
                    if ok:
                        total_success += 1
                    else:
                        log.warning("  -> FAILED")
                else:
                    total_success += 1

            elif action.action == "remove_and_delete":
                log.info("%s%s: REMOVE+DELETE %s (%s)", prefix, arr_name, action.title, action.reason)
                if not DRY_RUN:
                    ok = execute_remove(config, api_key, action, delete_from_client=True)
                    if ok:
                        total_success += 1
                    else:
                        log.warning("  -> FAILED")
                else:
                    total_success += 1

    log.info("Sweep complete: %d/%d actions succeeded", total_success, total_actions)


if __name__ == "__main__":
    main()
