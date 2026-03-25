#!/usr/bin/env python3
"""
because-you-watched.py — Generate "Because You Watched X" collections in Plex.

Queries Tautulli for recent watch history, uses TMDb to find similar titles,
cross-references with the Plex library, and creates/updates collections.

Designed to run on a cron (every 6 hours) or triggered by the webhook service.

Environment:
  PLEX_URL           - Plex base URL (default: http://localhost:32400)
  PLEX_TOKEN         - Plex auth token (required)
  TAUTULLI_URL       - Tautulli base URL (default: http://localhost:8181)
  TAUTULLI_API_KEY   - Tautulli API key (required)
  TMDB_API_KEY       - TMDb API key (required)
  MAX_SOURCES        - Max recently watched titles to build from (default: 5)
  MIN_COLLECTION     - Min items for a collection to be created (default: 3)
  COLLECTION_PREFIX  - Prefix for collection names (default: "Because You Watched")
"""

import json
import os
import sys
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from collections import defaultdict

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
PLEX_URL = os.environ.get("PLEX_URL", "http://localhost:32400")
PLEX_TOKEN = os.environ.get("PLEX_TOKEN", "")
TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://localhost:8181")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
TMDB_API_KEY = os.environ.get("TMDB_API_KEY", "")
MAX_SOURCES = int(os.environ.get("MAX_SOURCES", "5"))
MIN_COLLECTION = int(os.environ.get("MIN_COLLECTION", "3"))
COLLECTION_PREFIX = os.environ.get("COLLECTION_PREFIX", "Because You Watched")


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[byw] [{ts}] {msg}", flush=True)


def api_get(url):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def plex_get(path):
    url = f"{PLEX_URL}{path}"
    sep = "&" if "?" in url else "?"
    url += f"{sep}X-Plex-Token={PLEX_TOKEN}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return ET.fromstring(resp.read())


def plex_api(path, method="GET", data=None):
    url = f"{PLEX_URL}{path}"
    sep = "&" if "?" in url else "?"
    url += f"{sep}X-Plex-Token={PLEX_TOKEN}"
    req = urllib.request.Request(url, method=method)
    if data:
        req.data = data.encode()
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.status


# ---------------------------------------------------------------------------
# Tautulli: Get recently watched unique titles
# ---------------------------------------------------------------------------
def get_recent_watches():
    """Get recently watched unique movies and shows."""
    log("Fetching watch history from Tautulli...")
    data = api_get(
        f"{TAUTULLI_URL}/api/v2?apikey={TAUTULLI_API_KEY}"
        f"&cmd=get_history&length=50"
    )
    history = data["response"]["data"]["data"]

    seen_movies = {}
    seen_shows = {}

    for item in history:
        media_type = item.get("media_type", "")
        title = item.get("grandparent_title") or item.get("full_title", "")
        rating_key = item.get("grandparent_rating_key") or item.get("rating_key")

        if media_type == "movie":
            key = item.get("rating_key")
            if key and key not in seen_movies:
                seen_movies[key] = {
                    "title": item.get("full_title", ""),
                    "rating_key": key,
                    "year": item.get("year"),
                    "type": "movie",
                }
        elif media_type == "episode":
            key = item.get("grandparent_rating_key")
            if key and key not in seen_shows:
                seen_shows[key] = {
                    "title": item.get("grandparent_title", ""),
                    "rating_key": key,
                    "year": item.get("year"),
                    "type": "show",
                }

    # Combine and limit
    recent = list(seen_movies.values()) + list(seen_shows.values())
    recent = recent[:MAX_SOURCES]
    log(f"  Found {len(seen_movies)} unique movies, {len(seen_shows)} unique shows")
    log(f"  Using top {len(recent)} as sources")
    return recent


# ---------------------------------------------------------------------------
# Plex: Build library index by TMDb ID
# ---------------------------------------------------------------------------
def build_plex_index():
    """Build a lookup of {tmdb_id: {rating_key, title, section}} for all Plex items."""
    log("Building Plex library index...")
    index = {}

    for section_id, media_type in [("1", "movie"), ("2", "show"), ("7", "movie"), ("3", "show")]:
        try:
            plex_type = "1" if media_type == "movie" else "2"
            root = plex_get(f"/library/sections/{section_id}/all?type={plex_type}&includeGuids=1")
            tag = "Video" if media_type == "movie" else "Directory"
            for item in root.findall(tag):
                for guid in item.findall("Guid"):
                    gid = guid.get("id", "")
                    if gid.startswith("tmdb://"):
                        tmdb_id = int(gid.replace("tmdb://", ""))
                        index[tmdb_id] = {
                            "rating_key": item.get("ratingKey"),
                            "title": item.get("title"),
                            "section_id": section_id,
                            "type": media_type,
                        }
        except Exception as e:
            log(f"  Warning: section {section_id}: {e}")

    log(f"  Indexed {len(index)} items by TMDb ID")
    return index


# ---------------------------------------------------------------------------
# Plex: Get TMDb ID for a rating key
# ---------------------------------------------------------------------------
def get_tmdb_id(rating_key):
    """Get TMDb ID for a Plex item."""
    try:
        root = plex_get(f"/library/metadata/{rating_key}")
        for tag in ["Video", "Directory"]:
            item = root.find(tag)
            if item:
                for guid in item.findall("Guid"):
                    gid = guid.get("id", "")
                    if gid.startswith("tmdb://"):
                        return int(gid.replace("tmdb://", ""))
    except:
        pass
    return None


# ---------------------------------------------------------------------------
# TMDb: Get similar/recommended titles
# ---------------------------------------------------------------------------
def get_tmdb_similar(tmdb_id, media_type):
    """Get similar titles from TMDb."""
    tmdb_type = "movie" if media_type == "movie" else "tv"
    similar = []

    for endpoint in ["similar", "recommendations"]:
        try:
            data = api_get(
                f"https://api.themoviedb.org/3/{tmdb_type}/{tmdb_id}/{endpoint}"
                f"?api_key={TMDB_API_KEY}&language=en-US&page=1"
            )
            for item in data.get("results", []):
                similar.append(item["id"])
        except:
            pass

    return list(dict.fromkeys(similar))  # dedupe preserving order


# ---------------------------------------------------------------------------
# Plex: Manage collections
# ---------------------------------------------------------------------------
def get_existing_byw_collections(section_id):
    """Get existing 'Because You Watched' collections."""
    root = plex_get(f"/library/sections/{section_id}/collections")
    collections = {}
    for d in root.findall("Directory"):
        title = d.get("title", "")
        if title.startswith(COLLECTION_PREFIX):
            collections[title] = d.get("ratingKey")
    return collections


def create_or_update_collection(section_id, title, rating_keys):
    """Create or update a collection with the given items."""
    # Check if collection exists
    existing = get_existing_byw_collections(section_id)

    if title in existing:
        # Delete old one and recreate (simplest approach)
        coll_key = existing[title]
        try:
            plex_api(f"/library/metadata/{coll_key}", method="DELETE")
        except:
            pass

    # Create collection via adding items
    machine_id = plex_get("/").get("machineIdentifier")
    key_str = ",".join(str(k) for k in rating_keys)

    try:
        plex_api(
            f"/library/collections"
            f"?type=1&title={urllib.parse.quote(title)}"
            f"&smart=0&sectionId={section_id}"
            f"&uri=server://{machine_id}/com.plexapp.plugins.library/library/metadata/{key_str}",
            method="POST"
        )
        return True
    except Exception as e:
        log(f"  Failed to create collection '{title}': {e}")
        return False


# ---------------------------------------------------------------------------
# Cleanup: Remove stale BYW collections
# ---------------------------------------------------------------------------
def cleanup_stale_collections(active_titles):
    """Remove BYW collections that are no longer relevant."""
    for section_id in ["1", "2"]:
        existing = get_existing_byw_collections(section_id)
        for title, coll_key in existing.items():
            if title not in active_titles:
                try:
                    plex_api(f"/library/metadata/{coll_key}", method="DELETE")
                    log(f"  Removed stale: {title}")
                except:
                    pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if not PLEX_TOKEN:
        log("ERROR: PLEX_TOKEN not set")
        sys.exit(1)
    if not TAUTULLI_API_KEY:
        log("ERROR: TAUTULLI_API_KEY not set")
        sys.exit(1)
    if not TMDB_API_KEY:
        log("ERROR: TMDB_API_KEY not set")
        sys.exit(1)

    log("Starting 'Because You Watched' generation...")

    # Get recent watches
    recent = get_recent_watches()
    if not recent:
        log("No recent watch history found")
        return

    # Build Plex index
    plex_index = build_plex_index()

    # For each recently watched title, find similar in library
    active_titles = set()
    created = 0

    for source in recent:
        tmdb_id = get_tmdb_id(source["rating_key"])
        if not tmdb_id:
            log(f"  No TMDb ID for '{source['title']}', skipping")
            continue

        similar_ids = get_tmdb_similar(tmdb_id, source["type"])
        log(f"  '{source['title']}': {len(similar_ids)} similar from TMDb")

        # Cross-reference with Plex library
        matches = []
        for sid in similar_ids:
            if sid in plex_index:
                match = plex_index[sid]
                # Don't include the source itself
                if match["rating_key"] != source["rating_key"]:
                    matches.append(match)

        if len(matches) < MIN_COLLECTION:
            log(f"    Only {len(matches)} in library (need {MIN_COLLECTION}), skipping")
            continue

        # Create collection
        coll_title = f"{COLLECTION_PREFIX}: {source['title']}"
        active_titles.add(coll_title)

        # Determine section (movies go to movies, shows to shows)
        section_id = matches[0]["section_id"]
        rating_keys = [m["rating_key"] for m in matches[:20]]  # Cap at 20

        if create_or_update_collection(section_id, coll_title, rating_keys):
            log(f"    Created '{coll_title}' with {len(rating_keys)} items")
            created += 1

    # Cleanup old collections
    cleanup_stale_collections(active_titles)

    log(f"Done. Created/updated {created} collections.")


if __name__ == "__main__":
    main()
