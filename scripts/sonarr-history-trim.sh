#!/bin/bash
# Trim Sonarr download history older than 7 days
# Prevents ProcessMonitoredDownloads from choking on stale entries
# Runs daily via cron
docker exec arr-postgres psql -U arr_admin -d sonarr-main -c \
  "DELETE FROM \"DownloadHistory\" WHERE \"Date\" < NOW() - INTERVAL '7 days';"
