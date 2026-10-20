#!/bin/bash
# Create per-app main + log databases for the *arr suite.
# Runs once on first Postgres init via docker-entrypoint-initdb.d.
set -e

for app in sonarr radarr lidarr prowlarr whisparr; do
    for suffix in main log; do
        db="${app}-${suffix}"
        echo "Creating database: ${db}"
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
            CREATE DATABASE "${db}";
            GRANT ALL PRIVILEGES ON DATABASE "${db}" TO "$POSTGRES_USER";
EOSQL
    done
done

echo "All *arr databases created."
