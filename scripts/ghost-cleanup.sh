#!/bin/bash
# ghost-cleanup.sh — Remove queue entries where files no longer exist on disk
# Runs inside arr containers where paths are correct
# Called from arr-maintenance.sh

set -uo pipefail

# --- API keys extracted live from each container's config, never hardcoded ---
WHISPARR_KEY=$(docker exec whisparr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+')
SONARR_KEY=$(docker exec sonarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+')

# Whisparr ghost cleanup
docker exec whisparr python3 -c "
import json, urllib.request, os

BASE = 'http://localhost:6969/api/v3'
KEY = '$WHISPARR_KEY'

def get(path):
    req = urllib.request.Request(f'{BASE}/{path}', headers={'X-Api-Key': KEY})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def delete(path):
    req = urllib.request.Request(f'{BASE}/{path}', headers={'X-Api-Key': KEY}, method='DELETE')
    urllib.request.urlopen(req, timeout=30)

page = 1
ghosts = 0
while True:
    try:
        d = get(f'queue?pageSize=200&page={page}')
    except:
        break
    records = d.get('records', [])
    if not records:
        break
    for r in records:
        if r.get('status') == 'completed':
            output = r.get('outputPath', '')
            if output and not os.path.exists(output):
                try:
                    delete(f'queue/{r[\"id\"]}?removeFromClient=true&blocklist=false&skipRedownload=true')
                    ghosts += 1
                except:
                    pass
    page += 1

if ghosts > 0:
    print(f'Whisparr: removed {ghosts} ghost queue entries')
" 2>/dev/null

# Same for Sonarr
docker exec sonarr python3 -c "
import json, urllib.request, os

BASE = 'http://localhost:8989/api/v3'
KEY = '$SONARR_KEY'

def get(path):
    req = urllib.request.Request(f'{BASE}/{path}', headers={'X-Api-Key': KEY})
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def delete(path):
    req = urllib.request.Request(f'{BASE}/{path}', headers={'X-Api-Key': KEY}, method='DELETE')
    urllib.request.urlopen(req, timeout=30)

page = 1
ghosts = 0
while True:
    try:
        d = get(f'queue?pageSize=200&page={page}')
    except:
        break
    records = d.get('records', [])
    if not records:
        break
    for r in records:
        if r.get('status') == 'completed':
            output = r.get('outputPath', '')
            if output and not os.path.exists(output):
                try:
                    delete(f'queue/{r[\"id\"]}?removeFromClient=true&blocklist=false&skipRedownload=true')
                    ghosts += 1
                except:
                    pass
    page += 1

if ghosts > 0:
    print(f'Sonarr: removed {ghosts} ghost queue entries')
" 2>/dev/null
