#!/usr/bin/env python3
"""
episode-count-webhook.py — Webhook listener for Sonarr episode events.

Listens for Sonarr webhooks (Download, EpisodeFileDelete) and updates
Plex labels + Kometa overlay YAML with episode completion counts.

Runs a full sync on startup, then listens for incremental updates.

Environment:
  SONARR_URL        - Sonarr base URL (default: http://localhost:8989)
  SONARR_API_KEY    - Sonarr API key (required)
  PLEX_URL          - Plex base URL (default: http://192.168.1.34:32400)
  PLEX_TOKEN        - Plex auth token (required)
  PLEX_TV_SECTION   - Plex TV library section ID (default: 2)
  PLEX_ANIME_SECTION - Plex Anime library section ID (default: 3)
  KOMETA_OUTPUT     - Local YAML output path (default: /data/episode-counts.yml)
  KOMETA_REMOTE     - Remote path on Spyglass (default: /opt/media-stack/kometa/config/episode-counts.yml)
  SPYGLASS_HOST     - Spyglass SSH target (default: jolly@192.168.1.34)
  LISTEN_PORT       - Webhook listener port (default: 7800)
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from collections import defaultdict
from http.server import HTTPServer, BaseHTTPRequestHandler

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SONARR_URL = os.environ.get("SONARR_URL", "http://localhost:8989")
SONARR_API_KEY = os.environ.get("SONARR_API_KEY", "")
PLEX_URL = os.environ.get("PLEX_URL", "http://192.168.1.34:32400")
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "")
PLEX_TV_SECTION = os.environ.get("PLEX_TV_SECTION", "2")
PLEX_ANIME_SECTION = os.environ.get("PLEX_ANIME_SECTION", "3")
KOMETA_OUTPUT = os.environ.get("KOMETA_OUTPUT", "/data/episode-counts.yml")
KOMETA_REMOTE = os.environ.get("KOMETA_REMOTE", "/opt/media-stack/kometa/config/episode-counts.yml")
SPYGLASS_HOST = os.environ.get("SPYGLASS_HOST", "jolly@192.168.1.34")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "7800"))
LABEL_PREFIX = "Ep-"

# In-memory state
sonarr_counts = {}       # {tvdb_id: (file_count, total_count)}
plex_shows = []          # [{rating_key, title, tvdb_id, labels, section_id}]
label_map = defaultdict(list)  # {label: [titles]}
sync_lock = threading.Lock()

# Rate-limited search queue
SEARCH_DELAY = int(os.environ.get("SEARCH_DELAY_SECONDS", "30"))
search_queue = []        # [(series_id, title)]
search_queue_lock = threading.Lock()


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
def api_get(url):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def plex_get(path):
    url = f"{PLEX_URL}{path}"
    sep = "&" if "?" in url else "?"
    url += f"{sep}X-Plex-Token={PLEX_TOKEN}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return ET.fromstring(resp.read())


def plex_put(path):
    url = f"{PLEX_URL}{path}"
    sep = "&" if "?" in url else "?"
    url += f"{sep}X-Plex-Token={PLEX_TOKEN}"
    req = urllib.request.Request(url, method="PUT")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


# ---------------------------------------------------------------------------
# Sonarr
# ---------------------------------------------------------------------------
def fetch_all_sonarr_counts():
    """Fetch all series from Sonarr. Returns {tvdb_id: (file_count, total_count)}."""
    log("Fetching all series from Sonarr...")
    series = api_get(f"{SONARR_URL}/api/v3/series?apikey={SONARR_API_KEY}")
    counts = {}
    for s in series:
        tvdb_id = s.get("tvdbId")
        if not tvdb_id:
            continue
        fc, tc = 0, 0
        for season in s.get("seasons", []):
            if season["seasonNumber"] == 0:
                continue
            stats = season.get("statistics", {})
            fc += stats.get("episodeFileCount", 0)
            tc += stats.get("totalEpisodeCount", 0)
        counts[tvdb_id] = (fc, tc)
    log(f"  {len(counts)} series loaded from Sonarr")
    return counts


def fetch_single_sonarr_series(series_id):
    """Fetch a single series from Sonarr by its Sonarr ID."""
    s = api_get(f"{SONARR_URL}/api/v3/series/{series_id}?apikey={SONARR_API_KEY}")
    tvdb_id = s.get("tvdbId")
    if not tvdb_id:
        return None, None, None
    fc, tc = 0, 0
    for season in s.get("seasons", []):
        if season["seasonNumber"] == 0:
            continue
        stats = season.get("statistics", {})
        fc += stats.get("episodeFileCount", 0)
        tc += stats.get("totalEpisodeCount", 0)
    return tvdb_id, fc, tc


# ---------------------------------------------------------------------------
# Plex
# ---------------------------------------------------------------------------
def fetch_plex_shows():
    """Fetch all TV shows from Plex with TVDB IDs and labels."""
    all_shows = []
    for section_id in [PLEX_TV_SECTION, PLEX_ANIME_SECTION]:
        try:
            root = plex_get(f"/library/sections/{section_id}/all?type=2&includeGuids=1")
            for d in root.findall("Directory"):
                tvdb_id = None
                for guid in d.findall("Guid"):
                    gid = guid.get("id", "")
                    if gid.startswith("tvdb://"):
                        tvdb_id = int(gid.replace("tvdb://", ""))
                        break
                labels = [l.get("tag") for l in d.findall("Label")]
                all_shows.append({
                    "rating_key": d.get("ratingKey"),
                    "title": d.get("title"),
                    "tvdb_id": tvdb_id,
                    "labels": labels,
                    "section_id": section_id,
                })
        except Exception as e:
            log(f"  Warning: Could not fetch Plex section {section_id}: {e}")
    log(f"  {len(all_shows)} shows loaded from Plex")
    return all_shows


def apply_label_to_show(show, new_label):
    """Apply a single ep- label to a Plex show, preserving other labels."""
    existing = [l for l in show["labels"] if not l.startswith(LABEL_PREFIX)]
    all_labels = existing + [new_label]

    params = []
    for i, label in enumerate(all_labels):
        params.append(f"label[{i}].tag.tag={urllib.parse.quote(label)}")
    params.append("label.locked=1")
    params.append("type=2")
    params.append(f"id={show['rating_key']}")
    param_str = "&".join(params)

    plex_put(f"/library/sections/{show['section_id']}/all?{param_str}")

    # Update in-memory labels
    show["labels"] = all_labels


def trigger_sonarr_search(series_id):
    """Tell Sonarr to search for all episodes of a series."""
    log(f"  Triggering search for series {series_id}")
    try:
        payload = json.dumps({
            "name": "SeriesSearch",
            "seriesId": series_id,
        }).encode()
        req = urllib.request.Request(
            f"{SONARR_URL}/api/v3/command?apikey={SONARR_API_KEY}",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            log(f"  Search triggered (status {resp.status})")
    except Exception as e:
        log(f"  Failed to trigger search: {e}")


def queue_search(series_id, title=""):
    """Add a search to the rate-limited queue instead of firing immediately."""
    with search_queue_lock:
        # Don't double-queue the same series
        if any(sid == series_id for sid, _ in search_queue):
            log(f"  Search already queued for {title} ({series_id})")
            return
        search_queue.append((series_id, title))
        log(f"  Search queued for {title} ({series_id}) — position {len(search_queue)}")


def search_worker():
    """Background thread that drains the search queue with delays between each."""
    while True:
        series_id = None
        title = ""
        with search_queue_lock:
            if search_queue:
                series_id, title = search_queue.pop(0)

        if series_id:
            log(f"  [search-worker] Processing: {title} ({series_id}), {len(search_queue)} remaining")
            trigger_sonarr_search(series_id)
            time.sleep(SEARCH_DELAY)
        else:
            time.sleep(5)  # Idle poll


def make_label(file_count, total_count):
    """Generate the label string for a given count."""
    if total_count == 0:
        return f"{LABEL_PREFIX}0/0"
    elif file_count >= total_count:
        return f"{LABEL_PREFIX}complete"
    else:
        return f"{LABEL_PREFIX}{file_count}/{total_count}"


# ---------------------------------------------------------------------------
# Kometa YAML generation
# ---------------------------------------------------------------------------
def generate_kometa_yaml():
    """Generate the overlay YAML from current label_map."""
    lines = [
        "# =============================================================================",
        "# Episode Count Overlays — Auto-generated by episode-count-webhook.py",
        "# DO NOT EDIT — regenerated on every Sonarr import event",
        "# =============================================================================",
        "",
        "overlays:",
    ]

    sorted_labels = sorted(label_map.keys(),
                           key=lambda x: (x != f"{LABEL_PREFIX}complete", x))

    for label in sorted_labels:
        if not label_map[label]:
            continue

        yaml_key = label.replace("/", "-")

        if label == f"{LABEL_PREFIX}complete":
            display = "COMPLETE"
            color = "#2ECC40"
        elif label == f"{LABEL_PREFIX}0/0":
            display = "NO EPISODES"
            color = "#AAAAAA"
        else:
            display = label.replace(LABEL_PREFIX, "")
            color = "#FF6B35"

        lines.extend([
            f"  {yaml_key}:",
            f"    overlay:",
            f"      name: text({display})",
            f"      font: fonts/Inter-Medium.ttf",
            f"      font_size: 45",
            f"      font_color: \"{color}\"",
            f"      back_color: \"#000000CC\"",
            f"      back_padding: 10",
            f"      back_radius: 10",
            f"      horizontal_align: right",
            f"      vertical_align: bottom",
            f"      horizontal_offset: 15",
            f"      vertical_offset: 150",
            f"    plex_search:",
            f"      all:",
            f"        label: \"{label}\"",
            "",
        ])

    with open(KOMETA_OUTPUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    log(f"  Wrote {len(sorted_labels)} overlay entries to {KOMETA_OUTPUT}")


def push_to_spyglass():
    """Push the generated YAML to Spyglass via Plex's built-in HTTP or SSH."""
    # Read the generated file and push via SSH cat pipe (no scp binary needed)
    try:
        result = subprocess.run(
            ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
             SPYGLASS_HOST, f"cat > {KOMETA_REMOTE}"],
            stdin=open(KOMETA_OUTPUT, "rb"),
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            log("  YAML pushed to Spyglass")
        else:
            log(f"  SSH push failed: {result.stderr.strip()}")
    except Exception as e:
        log(f"  Push error: {e}")


# ---------------------------------------------------------------------------
# Full sync
# ---------------------------------------------------------------------------
def full_sync():
    """Run a complete sync of all shows."""
    global sonarr_counts, plex_shows, label_map

    with sync_lock:
        log("=== Full sync starting ===")
        sonarr_counts = fetch_all_sonarr_counts()
        plex_shows = fetch_plex_shows()

        label_map = defaultdict(list)
        matched = 0

        for show in plex_shows:
            tvdb_id = show["tvdb_id"]
            if tvdb_id is None or tvdb_id not in sonarr_counts:
                continue

            fc, tc = sonarr_counts[tvdb_id]
            new_label = make_label(fc, tc)
            label_map[new_label].append(show["title"])

            # Check if label already correct
            old_ep_labels = [l for l in show["labels"] if l.startswith(LABEL_PREFIX)]
            if old_ep_labels == [new_label]:
                matched += 1
                continue

            try:
                apply_label_to_show(show, new_label)
                matched += 1
            except Exception as e:
                log(f"  Failed to label {show['title']}: {e}")

        log(f"  Labeled {matched} shows")
        generate_kometa_yaml()
        push_to_spyglass()
        log("=== Full sync complete ===")


# ---------------------------------------------------------------------------
# Incremental update (webhook)
# ---------------------------------------------------------------------------
def handle_sonarr_event(payload):
    """Handle a single Sonarr webhook event."""
    global sonarr_counts, label_map

    event_type = payload.get("eventType", "")
    series = payload.get("series", {})
    series_id = series.get("id")
    tvdb_id = series.get("tvdbId")
    title = series.get("title", "unknown")

    if not series_id or not tvdb_id:
        log(f"  Ignoring event: no series ID or TVDB ID")
        return

    log(f"  Event: {event_type} for '{title}' (tvdb:{tvdb_id})")

    # On new series add, queue a search since Seerr has preventSearch=true
    # Rate-limited: one search every SEARCH_DELAY seconds to prevent box meltdown
    if event_type == "SeriesAdd" and series_id:
        queue_search(series_id, title)

    with sync_lock:
        # Refresh this series from Sonarr
        try:
            _, fc, tc = fetch_single_sonarr_series(series_id)
            if fc is None:
                return
        except Exception as e:
            log(f"  Failed to fetch series {series_id}: {e}")
            return

        sonarr_counts[tvdb_id] = (fc, tc)
        new_label = make_label(fc, tc)

        # Find matching Plex show
        plex_show = None
        for show in plex_shows:
            if show["tvdb_id"] == tvdb_id:
                plex_show = show
                break

        if not plex_show:
            log(f"  Show not found in Plex, skipping label update")
        else:
            old_ep_labels = [l for l in plex_show["labels"] if l.startswith(LABEL_PREFIX)]
            if old_ep_labels != [new_label]:
                # Remove old label from label_map
                for old in old_ep_labels:
                    if plex_show["title"] in label_map.get(old, []):
                        label_map[old].remove(plex_show["title"])

                try:
                    apply_label_to_show(plex_show, new_label)
                    log(f"  Updated label: {new_label} ({fc}/{tc})")
                except Exception as e:
                    log(f"  Failed to update Plex label: {e}")
                    return
            else:
                log(f"  Label already correct: {new_label}")

            label_map[new_label].append(plex_show["title"])

        # Regenerate YAML and push
        generate_kometa_yaml()
        push_to_spyglass()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"OK")

        try:
            payload = json.loads(body)
            event_type = payload.get("eventType", "")

            if event_type in ("Download", "EpisodeFileDelete", "Rename", "SeriesAdd", "SeriesDelete"):
                log(f"Webhook received: {event_type}")
                # Handle in a thread to not block the response
                threading.Thread(target=handle_sonarr_event, args=(payload,), daemon=True).start()
            elif event_type == "Test":
                log("Webhook test received — connection OK")
            else:
                log(f"Ignoring event type: {event_type}")
        except json.JSONDecodeError:
            log("Invalid JSON in webhook payload")
        except Exception as e:
            log(f"Error processing webhook: {e}")

    def do_GET(self):
        """Health check endpoint."""
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        stats = {
            "status": "ok",
            "sonarr_series": len(sonarr_counts),
            "plex_shows": len(plex_shows),
            "overlay_entries": len(label_map),
        }
        self.wfile.write(json.dumps(stats).encode())

    def log_message(self, format, *args):
        pass  # Suppress default HTTP logging


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not SONARR_API_KEY:
        log("ERROR: SONARR_API_KEY not set")
        sys.exit(1)
    if not PLEX_TOKEN:
        log("ERROR: PLEX_TOKEN not set")
        sys.exit(1)

    log("Episode count webhook service starting...")
    log(f"  Sonarr: {SONARR_URL}")
    log(f"  Plex: {PLEX_URL}")
    log(f"  Listening on port {LISTEN_PORT}")

    # Start the rate-limited search worker
    search_thread = threading.Thread(target=search_worker, daemon=True)
    search_thread.start()
    log(f"  Search worker started (delay: {SEARCH_DELAY}s between searches)")

    # Full sync on startup
    full_sync()

    # Start webhook listener
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), WebhookHandler)
    log(f"Webhook listener ready on port {LISTEN_PORT}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
