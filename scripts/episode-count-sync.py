#!/usr/bin/env python3
"""
episode-count-sync.py — Sync episode completion data from Sonarr to Plex labels
and generate a Kometa overlay YAML for displaying counts on posters.

Flow:
  1. Query Sonarr for all series and their season stats (excluding Season 0)
  2. Query Plex for all TV shows and match via TVDB ID
  3. Apply Plex labels: "ep-complete" or "ep-X/Y" per show
  4. Generate episode-counts.yml for Kometa with one overlay per unique count

Designed to run daily via cron.
"""

import json
import os
import sys
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from collections import defaultdict

# ---------------------------------------------------------------------------
# Config — override via environment variables
# ---------------------------------------------------------------------------
SONARR_URL = os.environ.get("SONARR_URL", "http://localhost:8989")
SONARR_API_KEY = os.environ.get("SONARR_API_KEY", "")
PLEX_URL = os.environ.get("PLEX_URL", "http://192.168.1.34:32400")
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "")
PLEX_TV_SECTION = os.environ.get("PLEX_TV_SECTION", "2")
PLEX_ANIME_SECTION = os.environ.get("PLEX_ANIME_SECTION", "3")
KOMETA_OUTPUT = os.environ.get("KOMETA_OUTPUT", "/tmp/episode-counts.yml")
LABEL_PREFIX = "Ep-"
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")


def log(msg):
    print(f"[episode-sync] {msg}", flush=True)


def api_get(url):
    """GET JSON from a URL."""
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def plex_get(path):
    """GET XML from Plex API."""
    url = f"{PLEX_URL}{path}"
    sep = "&" if "?" in url else "?"
    url += f"{sep}X-Plex-Token={PLEX_TOKEN}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return ET.fromstring(resp.read())


def plex_put(path):
    """PUT to Plex API."""
    url = f"{PLEX_URL}{path}"
    sep = "&" if "?" in url else "?"
    url += f"{sep}X-Plex-Token={PLEX_TOKEN}"
    req = urllib.request.Request(url, method="PUT")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


# ---------------------------------------------------------------------------
# Step 1: Get episode counts from Sonarr
# ---------------------------------------------------------------------------
def get_sonarr_counts():
    """Returns dict of {tvdb_id: (file_count, total_count)}."""
    log("Fetching series from Sonarr...")
    series = api_get(f"{SONARR_URL}/api/v3/series?apikey={SONARR_API_KEY}")
    log(f"  Found {len(series)} series")

    counts = {}
    for s in series:
        tvdb_id = s.get("tvdbId")
        if not tvdb_id:
            continue
        file_count = 0
        total_count = 0
        for season in s.get("seasons", []):
            if season["seasonNumber"] == 0:
                continue
            stats = season.get("statistics", {})
            file_count += stats.get("episodeFileCount", 0)
            total_count += stats.get("totalEpisodeCount", 0)
        counts[tvdb_id] = (file_count, total_count)
    return counts


# ---------------------------------------------------------------------------
# Step 2: Get Plex shows with TVDB IDs and existing labels
# ---------------------------------------------------------------------------
def get_plex_shows(section_id):
    """Returns list of {rating_key, title, tvdb_id, labels}."""
    log(f"Fetching Plex shows from section {section_id}...")
    root = plex_get(f"/library/sections/{section_id}/all?type=2&includeGuids=1")
    shows = []
    for d in root.findall("Directory"):
        tvdb_id = None
        for guid in d.findall("Guid"):
            gid = guid.get("id", "")
            if gid.startswith("tvdb://"):
                tvdb_id = int(gid.replace("tvdb://", ""))
                break
        labels = [l.get("tag") for l in d.findall("Label")]
        shows.append({
            "rating_key": d.get("ratingKey"),
            "title": d.get("title"),
            "tvdb_id": tvdb_id,
            "labels": labels,
        })
    log(f"  Found {len(shows)} shows")
    return shows


# ---------------------------------------------------------------------------
# Step 3: Apply labels to Plex shows
# ---------------------------------------------------------------------------
def apply_labels(shows, sonarr_counts):
    """Apply ep- labels to Plex shows. Returns dict of label -> [titles]."""
    label_map = defaultdict(list)
    updated = 0
    skipped = 0

    for show in shows:
        tvdb_id = show["tvdb_id"]
        if tvdb_id is None or tvdb_id not in sonarr_counts:
            skipped += 1
            continue

        file_count, total_count = sonarr_counts[tvdb_id]

        # Determine label
        if total_count == 0:
            new_label = f"{LABEL_PREFIX}0/0"
        elif file_count >= total_count:
            new_label = f"{LABEL_PREFIX}complete"
        else:
            new_label = f"{LABEL_PREFIX}{file_count}/{total_count}"

        # Preserve non-ep labels, replace ep- labels
        existing = [l for l in show["labels"] if not l.startswith(LABEL_PREFIX)]
        if new_label in show["labels"] and len(existing) + 1 == len(show["labels"]):
            # Label already correct, skip
            label_map[new_label].append(show["title"])
            skipped += 1
            continue

        all_labels = existing + [new_label]
        label_map[new_label].append(show["title"])

        if DRY_RUN:
            log(f"  [DRY RUN] {show['title']}: {new_label}")
            continue

        # Build label PUT params
        params = []
        for i, label in enumerate(all_labels):
            params.append(f"label[{i}].tag.tag={urllib.parse.quote(label)}")
        params.append("label.locked=1")
        params.append(f"type=2")
        params.append(f"id={show['rating_key']}")
        param_str = "&".join(params)

        section_id = show.get("section_id", PLEX_TV_SECTION)
        plex_put(f"/library/sections/{section_id}/all?{param_str}")
        updated += 1

    log(f"  Updated: {updated}, Skipped: {skipped}")
    return label_map


# ---------------------------------------------------------------------------
# Step 4: Generate Kometa overlay YAML
# ---------------------------------------------------------------------------
def generate_kometa_yaml(label_map):
    """Generate episode-counts.yml for Kometa."""
    log(f"Generating Kometa overlay YAML...")

    lines = [
        "# =============================================================================",
        "# Episode Count Overlays — Auto-generated by episode-count-sync.py",
        "# DO NOT EDIT — this file is regenerated daily",
        "# =============================================================================",
        "",
        "overlays:",
    ]

    # Sort: complete first, then by label
    sorted_labels = sorted(label_map.keys(), key=lambda x: (x != f"{LABEL_PREFIX}complete", x))

    for label in sorted_labels:
        if not label_map[label]:
            continue

        # Safe YAML key — replace / with -
        yaml_key = label.replace("/", "-")

        # Display text
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
            f"    plex_search:",
            f"      all:",
            f"        label: \"{label}\"",
            f"    name: \"text({display})\"",
            f"    font_size: 45",
            f"    font_color: \"{color}\"",
            f"    back_color: \"#000000CC\"",
            f"    back_width: 180",
            f"    back_height: 55",
            f"    horizontal_align: left",
            f"    vertical_align: bottom",
            f"    horizontal_offset: 15",
            f"    vertical_offset: 15",
            f"    back_radius: 10",
            "",
        ])

    yaml_content = "\n".join(lines) + "\n"

    with open(KOMETA_OUTPUT, "w") as f:
        f.write(yaml_content)
    log(f"  Wrote {len(sorted_labels)} overlay entries to {KOMETA_OUTPUT}")
    return yaml_content


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

    log("Starting episode count sync...")

    # Get Sonarr data
    sonarr_counts = get_sonarr_counts()

    # Get Plex shows from both TV and Anime sections
    all_shows = []
    for section in [PLEX_TV_SECTION, PLEX_ANIME_SECTION]:
        try:
            shows = get_plex_shows(section)
            # Tag each show with its section for label PUT
            for s in shows:
                s["section_id"] = section
            all_shows.extend(shows)
        except Exception as e:
            log(f"  Warning: Could not fetch section {section}: {e}")

    # Match and apply labels
    matched = sum(1 for s in all_shows if s["tvdb_id"] in sonarr_counts)
    log(f"Matched {matched} Plex shows to Sonarr series")

    label_map = apply_labels(all_shows, sonarr_counts)

    # Generate Kometa YAML
    generate_kometa_yaml(label_map)

    log("Done.")


if __name__ == "__main__":
    main()
