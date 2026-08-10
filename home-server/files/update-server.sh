#!/bin/bash
# Monthly home server maintenance with one command:
#   ssh -t <user>@192.168.0.10 ./update-server.sh
# Updates: system packages (both Pis), Paperless, Immich (incl. compose
# rebuild), the ML Pi. Skim the Immich release notes first:
#   https://github.com/immich-app/immich/releases
set -euo pipefail

# ---- adjust to your setup -------------------------------------------------
ML_PI="pi-admin@192.168.0.11"          # user@host of the ML Pi
ML_KEY="$HOME/.ssh/id_mlpi_update"     # restricted key, see setup guide
MAIN_IP="192.168.0.10"
# ---------------------------------------------------------------------------

echo "==== 1/5 System updates, main server ===="
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
echo "-- SSD health (SMART):"
sudo smartctl -H /dev/sda | tail -1 || true

echo "==== 2/5 Paperless ===="
cd /srv/docker/paperless
docker compose pull --quiet
docker compose up -d

echo "==== 3/5 Immich (fetch upstream compose + rebuild) ===="
cd /srv/docker/immich
wget -qO docker-compose.yml.upstream \
  https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -qO example.env.upstream \
  https://github.com/immich-app/immich/releases/latest/download/example.env
cp docker-compose.yml docker-compose.yml.bak
python3 /srv/docker/immich/transform-compose.py docker-compose.yml.upstream docker-compose.yml
docker compose config >/dev/null || { echo "ERROR: generated compose invalid, restoring backup"; cp docker-compose.yml.bak docker-compose.yml; exit 1; }
echo "-- Variables new in upstream (add to .env if needed):"
comm -23 <(grep -oE '^[A-Z_]+' example.env.upstream | sort -u) \
         <(grep -oE '^[A-Z_]+' .env | sort -u) || true
docker compose pull --quiet
docker compose up -d

echo "==== 4/5 ML Pi (system + container) ===="
ssh -i "$ML_KEY" -o BatchMode=yes "$ML_PI" update

echo "==== 5/5 Cleanup, main server ===="
docker image prune -f

echo "==== Done. Quick check (waits up to 2 min for restarts): ===="
check_url() { # name, url, expected code
  local code=""
  for _ in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$2" || true)
    [ "$code" = "$3" ] && break
    sleep 10
  done
  echo "$1 HTTP $code (expected $3)"
}
check_url "Paperless:" "http://$MAIN_IP:8000/" 302
check_url "Immich:   " "http://$MAIN_IP:2283/" 200
check_url "ML Pi:    " "http://${ML_PI#*@}:3003/ping" 200

# Immich soft-deletes offline external assets without setting status='trashed',
# so empty-trash skips them and the rows keep coming back; locked ones are not
# even reachable through the API. immich-trash-cleanup.py fixes both and only
# deletes what has no file on disk any more.
echo "==== Immich trash ===="
./immich-trash-cleanup.py --purge || echo "trash cleanup failed"

